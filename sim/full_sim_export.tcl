# ================================================================================
# OSVVM Ethernet FIFO Simulation - Full-BD Script Export (--full_sim support)
# ================================================================================
# INTERNAL dependency file, shared by BOTH simulator flows -- run_sim.sh
# (Questa) and run_sim.tcl (XSim) invoke it automatically when the exported
# scripts are missing; it is not meant to be run by hand (though it can be:
# vivado -mode batch -source full_sim_export.tcl).
#
# Generates simulator compile/elaborate scripts for the COMPLETE block design
# (both AXI Ethernet subsystems incl. GT SecureIP, clocking, FIFO,
# Frame_Stats) using Vivado's own simulation-script writer, so the file list
# and library ordering always match the generated IP exactly.
#
# Callable two ways:
#   * sourced INSIDE a Vivado session (run_sim.tcl does this when it is
#     already running under Vivado) -- reuses the open project if it is this
#     one, opens/closes it otherwise
#   * vivado -mode batch -source full_sim_export.tcl (run_sim.sh, and
#     run_sim.tcl under plain tclsh, launch it this way)
#
# Outputs (consumed by run_sim.sh --full_sim and run_sim.tcl -full_sim):
#   <project>.sim/sim_1/behav/questa/  Top_wrapper_compile.do + modelsim.ini
#   <project>.sim/sim_1/behav/xsim/    Top_wrapper_vlog.prj / _vhdl.prj +
#                                      elaborate.sh (xelab -L list)
#
# The Questa scripts reference the precompiled Xilinx simulation libraries
# (compile_simlib output); see QUESTA_COMPILED_LIBS below.
# ================================================================================

set sim_dir [file normalize [file dirname [info script]]]
set project_root [file normalize "$sim_dir/.."]
set project_xpr "$project_root/OSVVM_Ethernet_Sim.xpr"

# Precompiled Xilinx libraries for Questa (compile_simlib output).
# Generation path (already done on this machine, documented in README):
#   compile_simlib -simulator questa -simulator_exec_path <questa>/bin \
#       -family artixuplus -library all -dir <target_dir>
set QUESTA_COMPILED_LIBS \
    "/media/fpgadev/Dev_Tools/Mentor_Graphics/Questa_Libraries_Vivado_2026.1/Questa_Libraries_Vivado"

if {![file exists $project_xpr]} {
    error "full_sim_export.tcl: $project_xpr not found - run the Vivado build first (vivado -mode batch -source build_all.tcl)"
}
if {![file isdirectory $QUESTA_COMPILED_LIBS]} {
    error "full_sim_export.tcl: precompiled Questa libraries not found at\n  $QUESTA_COMPILED_LIBS\nGenerate them with compile_simlib (see README)."
}

# Reuse the project if this session already has it open (run_sim.tcl
# sourcing us from the Vivado TCL console); otherwise open it and close it
# again when done, leaving the session as we found it.
set opened_here 0
if {[catch {get_property NAME [current_project]} cur_proj] || $cur_proj ne "OSVVM_Ethernet_Sim"} {
    open_project $project_xpr
    set opened_here 1
}

# launch_simulation operates on the ACTIVE simulation fileset. The build
# leaves sim_tb (the OSVVM testbench fileset, for GUI browsing) active, but
# those testbenches cannot compile under Vivado (OSVVM lives outside the
# project) -- the export must run on the DUT-only sim_1. Switch, export,
# and restore the previously active simset at the end.
set prev_simset [current_fileset -simset]
current_fileset -simset [get_filesets sim_1]

# The build flow never simulates from the project, so sim_1 has no top yet:
# simulate the BD wrapper (the whole design) as the DUT.
set_property top Top_wrapper [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1

# Questa scripts (reference the precompiled libraries)
set_property target_simulator Questa [current_project]
set_property compxlib.questa_compiled_library_dir $QUESTA_COMPILED_LIBS [current_project]
launch_simulation -scripts_only -absolute_path
close_sim -quiet

# XSim scripts (XSim ships its own precompiled Xilinx libraries)
set_property target_simulator XSim [current_project]
launch_simulation -scripts_only -absolute_path
close_sim -quiet

current_fileset -simset $prev_simset

if {$opened_here} {
    close_project
} else {
    puts "full_sim_export.tcl: note - this session's project settings were touched (target_simulator, sim_1 top)"
}
puts "full_sim_export.tcl: simulation scripts exported"
