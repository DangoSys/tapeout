# Shared project configuration for DC/PT/PTPX/FM.
# Keep machine-specific paths here instead of scattering them through scripts.

set PROJECT_ROOT [file normalize [file join [file dirname [info script]] ..]]

set TOP_MODULE ChipTop
set RTL_FILELIST [file join $PROJECT_ROOT config rtl.f]
set RTL_SEARCH_PATHS [list \
  [file join $PROJECT_ROOT 0_RTL sims.verilator.BuckyballToyVerilatorConfig] \
  [file join $PROJECT_ROOT verilog] \
]

set RTL_DEFINES [list SYNTHESIS DC_SYN]
set RTL_INCLUDE_DIRS $RTL_SEARCH_PATHS
set EXTRA_RTL_FILES [list \
  [file join $PROJECT_ROOT verilog sram_replacements.sv] \
]

# Fill these with foundry/IP deliverables before running commercial tools.
set TARGET_LIBRARY_FILES [list]
set SYMBOL_LIBRARY_FILES [list]
set SYNTHETIC_LIBRARY_FILES [list \
  /data2/tools/syn/R-2020.09-SP5/libraries/syn/dw_foundation.sldb \
  /data2/tools/syn/R-2020.09-SP5/libraries/syn/standard.sldb \
]

# SRAM compiler outputs. Typical contents:
# - Liberty .lib/.db for timing/power
# - Verilog simulation/blackbox models for FM/PT linking if needed
set SRAM_LIBRARY_FILES [list]
set SRAM_VERILOG_FILES [list]

set CLOCK_PORT clock
set CLOCK_NAME clock
set CLOCK_PERIOD_NS 1.0
set CLOCK_UNCERTAINTY_RATIO 0.30
set CLOCK_TRANSITION_RATIO 0.10
set IO_DELAY_RATIO 0.70
set MAX_FANOUT 32
set MAX_TRANSITION 2.0
set OUTPUT_LOAD 2.0

# DC compile options.
set DC_HOST_CORES 16
set DC_COMPILE_OPTIONS [list -area_high_effort_script -no_autoungroup -no_boundary_optimization]

# PrimeTime / PTPX input selection. If PT_DC_RUN_TAG is empty, scripts pick the
# latest directory under 2_SYN/outputs.
set PT_DC_RUN_TAG ""
set PTPX_ACTIVITY_FILE ""
set PTPX_ACTIVITY_FORMAT "fsdb"
set PTPX_STRIP_PATH ""
set PTPX_TIME_WINDOW ""

proc require_nonempty_list {name value} {
  if {[llength $value] == 0} {
    error "$name is empty. Edit config/project.tcl before running this stage."
  }
}

proc require_existing_file {path desc} {
  if {![file exists $path]} {
    error "$desc does not exist: $path"
  }
}

proc existing_files {files desc} {
  set out [list]
  foreach f $files {
    if {$f eq ""} { continue }
    set nf [file normalize $f]
    if {![file exists $nf]} {
      error "$desc does not exist: $nf"
    }
    lappend out $nf
  }
  return $out
}

proc read_filelist {filelist} {
  require_existing_file $filelist "RTL filelist"
  set fh [open $filelist r]
  set files [list]
  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} { continue }
    lappend files [file normalize $line]
  }
  close $fh
  return $files
}

proc latest_child_dir {parent} {
  set dirs [glob -nocomplain -type d [file join $parent *]]
  if {[llength $dirs] == 0} {
    error "No run directories found under $parent"
  }
  return [lindex [lsort -decreasing -dictionary $dirs] 0]
}

proc selected_dc_output_dir {} {
  global PROJECT_ROOT PT_DC_RUN_TAG
  if {$PT_DC_RUN_TAG ne ""} {
    return [file join $PROJECT_ROOT 2_SYN outputs $PT_DC_RUN_TAG]
  }
  return [latest_child_dir [file join $PROJECT_ROOT 2_SYN outputs]]
}

proc setup_common_libraries {} {
  global PROJECT_ROOT RTL_SEARCH_PATHS TARGET_LIBRARY_FILES SYMBOL_LIBRARY_FILES
  global SYNTHETIC_LIBRARY_FILES SRAM_LIBRARY_FILES
  global TOP_MODULE search_path target_library symbol_library synthetic_library link_library

  require_nonempty_list TARGET_LIBRARY_FILES $TARGET_LIBRARY_FILES
  set target_library [existing_files [concat $TARGET_LIBRARY_FILES $SRAM_LIBRARY_FILES] "Library file"]
  set symbol_library [existing_files $SYMBOL_LIBRARY_FILES "Symbol library file"]
  set synthetic_library [existing_files $SYNTHETIC_LIBRARY_FILES "Synthetic library file"]

  set search_path [concat [list . $PROJECT_ROOT] $RTL_SEARCH_PATHS]
  set link_library [concat [list *] $target_library $synthetic_library]

  puts "TOP_MODULE: $TOP_MODULE"
  puts "target_library: $target_library"
  puts "synthetic_library: $synthetic_library"
  puts "link_library: $link_library"
}
