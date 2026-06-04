set script_dir [file dirname [file normalize [info script]]]
set verilog_dir [file join $script_dir verilog]
set filelist [file join $verilog_dir filelist.f]
set waveform [file join $script_dir waveform.vcd]
set report_dir [file join $script_dir ptpx_reports]
set default_library_files [list \
  /data0/tools/lib/db/scc28nhkcp_hdc35p140_rvt_ffg_v0p99_0c_basic.db \
  /data0/tools/lib/db/scc28nhkcp_hdc35p140_rvt_ffg_v0p99_0c_ccs.db \
  /data0/tools/lib/db/scc28nhkcp_hdc35p140_rvt_ffg_v0p99_0c_ecsm.db \
]
set default_library_search_path [list \
  /opt/dc/lib/TSMCHOME/SRAM_m4swbsoffg0p99v0c \
]

proc getenv_default {name default_value} {
  if {[info exists ::env($name)] && $::env($name) ne ""} {
    return $::env($name)
  }
  return $default_value
}

proc split_path_or_list {value} {
  if {$value eq ""} {
    return {}
  }
  if {[string first ":" $value] >= 0} {
    return [split $value ":"]
  }
  return $value
}

set top_module [getenv_default PTPX_TOP "DigitalTop"]
set default_netlist [file join $script_dir dc_outputs ${top_module}.mapped.v]
set default_sdc [file join $script_dir dc_outputs ${top_module}.sdc]
set netlist_file [file normalize [getenv_default PTPX_NETLIST $default_netlist]]
set sdc_file [file normalize [getenv_default PTPX_SDC $default_sdc]]
set vcd_file [file normalize [getenv_default PTPX_VCD $waveform]]
set strip_path [getenv_default PTPX_STRIP_PATH "TOP/BBSimHarness/chiptop0/system"]
set clock_period_ns [getenv_default PTPX_CLOCK_PERIOD_NS "10.0"]
set clock_port [getenv_default PTPX_CLOCK_PORT "auto_chipyard_prcictrl_domain_reset_setter_clock_in_member_allClocks_uncore_clock"]
set library_files [split_path_or_list [getenv_default PTPX_LIBS $default_library_files]]
set extra_search_path [concat $default_library_search_path [split_path_or_list [getenv_default PTPX_SEARCH_PATH ""]]]
set read_verilog_options [split_path_or_list [getenv_default PTPX_READ_VERILOG_OPTIONS "-hdl_compiler"]]

set netlist_requested [expr {[info exists ::env(PTPX_NETLIST)] && $::env(PTPX_NETLIST) ne ""}]
set sdc_requested [expr {[info exists ::env(PTPX_SDC)] && $::env(PTPX_SDC) ne ""}]
set use_netlist [file exists $netlist_file]
set use_sdc [file exists $sdc_file]

if {$netlist_requested && !$use_netlist} {
  puts stderr "ERROR: Cannot find PTPX netlist: $netlist_file"
  exit 1
}

if {$sdc_requested && !$use_sdc} {
  puts stderr "ERROR: Cannot find PTPX SDC: $sdc_file"
  exit 1
}

if {!$use_netlist && ![file exists $filelist]} {
  puts stderr "ERROR: Cannot find Verilog file list: $filelist"
  exit 1
}

if {![file exists $vcd_file]} {
  puts stderr "ERROR: Cannot find VCD waveform: $vcd_file"
  exit 1
}

if {[llength $library_files] == 0} {
  puts stderr "ERROR: Please set PTPX_LIBS to one or more technology libraries."
  puts stderr "       Example: export PTPX_LIBS=/path/stdcell.db:/path/memories.db"
  exit 1
}

file mkdir $report_dir

