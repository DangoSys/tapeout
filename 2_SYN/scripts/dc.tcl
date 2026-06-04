set STAGE_DIR [file normalize [file join [pwd]]]
source -e -v ../config/project.tcl

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

setup_common_libraries

set hdlin_verilog_defines $RTL_DEFINES
set hdlin_auto_save_templates true
set_app_var alib_library_analysis_path ./alib-52

set rtl_files [concat [read_filelist $RTL_FILELIST] [existing_files $EXTRA_RTL_FILES "Extra RTL file"]]
puts "Analyzing [llength $rtl_files] RTL files"
analyze -format sverilog $rtl_files

elaborate $TOP_MODULE
current_design $TOP_MODULE
link

source -e -v ./scripts/constraints.tcl
source -e -v ./scripts/set_dont_touch.tcl
source -e -v ./scripts/set_false_path.tcl
source -e -v ./scripts/set_dont_use.tcl
source -e -v ./scripts/operation_conditions.tcl

check_design > ./rpt/$RUN_TAG/check_design.rpt
check_timing > ./rpt/$RUN_TAG/check_timing.pre.rpt
report_clocks > ./rpt/$RUN_TAG/clocks.rpt

group_path -name INPUT_GROUP -from [all_inputs]
group_path -name OUTPUT_GROUP -to [all_outputs]

compile_ultra {*}$DC_COMPILE_OPTIONS

set_fix_multiple_port_nets -all -buffer_constants
set_fix_multiple_port_nets -all -buffer_constants [all_designs]

change_names -hier -rules verilog

write_sdc ./outputs/$RUN_TAG/${TOP_MODULE}.sdc
write -format ddc -hierarchy -output ./outputs/$RUN_TAG/${TOP_MODULE}.ddc
write -format verilog -hierarchy -output ./outputs/$RUN_TAG/${TOP_MODULE}.v
write_link_library -out ./outputs/$RUN_TAG/link_library.txt

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

puts "DC run complete: $RUN_TAG"
