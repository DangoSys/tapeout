set verification_auto_session on
source -e -v ../config/project.tcl

if {![info exists RUN_TAG]} {
  set RUN_TAG [clock format [clock seconds] -format "%m%d_%H%M"]
}

setup_common_libraries

set dc_dir [selected_dc_output_dir]
set impl_netlist [file join $dc_dir ${TOP_MODULE}.v]
set svf_file [file join $PROJECT_ROOT 2_SYN default.svf]
require_existing_file $impl_netlist "DC implementation netlist"

guide
setup

if {[file exists $svf_file]} {
  set_svf -append $svf_file
} else {
  puts "Warning: DC SVF not found: $svf_file"
}

set_mismatch_message_filter -warn FMR_VLOG-091
set_mismatch_message_filter -warn FMR_ELAB-147

foreach lib [existing_files [concat $TARGET_LIBRARY_FILES $SRAM_LIBRARY_FILES] "Library file"] {
  read_db $lib
}

set rtl_files [concat [read_filelist $RTL_FILELIST] [existing_files $EXTRA_RTL_FILES "Extra RTL file"]]
foreach f $rtl_files {
  read_verilog -r $f
}
foreach f [existing_files $SRAM_VERILOG_FILES "SRAM Verilog file"] {
  read_verilog -r $f
}
set_top r:/WORK/${TOP_MODULE}

read_verilog -i $impl_netlist
foreach f [existing_files $SRAM_VERILOG_FILES "SRAM Verilog file"] {
  read_verilog -i $f
}
set_top i:/WORK/${TOP_MODULE}

set verification_clock_gate_edge_analysis true

match
verify

report_failing_points > ./rpt/$RUN_TAG/failing_points.rpt
report_unmatched_points > ./rpt/$RUN_TAG/unmatched_points.rpt
report_matched_points > ./rpt/$RUN_TAG/matched_points.rpt
report_passing_points > ./rpt/$RUN_TAG/passing_points.rpt

puts "Formality complete: $RUN_TAG, DC input: $dc_dir"
