#!/bin/sh

set -eu

MEM_ROOT_DEFAULT="/data0/tsmc28/TSMC28/Memory/tsn28hpcpd127spsram_20120200_180a/AN61001_20180416/TSMCHOME/sram/Compiler/tsn28hpcpd127spsram_20120200_180a/ts1n28hpcphvtb128x64m4swbaso_180a"
LC_SHELL_DEFAULT="/data2/tools/lc/R-2020.09-SP5/linux64/lc/bin/lc_shell"
LC_LICENSE_FILE_DEFAULT="26000@amax"
LC_LD_LIBRARY_PATH_DEFAULT="/data0/tools/Synopsys/dc/syn/W-2024.09-SP1/linux64/syn/shlib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu/pulseaudio"

mem_root="${1:-$MEM_ROOT_DEFAULT}"
out_dir="${2:-$(pwd)}"
lc_shell_bin="${LC_SHELL:-$LC_SHELL_DEFAULT}"
lc_license_file="${LC_LICENSE_FILE:-$LC_LICENSE_FILE_DEFAULT}"
lc_ld_library_path="${LC_LD_LIBRARY_PATH:-$LC_LD_LIBRARY_PATH_DEFAULT}"

if [ ! -d "$mem_root" ]; then
  echo "ERROR: memory root does not exist: $mem_root" >&2
  exit 1
fi

mkdir -p "$out_dir"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/build_sram_db.XXXXXX")"
tcl_file="$tmp_dir/convert_libs.tcl"
manifest_file="$tmp_dir/lib_manifest.txt"
log_file="$out_dir/lc_compile.log"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

find "$mem_root" -type f \( -name "*.lib" -o -name "*.LIB" \) | sort > "$tmp_dir/all_libs.txt"

: > "$manifest_file"
while IFS= read -r lib_file; do
  lib_name="$(awk '
    /^[[:space:]]*library[[:space:]]*\(/ {
      line = $0
      sub(/^[[:space:]]*library[[:space:]]*\([[:space:]]*/, "", line)
      sub(/[[:space:]]*\).*/, "", line)
      print line
      exit
    }
  ' "$lib_file")"
  if [ -n "$lib_name" ]; then
    printf '%s\t%s\n' "$lib_file" "$lib_name" >> "$manifest_file"
  fi
done < "$tmp_dir/all_libs.txt"

if [ ! -s "$manifest_file" ]; then
  echo "ERROR: no Liberty timing libraries found under $mem_root" >&2
  exit 1
fi

cat > "$tcl_file" <<EOF
set out_dir [file normalize {$out_dir}]
set manifest_file [file normalize {$manifest_file}]
set success_count 0
set failure_count 0

proc convert_one {lib_path lib_name out_dir} {
  upvar success_count success_count
  upvar failure_count failure_count

  set out_file [file join \$out_dir "\${lib_name}.db"]
  puts "==> Converting \$lib_path"
  if {[catch {read_lib \$lib_path} err]} {
    incr failure_count
    puts stderr "ERROR: read_lib failed for \$lib_path"
    puts stderr \$err
    return
  }
  if {[catch {write_lib \$lib_name -f db -o \$out_file} err]} {
    incr failure_count
    puts stderr "ERROR: write_lib failed for \$lib_name"
    puts stderr \$err
    return
  }
  incr success_count
  puts "    Wrote \$out_file"
}

set fp [open \$manifest_file r]
while {[gets \$fp line] >= 0} {
  if {\$line eq ""} {
    continue
  }
  set fields [split \$line "\t"]
  if {[llength \$fields] != 2} {
    incr failure_count
    puts stderr "ERROR: malformed manifest line: \$line"
    continue
  }
  lassign \$fields lib_path lib_name
  convert_one \$lib_path \$lib_name \$out_dir
}
close \$fp

puts "SUMMARY: success=\$success_count failure=\$failure_count output_dir=\$out_dir"
if {\$failure_count > 0} {
  exit 2
}
quit
EOF

echo "Memory root : $mem_root"
echo "Output dir  : $out_dir"
echo "Manifest    : $manifest_file"
echo "Log file    : $log_file"
echo "LC shell    : $lc_shell_bin"
echo "License     : $lc_license_file"

status=0
env -i \
  HOME="$HOME" \
  USER="${USER:-$(id -un)}" \
  LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
  TERM="${TERM:-xterm}" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LM_LICENSE_FILE="$lc_license_file" \
  LD_LIBRARY_PATH="$lc_ld_library_path" \
  "$lc_shell_bin" -f "$tcl_file" > "$log_file" 2>&1 || status=$?
cat "$log_file"
exit "$status"
