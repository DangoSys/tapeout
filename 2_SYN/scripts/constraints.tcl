set clk_port [get_ports -quiet $CLOCK_PORT]
if {[sizeof_collection $clk_port] != 1} {
  set clock_like_ports [get_object_name [get_ports -quiet *clock*]]
  error "Clock port '$CLOCK_PORT' not found. Edit CLOCK_PORT in config/project.tcl. Clock-like ports: $clock_like_ports"
} else {
  create_clock $clk_port \
    -period $CLOCK_PERIOD_NS \
    -waveform [list 0 [expr $CLOCK_PERIOD_NS / 2.0]] \
    -name $CLOCK_NAME

  set main_clock [get_clocks $CLOCK_NAME]
  set_clock_uncertainty [expr $CLOCK_PERIOD_NS * $CLOCK_UNCERTAINTY_RATIO] $main_clock
  set_clock_transition [expr $CLOCK_PERIOD_NS * $CLOCK_TRANSITION_RATIO] $main_clock

  set data_inputs [remove_from_collection [all_inputs] $clk_port]
  set data_outputs [all_outputs]
  set_input_delay [expr $CLOCK_PERIOD_NS * $IO_DELAY_RATIO] -clock $main_clock $data_inputs
  set_output_delay [expr $CLOCK_PERIOD_NS * $IO_DELAY_RATIO] -clock $main_clock $data_outputs

  set_load $OUTPUT_LOAD $data_outputs

  set all_objects [remove_from_collection [current_design] [all_outputs]]
  set all_objects [remove_from_collection $all_objects [all_inputs]]
  set_max_transition $MAX_TRANSITION $all_objects
  set_max_fanout $MAX_FANOUT $all_objects

  set_ideal_network $clk_port
  set_fix_multiple_port_nets -all -buffer_constants
}
