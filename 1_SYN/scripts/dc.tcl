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

proc run_or_die {command description} {
  if {[catch {uplevel 1 $command} result options]} {
    puts stderr "FATAL: $description failed: $result"
    if {[dict exists $options -errorinfo]} {
      puts stderr [dict get $options -errorinfo]
    }
    exit 1
  }
  return $result
}

proc fail_if_report_matches {path patterns description} {
  if {![file exists $path]} {
    error "$description report does not exist: $path"
  }
  set fh [open $path r]
  set text [read $fh]
  close $fh
  foreach pattern $patterns {
    if {[regexp $pattern $text]} {
      error "$description found pattern '$pattern' in $path"
    }
  }
}

proc copy_generated_netlist_outputs {src_dir dst_dir} {
  if {![file isdirectory $src_dir]} {
    error "DC output directory does not exist: $src_dir"
  }
  file mkdir $dst_dir
  set copied_files [list]
  foreach src [glob -nocomplain -types f [file join $src_dir *]] {
    set dst [file join $dst_dir [file tail $src]]
    file copy -force $src $dst
    lappend copied_files $dst
  }
  if {[llength $copied_files] == 0} {
    error "No generated netlist output files found under $src_dir"
  }
  return $copied_files
}

if {![info exists RUN_TAG]} {
  set RUN_TAG [clock format [clock seconds] -format "%m%d_%H%M"]
}

set_host_options -max_cores $DC_HOST_CORES
define_design_lib work -path ./elab
history keep 500

set compile_enable_register_merging true
set compile_seqmap_propagate_constants true
set compile_seqmap_identify_shift_registers false
set compile_seqmap_identify_shift_registers_with_synchronous_logic false
set timing_enable_multiple_clocks_per_reg true
set verilogout_no_tri true
set verilogout_equation false
set change_names_dont_change_bus_members true
set compile_disable_hierarchical_inverter_opt true

run_or_die {setup_common_libraries} "library setup"

set hdlin_verilog_defines $RTL_DEFINES
set hdlin_auto_save_templates true
set_app_var alib_library_analysis_path ./alib-52

run_or_die {
  set rtl_files [concat [read_filelist $RTL_FILELIST] [existing_files $EXTRA_RTL_FILES "Extra RTL file"]]
} "RTL file collection"
puts "Analyzing [llength $rtl_files] RTL files"
run_or_die {analyze -format sverilog $rtl_files} "RTL analyze"

run_or_die {elaborate $TOP_MODULE} "elaborate $TOP_MODULE"
run_or_die {current_design $TOP_MODULE} "select current design $TOP_MODULE"
run_or_die {link} "link current design"

run_or_die {source -e -v ./scripts/constraints.tcl} "source constraints.tcl"
run_or_die {source -e -v ./scripts/set_dont_touch.tcl} "source set_dont_touch.tcl"
run_or_die {source -e -v ./scripts/set_false_path.tcl} "source set_false_path.tcl"
run_or_die {source -e -v ./scripts/set_dont_use.tcl} "source set_dont_use.tcl"
run_or_die {source -e -v ./scripts/operation_conditions.tcl} "source operation_conditions.tcl"

check_design > ./rpt/$RUN_TAG/check_design.rpt
run_or_die {
  fail_if_report_matches ./rpt/$RUN_TAG/check_design.rpt [list {unresolved references} {Unable to resolve reference}] "pre-compile design check"
} "pre-compile unresolved reference check"
check_timing > ./rpt/$RUN_TAG/check_timing.pre.rpt
report_clocks > ./rpt/$RUN_TAG/clocks.rpt

run_or_die {group_path -name INPUT_GROUP -from [all_inputs]} "group input paths"
run_or_die {group_path -name OUTPUT_GROUP -to [all_outputs]} "group output paths"

run_or_die {compile_ultra {*}$DC_COMPILE_OPTIONS} "compile_ultra"

run_or_die {set_fix_multiple_port_nets -all -buffer_constants} "fix multiple port nets"
run_or_die {set_fix_multiple_port_nets -all -buffer_constants [all_designs]} "fix multiple port nets across designs"

run_or_die {change_names -hier -rules verilog} "change_names"

run_or_die {write_sdc ./outputs/$RUN_TAG/${TOP_MODULE}.sdc} "write SDC"
run_or_die {write -format ddc -hierarchy -output ./outputs/$RUN_TAG/${TOP_MODULE}.ddc} "write DDC"
run_or_die {write -format verilog -hierarchy -output ./outputs/$RUN_TAG/${TOP_MODULE}.v} "write mapped Verilog"
run_or_die {write_link_library -out ./outputs/$RUN_TAG/link_library.txt} "write link library"

report_constraint -all_vio > ./rpt/$RUN_TAG/constraint.rpt
report_constraint -all_violators > ./rpt/$RUN_TAG/${TOP_MODULE}_constraint_all_violators.rpt
check_timing > ./rpt/$RUN_TAG/${TOP_MODULE}_check_timing_final.rpt
report_timing_requirements > ./rpt/$RUN_TAG/${TOP_MODULE}_timing_requirements.rpt
report_timing -transition_time -nets -attributes -nosplit > ./rpt/$RUN_TAG/${TOP_MODULE}_mapped_timing.rpt
report_timing -delay max -max_paths 50 > ./rpt/$RUN_TAG/${TOP_MODULE}_timing_max_path.rpt
report_timing -delay min -max_paths 50 > ./rpt/$RUN_TAG/${TOP_MODULE}_timing_min_path.rpt
report_area -physical -nosplit -hierarchy > ./rpt/$RUN_TAG/${TOP_MODULE}_mapped_area.rpt
report_area -hier > ./rpt/$RUN_TAG/area.rpt
report_power -hierarchy > ./rpt/$RUN_TAG/${TOP_MODULE}_power.rpt
report_cell > ./rpt/$RUN_TAG/${TOP_MODULE}_cell.rpt
report_reference > ./rpt/$RUN_TAG/${TOP_MODULE}_ref.rpt

set POWER_NETLIST_DIR [file join $POWER_STAGE_DIR netlist]
run_or_die {
  set copied_netlist_files [copy_generated_netlist_outputs ./outputs/$RUN_TAG $POWER_NETLIST_DIR]
} "copy generated netlist outputs to power netlist directory"
puts "Copied [llength $copied_netlist_files] generated netlist output files to $POWER_NETLIST_DIR"

puts "DC run complete: $RUN_TAG"
