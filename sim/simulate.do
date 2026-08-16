# ================================================================================
# OSVVM Ethernet FIFO Simulation - Questa Simulation Script
# ================================================================================
# Runs the OSVVM constrained-random Ethernet frame loopback test on the
# FIFO Generator datapath DUT.
#
# Usage (via run_sim.sh / run_sim.bat):
#   ./run_sim.sh                    Fast mode, batch of coverage-driven frames
#   ./run_sim.sh --detailed         Full signal visibility (+acc) with waveforms
#
# Direct usage:
#   vsim -do simulate.do
#   vsim -c -do "set BATCH_MODE yes; do simulate.do; quit -f"
#
# The test is coverage-driven and stops itself via std.env.stop when the
# OSVVM ControlProc barrier completes, so the default run time is "-all".
# ================================================================================

# Batch mode: abort with a nonzero exit code on any script error so CI and
# shell callers see the failure instead of a hung interactive prompt.
if {[info exists BATCH_MODE] && $BATCH_MODE eq "yes"} {
    onerror {quit -code 1 -f}
}

# Source the compilation script first
do compile.do

# ================================================================================
# Simulation Parameters
# ================================================================================

# The OSVVM test self-terminates (std.env.stop) when coverage closes or the
# 30 ms watchdog expires, so run -all is the natural default.
if {![info exists SIM_TIME]} {
    set SIM_TIME "-all"
}

# Detailed mode: "yes" = full signal visibility (+acc) with waveforms
if {![info exists DETAILED]} {
    set DETAILED "no"
}

if {$DETAILED eq "yes"} {
    set acc_flag "+acc"
    set mode_str "DETAILED (+acc, full signal visibility)"
} else {
    set acc_flag "+acc=rn"
    set mode_str "FAST (+acc=rn, no waveforms)"
}

puts "=========================================="
puts "Starting OSVVM Ethernet FIFO Simulation..."
puts "Mode:            $mode_str"
puts "Simulation time: $SIM_TIME"
puts "=========================================="

# ================================================================================
# Elaborate and Load Design
# ================================================================================

# VHDL library references (osvvm, osvvm_common, osvvm_axi4) resolve through
# the ./modelsim.ini mappings created by the OSVVM build in compile.do.
# -L switches cover mixed-language default binding of the Verilog DUT.
vopt -l elaborate.log $acc_flag \
    -L fifo_dut \
    -L xpm \
    -work tb_eth \
    tb_eth.TbEthernetFifo fifo_dut.glbl \
    -o TbEthernetFifo_opt

# Load the optimized design (1 ps resolution required by the Verilog IP model).
# vsim-8683 (uninitialized inout port has no driver) fires on OSVVM MIT
# transaction-record fields the CSR manager VVC does not use - benign.
vsim -t 1ps -suppress 8683 -lib tb_eth TbEthernetFifo_opt

# Suppress numeric std warnings
set NumericStdNoWarnings 1
set StdArithNoWarnings 1

# ================================================================================
# Add Waveforms (detailed mode only)
# ================================================================================

if {$DETAILED eq "yes"} {

add wave -divider "Clock & Reset"
add wave /TbEthernetFifo/Clk
add wave /TbEthernetFifo/nReset

add wave -divider "S_AXIS (OSVVM Transmitter -> FIFO)"
add wave /TbEthernetFifo/SAxisTValid
add wave /TbEthernetFifo/SAxisTReady
add wave -hex /TbEthernetFifo/SAxisTData
add wave -hex /TbEthernetFifo/SAxisTKeep
add wave /TbEthernetFifo/SAxisTLast

add wave -divider "M_AXIS (FIFO -> OSVVM Receiver)"
add wave /TbEthernetFifo/MAxisTValid
add wave /TbEthernetFifo/MAxisTReady
add wave -hex /TbEthernetFifo/MAxisTData
add wave -hex /TbEthernetFifo/MAxisTKeep
add wave /TbEthernetFifo/MAxisTLast

add wave -divider "Frame_Stats counters (live CSR values)"
add wave -unsigned /TbEthernetFifo/FrameStats_1/FramesIn
add wave -unsigned /TbEthernetFifo/FrameStats_1/FramesOut
add wave -unsigned /TbEthernetFifo/FrameStats_1/BytesIn
add wave -unsigned /TbEthernetFifo/FrameStats_1/BytesOut
add wave -unsigned /TbEthernetFifo/FrameStats_1/StallIn
add wave -unsigned /TbEthernetFifo/FrameStats_1/StallOut

configure wave -namecolwidth 400
configure wave -valuecolwidth 120
configure wave -signalnamewidth 1

view wave
view structure
view signals

}
# end if DETAILED

# ================================================================================
# Run Simulation
# ================================================================================

# Record start time
set start_time [clock milliseconds]

# Run simulation (test self-terminates via OSVVM std.env.stop)
if {$SIM_TIME eq "-all"} {
    run -all
} else {
    run $SIM_TIME
}

# Calculate and display wall clock time
set end_time [clock milliseconds]
set elapsed_ms [expr {$end_time - $start_time}]
set elapsed_sec [format "%.2f" [expr {$elapsed_ms / 1000.0}]]

puts "=========================================="
puts "Simulation Complete!"
puts "Wall clock time: $elapsed_sec seconds"
puts "=========================================="

if {$DETAILED eq "yes"} {
    catch {wave zoom full}
}
