# ================================================================================
# OSVVM Ethernet FIFO Simulation - Questa Compilation Script
# ================================================================================
# Compiles, in order:
#   1. The OSVVM libraries (osvvm, osvvm_common, osvvm_axi4) using OSVVM's own
#      scripting system (deps/OsvvmLibraries/Scripts) -- built once, cached in
#      ./VHDL_LIBS and mapped persistently through ./modelsim.ini
#   2. Xilinx simulation prerequisites: XPM, glbl, and the FIFO Generator
#      behavioral model + the Vivado-generated DUT instance netlist
#      (Top_Axis_Frame_Fifo_0) from the block design
#   3. The OSVVM testbench (harness + TestCtrl) into library tb_eth
#
# Prerequisite: the Vivado project must have been built first
#   (cd .. && vivado -mode batch -source build_all.tcl)
# ================================================================================

set sim_dir [file normalize [pwd]]
set project_root [file normalize "$sim_dir/.."]
set osvvm_dir "$project_root/deps/OsvvmLibraries"
set vivado_gen_dir "$project_root/OSVVM_Ethernet_Sim.gen/sources_1/bd/Top"

# Xilinx install (for XPM and glbl sources)
if {[info exists ::env(XILINX_VIVADO)]} {
    set vivado_install $::env(XILINX_VIVADO)
} else {
    set vivado_install "/media/fpgadev/Dev_Tools/Xilinx/2026.1/Vivado"
}
if {![file isdirectory $vivado_install]} {
    error "compile.do: Vivado install not found at $vivado_install (set XILINX_VIVADO)"
}

# Sanity-check the Vivado build output before compiling anything
set dut_netlist "$vivado_gen_dir/ip/Top_Axis_Frame_Fifo_0/sim/Top_Axis_Frame_Fifo_0.v"
if {![file exists $dut_netlist]} {
    error "compile.do: DUT netlist not found: $dut_netlist - run the Vivado build first (vivado -mode batch -source ../build_all.tcl)"
}

# ================================================================================
# 0) Project-local modelsim.ini
# ================================================================================
# Keep ALL library mappings project-local. Without this, every vmap in
# this script AND inside the OSVVM build silently falls back to modifying
# the Questa installation's global modelsim.ini (with relative paths that
# only resolve from this directory) -- polluting the shared tool install.
if {![file exists "$sim_dir/modelsim.ini"]} {
    vmap -c
}
set ::env(MODELSIM) "$sim_dir/modelsim.ini"

# ================================================================================
# 1) OSVVM libraries via the OSVVM scripting system
# ================================================================================
# First run: compiles osvvm + Common (osvvm_common) + AXI4 (osvvm_axi4 incl.
# the AxiStream VVCs) into ./VHDL_LIBS/<tool>/ and records the library
# mappings in ./modelsim.ini. Subsequent runs reuse the cached libraries
# through the persisted mappings.
if {![file isdirectory "$sim_dir/VHDL_LIBS"]} {
    puts "compile.do: building OSVVM libraries (first run, takes a few minutes)..."
    source $osvvm_dir/Scripts/StartUp.tcl
    build $osvvm_dir/osvvm
    build $osvvm_dir/Common
    build $osvvm_dir/AXI4
} else {
    puts "compile.do: reusing cached OSVVM libraries in VHDL_LIBS/"
    # Re-register the cached OSVVM libraries (defaultlib, osvvm,
    # osvvm_common, osvvm_axi4) in the project-local modelsim.ini, so
    # resolution never depends on mappings left in any other ini.
    foreach libdir [glob -nocomplain -types d "$sim_dir/VHDL_LIBS/*/*"] {
        vmap [file tail $libdir] $libdir
    }
}

# ================================================================================
# 2) Xilinx simulation prerequisites + DUT netlist
# ================================================================================

if {![file isdirectory questa_lib]} { file mkdir questa_lib }

# XPM (referenced by Xilinx IP simulation models)
vlib questa_lib/xpm
vmap xpm questa_lib/xpm
vlog -work xpm -sv \
    "$vivado_install/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \
    "$vivado_install/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv"
vcom -work xpm -2008 "$vivado_install/data/ip/xpm/xpm_VCOMP.vhd"

# FIFO Generator behavioral model + versioned wrapper + BD instance netlist.
# The ipshared subdirectory carries a hash that changes between Vivado
# builds, so glob for it instead of hardcoding.
vlib questa_lib/fifo_dut
vmap fifo_dut questa_lib/fifo_dut

vlog -work fifo_dut "$vivado_install/data/verilog/src/glbl.v"

set fifo_beh [lindex [glob "$vivado_gen_dir/ipshared/*/simulation/fifo_generator_vlog_beh.v"] 0]
set fifo_rfs [lindex [glob "$vivado_gen_dir/ipshared/*/hdl/fifo_generator_v13_2_vl_sim_rfs.v"] 0]
vlog -work fifo_dut $fifo_beh
vlog -work fifo_dut $fifo_rfs
vlog -work fifo_dut $dut_netlist

# ================================================================================
# 3) OSVVM testbench
# ================================================================================

vlib questa_lib/tb_eth
vmap tb_eth questa_lib/tb_eth

# open-logic sources + the project frame_stats RTL, compiled into the same
# library as the testbench (open-logic uses plain `work` references
# internally, and the harness instantiates entity work.frame_stats)
set olo_dir "$project_root/deps/open-logic/src"
vcom -work tb_eth -2008 \
    "$olo_dir/base/vhdl/olo_base_pkg_array.vhd" \
    "$olo_dir/base/vhdl/olo_base_pkg_math.vhd" \
    "$olo_dir/base/vhdl/olo_base_pkg_logic.vhd" \
    "$olo_dir/base/vhdl/olo_base_pkg_string.vhd" \
    "$olo_dir/axi/vhdl/olo_axi_pkg_protocol.vhd" \
    "$olo_dir/axi/vhdl/olo_axi_lite_slave.vhd" \
    "$project_root/rtl/frame_stats.vhd"

vcom -work tb_eth -2008 \
    "$sim_dir/tb/EthFramePkg.vhd" \
    "$sim_dir/tb/CsrAxiLiteManager.vhd" \
    "$sim_dir/tb/TestCtrl_e.vhd" \
    "$sim_dir/tb/TbEthernetFifo.vhd" \
    "$sim_dir/tb/TestCtrl_FrameLoopback.vhd"

puts "compile.do: compilation complete"
