set script_dir [file dirname [file normalize [info script]]]
set verilog_dir [file join $script_dir verilog]
set filelist [file join $verilog_dir filelist.f]
set output_dir [file join $script_dir dc_outputs]
set report_dir [file join $script_dir dc_reports]
set work_dir [file join $script_dir dc_work]
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

proc env_flag_enabled {value} {
  set normalized [string tolower [string trim $value]]
  if {$normalized in {"0" "false" "no" "off"}} {
    return 0
  }
  return 1
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

proc normalize_source_path {base_dir path} {
  if {[file pathtype $path] eq "absolute"} {
    return [file normalize $path]
  }
  return [file normalize [file join $base_dir $path]]
}

proc write_macro_define {fp macro} {
  if {[regexp {^([^=]+)=(.*)$} $macro -> name value]} {
    puts $fp "`define $name $value"
  } else {
    puts $fp "`define $macro 1"
  }
}

proc path_list_contains {paths target_path} {
  foreach path $paths {
    if {[file normalize $path] eq [file normalize $target_path]} {
      return 1
    }
  }
  return 0
}

proc detect_sram_library {script_dir library_files} {
  set explicit_sram_lib [getenv_default DC_SRAM_LIB ""]
  if {$explicit_sram_lib ne ""} {
    set resolved_path [normalize_source_path $script_dir $explicit_sram_lib]
    if {![file exists $resolved_path]} {
      error "Requested SRAM library does not exist: $resolved_path"
    }
    return $resolved_path
  }

  set db_dir [file join $script_dir db]
  if {![file isdirectory $db_dir]} {
    return ""
  }

  set sram_candidates [lsort [glob -nocomplain [file join $db_dir *.db]]]
  if {[llength $sram_candidates] == 0} {
    return ""
  }
  if {[llength $sram_candidates] == 1} {
    return [lindex $sram_candidates 0]
  }

  array set corner_map {
    ffg_v0p99_0c ffg0p99v0c
    ffg_v0p99_125c ffg0p99v125c
    ffg_v0p99_m40c ffg0p99vm40c
    ffg_v1p05_0c ffg1p05v0c
    ffg_v1p05_125c ffg1p05v125c
    ffg_v1p05_m40c ffg1p05vm40c
    ssg_v0p81_0c ssg0p81v0c
    ssg_v0p81_125c ssg0p81v125c
    ssg_v0p81_m40c ssg0p81vm40c
    ssg_v0p9_0c ssg0p9v0c
    ssg_v0p9_125c ssg0p9v125c
    ssg_v0p9_m40c ssg0p9vm40c
    tt_0p9_25c tt0p9v25c
    tt_0p9_85c tt0p9v85c
    tt_1v25c tt1v25c
    tt_1v85c tt1v85c
  }

  foreach library_file $library_files {
    set library_basename [string tolower [file rootname [file tail $library_file]]]
    foreach key [array names corner_map] {
      if {[string first $key $library_basename] >= 0} {
        set desired_suffix $corner_map($key)
        foreach candidate $sram_candidates {
          set candidate_basename [string tolower [file rootname [file tail $candidate]]]
          if {[string first $desired_suffix $candidate_basename] >= 0} {
            return $candidate
          }
        }
      }
    }
  }

  foreach fallback_suffix {ffg0p99v0c tt1v25c tt0p9v25c} {
    foreach candidate $sram_candidates {
      set candidate_basename [string tolower [file rootname [file tail $candidate]]]
      if {[string first $fallback_suffix $candidate_basename] >= 0} {
        return $candidate
      }
    }
  }

  return [lindex $sram_candidates 0]
}

set top_module [getenv_default DC_TOP [getenv_default PTPX_TOP "DigitalTop"]]
set clock_period_ns [getenv_default DC_CLOCK_PERIOD_NS [getenv_default PTPX_CLOCK_PERIOD_NS "10.0"]]
set clock_port [getenv_default DC_CLOCK_PORT [getenv_default PTPX_CLOCK_PORT "auto_chipyard_prcictrl_domain_reset_setter_clock_in_member_allClocks_uncore_clock"]]
set max_cores [getenv_default DC_MAX_CORES ""]
set compile_command [getenv_default DC_COMPILE_COMMAND "compile_ultra -no_autoungroup"]
set raw_library_files [split_path_or_list [getenv_default DC_LIBS [getenv_default PTPX_LIBS $default_library_files]]]
set extra_search_path [concat $default_library_search_path [split_path_or_list [getenv_default DC_SEARCH_PATH [getenv_default PTPX_SEARCH_PATH ""]]]]
set extra_defines [split_path_or_list [getenv_default DC_DEFINES ""]]
set sram_macro_cell [getenv_default DC_SRAM_CELL "TS1N28HPCPHVTB128X64M4SWBASO"]
set sram_wrapper_file [file join $verilog_dir sram_replacements.sv]
set enable_sram_wrappers [env_flag_enabled [getenv_default DC_ENABLE_SRAM_WRAPPERS "1"]]
set selected_sram_lib [detect_sram_library $script_dir $raw_library_files]
set library_files $raw_library_files
set replaced_memory_basenames [list \
  bbtile_dcache_data_arrays_256x512.sv \
  bbtile_dcache_tag_array_64x176.sv \
  bbtile_icache_data_arrays_256x256.sv \
  bbtile_icache_tag_array_64x168.sv \
  cc_dir_1024x136.sv \
  cc_banks_8192x64.sv \
  mem_128x128.sv \
  mem_8192x64.sv \
  sram_64x1144.sv \
]

if {$selected_sram_lib ne "" && ![path_list_contains $library_files $selected_sram_lib]} {
  lappend library_files $selected_sram_lib
}

if {![file exists $filelist]} {
  puts stderr "ERROR: Cannot find Verilog file list: $filelist"
  exit 1
}

if {[llength $library_files] == 0} {
  puts stderr "ERROR: Please set DC_LIBS or PTPX_LIBS to one or more technology libraries."
  puts stderr "       Example: export DC_LIBS=/path/stdcell.db:/path/memories.db"
  exit 1
}

if {$enable_sram_wrappers && $selected_sram_lib eq ""} {
  puts stderr "WARNING: SRAM wrappers are enabled, but no SRAM .db was found under [file join $script_dir db]."
  puts stderr "         Behavioral memories will be left untouched."
}

if {$enable_sram_wrappers && $selected_sram_lib ne "" && ![file exists $sram_wrapper_file]} {
  puts stderr "ERROR: Cannot find SRAM wrapper source: $sram_wrapper_file"
  exit 1
}

set use_sram_wrappers [expr {$enable_sram_wrappers && $selected_sram_lib ne ""}]

file mkdir $output_dir
file mkdir $report_dir
file mkdir $work_dir

if {$max_cores ne ""} {
  set_host_options -max_cores $max_cores
}

set_app_var search_path [concat [list . $verilog_dir] $extra_search_path]
set_app_var target_library $library_files
set synthetic_library_files [list dw_foundation.sldb]
set_app_var synthetic_library $synthetic_library_files
set_app_var link_library [concat [list *] $library_files $synthetic_library_files]

define_design_lib WORK -path $work_dir

set fp [open $filelist r]
set filelist_text [read $fp]
close $fp

set rtl_files {}
set include_dirs [list $verilog_dir]
set filelist_defines {}
foreach raw_line [split $filelist_text "\n"] {
  set line [string trim $raw_line]
  if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} {
    continue
  }
  if {[string match "+incdir+*" $line]} {
    foreach incdir [split [string range $line 8 end] "+"] {
      if {$incdir ne ""} {
        lappend include_dirs [normalize_source_path $verilog_dir $incdir]
      }
    }
    continue
  }
  if {[string match "+define+*" $line]} {
    foreach macro [split [string range $line 8 end] "+"] {
      if {$macro ne ""} {
        lappend filelist_defines $macro
      }
    }
    continue
  }
  set ext [string tolower [file extension $line]]
  if {$ext ni {.sv .v .svh .vh}} {
    continue
  }
  lappend rtl_files [normalize_source_path $verilog_dir $line]
}