if {!$use_netlist} {
  set fp [open $filelist r]
  set filelist_text [read $fp]
  close $fp

  set rtl_files {}
  foreach raw_line [split $filelist_text "\n"] {
    set line [string trim $raw_line]
    if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} {
      continue
    }
    set ext [string tolower [file extension $line]]
    if {$ext ni {.sv .v .svh .vh}} {
      continue
    }
    if {[file pathtype $line] eq "absolute"} {
      lappend rtl_files $line
    } else {
      lappend rtl_files [file normalize [file join $verilog_dir $line]]
    }
  }

  if {[llength $rtl_files] == 0} {
    puts stderr "ERROR: No Verilog/SystemVerilog source files found in $filelist"
    exit 1
  }
}

proc file_has_design {filename} {
  set fp [open $filename r]
  set text [read $fp]
  close $fp
  return [regexp -line {^[[:space:]]*(module|interface|package|primitive)[[:space:]]+} $text]
}

proc file_has_dpi_import {filename} {
  set fp [open $filename r]
  set text [read $fp]
  close $fp
  return [regexp {import[[:space:]]+"DPI-C"} $text]
}

if {!$use_netlist} {
  set sv_file_count 0
  set v_file_count 0
  set design_files {}
  foreach rtl_file $rtl_files {
    set ext [string tolower [file extension $rtl_file]]
    if {$ext in {.svh .vh}} {
      continue
    }
    if {![file_has_design $rtl_file]} {
      puts "Skipping $rtl_file because it does not define a design."
      continue
    }
    if {[file_has_dpi_import $rtl_file]} {
      puts "Skipping $rtl_file because PrimeTime HDL Compiler cannot parse DPI imports."
      continue
    }
    lappend design_files $rtl_file
    if {$ext eq ".sv"} {
      incr sv_file_count
    } else {
      incr v_file_count
    }
  }

  if {[llength $design_files] == 0} {
    puts stderr "ERROR: No Verilog/SystemVerilog design files found in $filelist"
    exit 1
  }
}

set_app_var search_path [concat [list . $verilog_dir] $extra_search_path]
set_app_var target_library $library_files
set_app_var link_library [concat [list *] $library_files]
set_app_var power_enable_analysis true

if {$use_netlist} {
  puts "Reading DC mapped netlist: $netlist_file"
  read_verilog $netlist_file
} else {
  set combined_source [file join $report_dir ptpx_combined_sources.sv]
  set combined_fp [open $combined_source w]
  puts $combined_fp "// Generated by ptpx_power.tcl. Do not edit."
  foreach design_file $design_files {
    puts $combined_fp "\`include \"$design_file\""
  }
  close $combined_fp

  puts "Reading $sv_file_count SystemVerilog files and $v_file_count Verilog files from $filelist"
  if {[llength $read_verilog_options] == 0} {
    read_verilog $combined_source
  } else {
    read_verilog {*}$read_verilog_options $combined_source
  }
}

link_design $top_module
set top_designs [get_designs -quiet $top_module]
if {[sizeof_collection $top_designs] == 0} {
  puts stderr "ERROR: Top design '$top_module' was not read. Check read_verilog messages above."
  exit 1
}
current_design $top_module

if {$use_sdc} {
  puts "Reading SDC constraints: $sdc_file"
  read_sdc $sdc_file
} else {
  set clock_objs [get_ports -quiet $clock_port]
  if {[sizeof_collection $clock_objs] > 0} {
    create_clock -name core_clock -period $clock_period_ns $clock_objs
  } else {
    puts stderr "WARNING: Clock port '$clock_port' was not found; reports will use the VCD timing only."
  }
}

if {[llength [info commands check_design]] > 0} {
  check_design > [file join $report_dir check_design.rpt]
} else {
  puts "Skipping check_design because this PrimeTime version does not provide that command."
}
check_timing > [file join $report_dir check_timing.rpt]

set_power_analysis_mode -analysis_effort medium
read_vcd -strip_path $strip_path $vcd_file

update_power

report_switching_activity > [file join $report_dir switching_activity.rpt]
report_power -hierarchy > [file join $report_dir power_hierarchy.rpt]
report_power > [file join $report_dir power_summary.rpt]

puts "PTPX power analysis completed."
puts "Reports are under: $report_dir"
