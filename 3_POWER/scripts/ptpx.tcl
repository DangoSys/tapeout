set STAGE_DIR [file normalize [file join [pwd]]]
set PROJECT_ROOT [file normalize [file join $STAGE_DIR ..]]
if {[info exists env(CONFIG_DIR)] && $env(CONFIG_DIR) ne ""} {
  set CONFIG_DIR [file normalize $env(CONFIG_DIR)]
} else {
  if {[info exists env(CONFIG_DIR_NAME)] && $env(CONFIG_DIR_NAME) ne ""} {
    set CONFIG_DIR_NAME $env(CONFIG_DIR_NAME)
  } else {
    set CONFIG_DIR_NAME config
  }
  set CONFIG_DIR [file join $PROJECT_ROOT $CONFIG_DIR_NAME]
}
source -e -v [file join $CONFIG_DIR project.tcl]

if {![info exists RUN_TAG]} {
  set RUN_TAG [clock format [clock seconds] -format "%m%d_%H%M"]
}

if {[info exists PTPX_RUN_ACTIVITY_FILE]} {
  set PTPX_ACTIVITY_FILE $PTPX_RUN_ACTIVITY_FILE
}
if {[info exists PTPX_RUN_ACTIVITY_FORMAT]} {
  set PTPX_ACTIVITY_FORMAT $PTPX_RUN_ACTIVITY_FORMAT
}
if {[info exists PTPX_RUN_STRIP_PATH]} {
  set PTPX_STRIP_PATH $PTPX_RUN_STRIP_PATH
}

if {$PTPX_ACTIVITY_FILE eq ""} {
  error "PTPX_ACTIVITY_FILE is empty. Edit config/project.tcl before running PTPX."
}

setup_common_libraries

if {[info exists PTPX_RUN_NETLIST_FILE]} {
  set PTPX_NETLIST_FILE $PTPX_RUN_NETLIST_FILE
}
if {[info exists PTPX_RUN_SDC_FILE]} {
  set PTPX_SDC_FILE $PTPX_RUN_SDC_FILE
}

if {![info exists PTPX_NETLIST_FILE] || $PTPX_NETLIST_FILE eq ""} {
  set dc_dir [selected_dc_output_dir]
  set PTPX_NETLIST_FILE [file join $dc_dir ${TOP_MODULE}.v]
} else {
  set dc_dir [file dirname $PTPX_NETLIST_FILE]
}

if {![info exists PTPX_SDC_FILE] || $PTPX_SDC_FILE eq ""} {
  set PTPX_SDC_FILE [file join $dc_dir ${TOP_MODULE}.sdc]
}

set netlist [file normalize $PTPX_NETLIST_FILE]
set sdc [file normalize $PTPX_SDC_FILE]
set PTPX_ACTIVITY_FILE [file normalize $PTPX_ACTIVITY_FILE]

require_existing_file $netlist "DC netlist"
require_existing_file $sdc "DC SDC"
require_existing_file $PTPX_ACTIVITY_FILE "PTPX activity file"

read_verilog $netlist
foreach f [existing_files $SRAM_VERILOG_FILES "SRAM Verilog file"] {
  read_verilog $f
}

current_design $TOP_MODULE
link
read_sdc $sdc
source -e -v ./scripts/operation_conditions.tcl

set power_enable_analysis true
set power_model_preference nlpm
set auto_wire_load_selection false
set power_clock_network_include_register_clock_pin_power false

set read_activity_options [list]
if {$PTPX_TIME_WINDOW ne ""} {
  lappend read_activity_options -time $PTPX_TIME_WINDOW
}
if {$PTPX_STRIP_PATH ne ""} {
  lappend read_activity_options -strip_path $PTPX_STRIP_PATH
}

set fmt [string tolower $PTPX_ACTIVITY_FORMAT]
if {$fmt eq "fsdb"} {
  set power_analysis_mode time_based
  read_fsdb {*}$read_activity_options $PTPX_ACTIVITY_FILE
} elseif {$fmt eq "vcd"} {
  set power_analysis_mode time_based
  read_vcd {*}$read_activity_options $PTPX_ACTIVITY_FILE
} elseif {$fmt eq "saif"} {
  set power_analysis_mode averaged
  read_saif {*}$read_activity_options $PTPX_ACTIVITY_FILE
} else {
  error "Unsupported PTPX_ACTIVITY_FORMAT '$PTPX_ACTIVITY_FORMAT'. Use fsdb, vcd, or saif."
}

check_power > ./rpt/$RUN_TAG/check_power.rpt
if {$fmt ne "saif"} {
  set_power_analysis_options \
    -waveform_interval 1 \
    -waveform_format fsdb \
    -waveform_output ./outputs/$RUN_TAG/${TOP_MODULE}_power \
    -include top
}

update_power

report_power -hierarchy -levels 3 > ./rpt/$RUN_TAG/${TOP_MODULE}_power_hier_level3.rpt
report_power -verbose > ./rpt/$RUN_TAG/${TOP_MODULE}_power_total.rpt
report_power -hierarchy -levels 2 -sort_by total_power > ./rpt/$RUN_TAG/${TOP_MODULE}_power_hier_level2_sort.rpt
report_power -hierarchy -levels 4 -sort_by total_power > ./rpt/$RUN_TAG/${TOP_MODULE}_power_hier_level4_sort.rpt
report_power -hierarchy -levels 5 -sort_by total_power > ./rpt/$RUN_TAG/${TOP_MODULE}_power_hier_level5_sort.rpt
report_clock_gate_savings -hierarchical -sequential > ./rpt/$RUN_TAG/${TOP_MODULE}_clock_gate_savings.rpt

puts "PTPX complete: $RUN_TAG, netlist: $netlist, activity: $PTPX_ACTIVITY_FILE"
quit