if {[llength $rtl_files] == 0} {
  puts stderr "ERROR: No Verilog/SystemVerilog source files found in $filelist"
  exit 1
}

set sv_file_count 0
set v_file_count 0
set design_files {}

if {$use_sram_wrappers} {
  lappend design_files $sram_wrapper_file
  incr sv_file_count
  puts "Using SRAM replacement wrappers from $sram_wrapper_file"
  puts "Selected SRAM library: $selected_sram_lib"
}

foreach rtl_file $rtl_files {
  set rtl_basename [file tail $rtl_file]
  if {$use_sram_wrappers && [lsearch -exact $replaced_memory_basenames $rtl_basename] >= 0} {
    puts "Skipping $rtl_file because it is replaced by instantiated SRAM wrappers."
    continue
  }

  set ext [string tolower [file extension $rtl_file]]
  if {$ext in {.svh .vh}} {
    continue
  }
  if {![file_has_design $rtl_file]} {
    puts "Skipping $rtl_file because it does not define a design."
    continue
  }
  if {[file_has_dpi_import $rtl_file]} {
    puts "Skipping $rtl_file because Design Compiler should not synthesize DPI simulation modules."
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

set combined_source [file join $report_dir dc_combined_sources.sv]
set combined_fp [open $combined_source w]
puts $combined_fp "// Generated by dc_synth.tcl. Do not edit."
puts $combined_fp "`define SYNTHESIS 1"
foreach macro [concat $filelist_defines $extra_defines] {
  write_macro_define $combined_fp $macro
}
foreach design_file $design_files {
  puts $combined_fp "`include \"$design_file\""
}
close $combined_fp

set_app_var search_path [concat [list . $verilog_dir] [lsort -unique $include_dirs] $extra_search_path]

puts "Analyzing $sv_file_count SystemVerilog files and $v_file_count Verilog files from $filelist"
analyze -format sverilog -work WORK $combined_source
elaborate $top_module -work WORK
current_design $top_module
link

set clock_objs [get_ports -quiet $clock_port]
if {[sizeof_collection $clock_objs] > 0} {
  create_clock -name core_clock -period $clock_period_ns $clock_objs
} else {
  puts stderr "WARNING: Clock port '$clock_port' was not found; mapped netlist will be generated without an explicit clock."
}

check_design > [file join $report_dir check_design_pre_compile.rpt]
check_timing > [file join $report_dir check_timing_pre_compile.rpt]

uniquify
set_fix_multiple_port_nets -all -buffer_constants

puts "Running DC compile command: $compile_command"
eval $compile_command

change_names -rules verilog -hierarchy

write -format ddc -hierarchy -output [file join $output_dir ${top_module}.ddc]
write -format verilog -hierarchy -output [file join $output_dir ${top_module}.mapped.v]
write_sdc [file join $output_dir ${top_module}.sdc]

report_qor > [file join $report_dir qor.rpt]
report_area -hierarchy > [file join $report_dir area_hierarchy.rpt]
report_timing -max_paths 50 > [file join $report_dir timing.rpt]
report_reference -hierarchy > [file join $report_dir reference_hierarchy.rpt]
check_design > [file join $report_dir check_design_post_compile.rpt]
check_timing > [file join $report_dir check_timing_post_compile.rpt]

set sram_mapping_report [file join $report_dir sram_mapping.rpt]
set sram_cells [get_cells -hierarchical -quiet -filter "ref_name == $sram_macro_cell"]
set sram_instance_count [sizeof_collection $sram_cells]
set sram_fp [open $sram_mapping_report w]
puts $sram_fp "SRAM wrappers enabled: $use_sram_wrappers"
puts $sram_fp "Selected SRAM library: $selected_sram_lib"
puts $sram_fp "SRAM macro cell: $sram_macro_cell"
puts $sram_fp "SRAM macro instances after compile: $sram_instance_count"
if {$use_sram_wrappers} {
  puts $sram_fp "Replaced behavioral memory sources:"
  foreach basename $replaced_memory_basenames {
    puts $sram_fp "  $basename"
  }
}
if {$sram_instance_count > 0} {
  puts $sram_fp ""
  puts $sram_fp "SRAM macro instances:"
  foreach_in_collection sram_cell_inst $sram_cells {
    puts $sram_fp [get_object_name $sram_cell_inst]
  }
}
close $sram_fp

if {$use_sram_wrappers} {
  if {$sram_instance_count > 0} {
    puts "Instantiated $sram_instance_count SRAM macro cells of type $sram_macro_cell."
  } else {
    puts stderr "WARNING: SRAM wrappers were enabled, but no $sram_macro_cell instances were found after compile."
  }
}

puts "DC synthesis completed."
puts "Mapped netlist: [file join $output_dir ${top_module}.mapped.v]"
puts "DDC: [file join $output_dir ${top_module}.ddc]"
puts "SDC: [file join $output_dir ${top_module}.sdc]"
puts "Reports are under: $report_dir"
