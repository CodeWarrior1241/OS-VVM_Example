# ================================================================================
# OSVVM Ethernet FIFO Simulation - Vivado Simulator (XSim) Launcher
# ================================================================================
# Runs the same OSVVM constrained-random Ethernet frame loopback test as
# run_sim.sh (Questa), but on the Vivado simulator (xvhdl/xvlog/xelab/xsim).
#
# Usage - any of:
#   1. From the Vivado TCL console:
#        cd {path/to/OS-VVM_Test/sim}
#        source run_sim.tcl
#   2. From the Vivado command line (batch):
#        vivado -mode batch -source sim/run_sim.tcl
#   3. Independently (no Vivado session, xsim tools resolved from the
#      install or XILINX_VIVADO):
#        tclsh sim/run_sim.tcl
#
#   Optional arguments:
#     -gui        opens xsim in GUI mode with the AXIS waves
#     -full_sim   simulates the FULL block design (both Ethernet subsystems
#                 incl. GT SecureIP) with the bring-up test instead of the
#                 FIFO-datapath testbench (see README 5.4)
#        vivado -mode batch -source sim/run_sim.tcl -tclargs -gui
#        tclsh sim/run_sim.tcl -full_sim
#
# The OSVVM libraries are compiled with OSVVM's own scripting system
# (StartXSIM.tcl), cached under xsim_work/VHDL_LIBS. All XSim artifacts
# live in sim/xsim_work/ so the Questa flow (run_sim.sh) is untouched.
#
# Prerequisite: the Vivado project must have been built first
#   (cd .. && vivado -mode batch -source build_all.tcl)
# ================================================================================

# --- Locate ourselves (works for source, -source, and tclsh) ---------------
set sim_dir [file normalize [file dirname [info script]]]
set project_root [file normalize "$sim_dir/.."]
set osvvm_dir "$project_root/deps/OsvvmLibraries"
set vivado_gen_dir "$project_root/OSVVM_Ethernet_Sim.gen/sources_1/bd/Top"

# --- Parse arguments -------------------------------------------------------
set xsim_gui 0
set full_sim 0
if {[info exists ::argv]} {
    foreach arg $::argv {
        if {$arg eq "-gui"} { set xsim_gui 1 }
        if {$arg eq "-full_sim" || $arg eq "--full_sim"} { set full_sim 1 }
    }
}

# --- Make sure the RIGHT xsim tools are reachable --------------------------
# The xsim libraries (.vdb) are version-locked: OSVVM and the DUT are
# compiled by Vivado 2026.1, and an older xvhdl/xelab -- e.g. resolved
# through an XILINX_VIVADO that points at another release -- fails with
# "forward compatibility is not supported". So the release that built the
# project is PREPENDED to PATH whenever it exists locally, taking priority
# over whatever xvhdl the environment happens to offer; XILINX_VIVADO and
# bare PATH remain as fallbacks for other machines.
proc have_tool {tool} {
    return [expr {![catch {exec $tool --version}]}]
}
set preferred_vivado "/media/fpgadev/Dev_Tools/Xilinx/2026.1/Vivado"
if {[file isdirectory "$preferred_vivado/bin"]} {
    set ::env(PATH) "$preferred_vivado/bin:$::env(PATH)"
}
if {![have_tool xvhdl]} {
    if {[info exists ::env(XILINX_VIVADO)]} {
        set ::env(PATH) "$::env(XILINX_VIVADO)/bin:$::env(PATH)"
    }
    if {![have_tool xvhdl]} {
        error "run_sim.tcl: xvhdl not found - add Vivado/bin to PATH or set XILINX_VIVADO"
    }
}

# --- Check that the Vivado project has been built (DUT netlist exists) -----
set dut_netlist "$vivado_gen_dir/ip/Top_Axis_Frame_Fifo_0/sim/Top_Axis_Frame_Fifo_0.v"
if {![file exists $dut_netlist]} {
    error "run_sim.tcl: DUT netlist not found:\n  $dut_netlist\nBuild the Vivado project first:\n  cd $project_root && vivado -mode batch -source build_all.tcl"
}

# --- Isolated XSim working directory ---------------------------------------
set xsim_work "$sim_dir/xsim_work"
file mkdir $xsim_work
set orig_dir [pwd]
cd $xsim_work

puts "=========================================="
puts "OSVVM Ethernet FIFO XSim Simulation"
puts "Work dir: $xsim_work"
puts "Mode:     [expr {$xsim_gui ? "GUI" : "batch"}][expr {$full_sim ? " FULL-BD (GT SecureIP)" : ""}]"
puts "=========================================="

# ================================================================================
# 1) OSVVM libraries via the OSVVM scripting system (XSim vendor scripts)
# ================================================================================
# First run compiles osvvm + Common (osvvm_common) + AXI4 (osvvm_axi4) with
# xvhdl into ./VHDL_LIBS + ./xsim.dir; later runs reuse the cache.
if {![file isdirectory "$xsim_work/VHDL_LIBS"]} {
    puts "run_sim.tcl: building OSVVM libraries for XSim (first run)..."
    source $osvvm_dir/Scripts/StartXSIM.tcl
    build $osvvm_dir/osvvm
    build $osvvm_dir/Common
    build $osvvm_dir/AXI4
} else {
    puts "run_sim.tcl: reusing cached OSVVM XSim libraries in xsim_work/VHDL_LIBS/"
}

proc run_tool {args} {
    puts "  $args"
    if {[catch {exec {*}$args 2>@1} msg]} {
        # exec throws whenever the tool writes to stderr; check for real errors
        if {[string match "*ERROR*" $msg] || [string match "*CRITICAL*" $msg]} {
            error "run_sim.tcl: [lindex $args 0] failed:\n$msg"
        }
        puts $msg
    } else {
        if {$msg ne ""} { puts $msg }
    }
}

# ================================================================================
# FULL block-design simulation (-full_sim): the complete BD -- both AXI
# Ethernet subsystems (TEMAC + PCS/PMA + GT SecureIP), clocking, FIFO and
# Frame_Stats -- compiled from the Vivado-generated scripts and driven by
# the OSVVM bring-up testbench (TbFullBd / TestCtrl_FullBringup). XSim's
# shipped precompiled libraries provide unisim/secureip/IP static code.
# ================================================================================
if {$full_sim} {
    set expx "$project_root/OSVVM_Ethernet_Sim.sim/sim_1/behav/xsim"

    # Vivado-generated compile scripts (regenerate if absent).
    # full_sim_export.tcl is the shared internal dependency of both
    # simulator flows: when this script is already running inside a Vivado
    # session (TCL console or vivado -mode batch), source it directly --
    # no second Vivado process; under plain tclsh, launch a batch Vivado.
    if {![file exists "$expx/Top_wrapper_vlog.prj"]} {
        if {[llength [info commands launch_simulation]]} {
            puts "run_sim.tcl: exporting full-sim compile scripts (in this Vivado session)..."
            source "$sim_dir/full_sim_export.tcl"
        } else {
            puts "run_sim.tcl: exporting full-sim compile scripts via Vivado (one-time)..."
            run_tool vivado -mode batch -nojournal -nolog -source "$sim_dir/full_sim_export.tcl"
        }
    }

    # xsim.ini in the exported dir resolves shipped libraries via RDI_DATADIR
    set xvhdl_bin [lindex [auto_execok xvhdl] 0]
    set ::env(RDI_DATADIR) [file normalize [file join [file dirname $xvhdl_bin] .. data]]

    # Compile the complete BD with the Vivado-generated script (absolute paths)
    puts "run_sim.tcl: compiling the full block design..."
    cd $expx
    if {[catch {exec bash compile.sh > full_bd_compile.log 2>@1} msg]} {
        error "run_sim.tcl: full-BD compile failed - see $expx/full_bd_compile.log\n$msg"
    }

    # Make the cached OSVVM libraries visible in this xsim.ini context
    set fp [open "$expx/xsim.ini" r] ; set ini [read $fp] ; close $fp
    set additions ""
    foreach lib {osvvm osvvm_common osvvm_axi4} {
        if {![regexp -line "^$lib=" $ini]} {
            append additions "$lib=$xsim_work/xsim.dir/$lib\n"
        }
    }
    if {$additions ne ""} {
        set fp [open "$expx/xsim.ini" a] ; puts -nonewline $fp $additions ; close $fp
    }

    # Compile the full-BD OSVVM testbench
    run_tool xvhdl --2008 --relax -work tb_full "$sim_dir/tb/CsrAxiLiteManager.vhd"
    run_tool xvhdl --2008 --relax -work tb_full "$sim_dir/tb/TestCtrlFull_e.vhd"
    run_tool xvhdl --2008 --relax -work tb_full "$sim_dir/tb/TbFullBd.vhd"
    run_tool xvhdl --2008 --relax -work tb_full "$sim_dir/tb/TestCtrl_FullBringup.vhd"

    # Elaborate with the exact -L library list Vivado generated
    set fp [open "$expx/elaborate.sh" r] ; set etxt [read $fp] ; close $fp
    set lflags {}
    foreach {m name} [regexp -all -inline -- {-L (\w+)} $etxt] {
        if {[lsearch -exact $lflags $name] < 0} { lappend lflags $name }
    }
    set largs {}
    foreach name $lflags { lappend largs -L $name }
    puts "run_sim.tcl: elaborating TbFullBd (loads GT SecureIP)..."
    run_tool xelab --incr --relax --mt 8 {*}$largs -L tb_full \
        -timeprecision_vhdl 1ps \
        --snapshot TbFullBd_full tb_full.TbFullBd xil_defaultlib.glbl

    # OSVVM's EndOfTestReports appends to OsvvmTemp_<tool>/OsvvmRun.yml and
    # fatals if it does not exist (normally created by the OSVVM scripting
    # environment, which this flow bypasses)
    file mkdir "$expx/OsvvmTemp_XSIM"
    if {![file exists "$expx/OsvvmTemp_XSIM/OsvvmRun.yml"]} {
        close [open "$expx/OsvvmTemp_XSIM/OsvvmRun.yml" w]
    }

    # Run
    if {$xsim_gui} {
        puts "  xsim TbFullBd_full -gui"
        exec xsim TbFullBd_full -gui &
        puts "run_sim.tcl: xsim GUI launched (full-BD bring-up test)"
    } else {
        set start_ms [clock milliseconds]
        puts "  xsim TbFullBd_full -runall"
        if {[catch {exec xsim TbFullBd_full -runall 2>@1} sim_out]} {
            puts $sim_out
            error "run_sim.tcl: xsim failed"
        }
        puts $sim_out
        set elapsed [format "%.2f" [expr {([clock milliseconds] - $start_ms) / 1000.0}]]
        puts "=========================================="
        puts "Full-BD Simulation Complete!"
        puts "Wall clock time: $elapsed seconds"
        puts "=========================================="
        if {![string match "*DONE   PASSED*" $sim_out] && ![string match "*DONE  PASSED*" $sim_out]} {
            error "run_sim.tcl: full-BD test did not report DONE PASSED - inspect the transcript above"
        }
    }

    cd $orig_dir
    puts "run_sim.tcl: done (full-BD)"
} else {
# ================================================================================
# 2) Xilinx prerequisites + DUT netlist (Verilog side)
# ================================================================================
# XSim ships precompiled xpm/unisim libraries, so only glbl and the FIFO
# Generator model + instance netlist need compiling.

if {[info exists ::env(XILINX_VIVADO)]} {
    set glbl_src "$::env(XILINX_VIVADO)/data/verilog/src/glbl.v"
} else {
    set glbl_src "/media/fpgadev/Dev_Tools/Xilinx/2026.1/Vivado/data/verilog/src/glbl.v"
}

set fifo_beh [lindex [glob "$vivado_gen_dir/ipshared/*/simulation/fifo_generator_vlog_beh.v"] 0]
set fifo_rfs [lindex [glob "$vivado_gen_dir/ipshared/*/hdl/fifo_generator_v13_2_vl_sim_rfs.v"] 0]

run_tool xvlog -work fifo_dut $glbl_src
run_tool xvlog -work fifo_dut $fifo_beh
run_tool xvlog -work fifo_dut $fifo_rfs
run_tool xvlog -work fifo_dut $dut_netlist

# ================================================================================
# 3) OSVVM testbench (VHDL-2008)
# ================================================================================

# open-logic sources + the project frame_stats RTL (same library as the TB;
# open-logic uses plain `work` references internally)
set olo_dir "$project_root/deps/open-logic/src"
run_tool xvhdl --2008 -work tb_eth "$olo_dir/base/vhdl/olo_base_pkg_array.vhd"
run_tool xvhdl --2008 -work tb_eth "$olo_dir/base/vhdl/olo_base_pkg_math.vhd"
run_tool xvhdl --2008 -work tb_eth "$olo_dir/base/vhdl/olo_base_pkg_logic.vhd"
run_tool xvhdl --2008 -work tb_eth "$olo_dir/base/vhdl/olo_base_pkg_string.vhd"
run_tool xvhdl --2008 -work tb_eth "$olo_dir/axi/vhdl/olo_axi_pkg_protocol.vhd"
run_tool xvhdl --2008 -work tb_eth "$olo_dir/axi/vhdl/olo_axi_lite_slave.vhd"
run_tool xvhdl --2008 -work tb_eth "$project_root/rtl/frame_stats.vhd"

run_tool xvhdl --2008 -work tb_eth "$sim_dir/tb/EthFramePkg.vhd"
run_tool xvhdl --2008 -work tb_eth "$sim_dir/tb/CsrAxiLiteManager.vhd"
run_tool xvhdl --2008 -work tb_eth "$sim_dir/tb/TestCtrl_e.vhd"
run_tool xvhdl --2008 -work tb_eth "$sim_dir/tb/TbEthernetFifo.vhd"
run_tool xvhdl --2008 -work tb_eth "$sim_dir/tb/TestCtrl_FrameLoopback.vhd"

# ================================================================================
# 4) Elaborate and run
# ================================================================================

# GUI runs need debug info in the snapshot so add_wave can reach the
# frame_stats internals; batch runs stay lean without it
set dbg_args [expr {$xsim_gui ? [list --debug typical] : [list]}]
run_tool xelab tb_eth.TbEthernetFifo fifo_dut.glbl \
    -L fifo_dut -L xpm -L unisims_ver \
    -timeprecision_vhdl 1ps \
    {*}$dbg_args \
    -s TbEthernetFifo_sim

if {$xsim_gui} {
    # GUI: log the AXIS interface waves and hand control to the user
    set wcfg_do "$xsim_work/xsim_waves.tcl"
    set fp [open $wcfg_do w]
    puts $fp {add_wave /TbEthernetFifo/Clk /TbEthernetFifo/nReset}
    puts $fp {add_wave /TbEthernetFifo/SAxisTValid /TbEthernetFifo/SAxisTReady /TbEthernetFifo/SAxisTData /TbEthernetFifo/SAxisTKeep /TbEthernetFifo/SAxisTLast}
    puts $fp {add_wave /TbEthernetFifo/MAxisTValid /TbEthernetFifo/MAxisTReady /TbEthernetFifo/MAxisTData /TbEthernetFifo/MAxisTKeep /TbEthernetFifo/MAxisTLast}
    puts $fp {add_wave -radix unsigned /TbEthernetFifo/FrameStats_1/FramesIn /TbEthernetFifo/FrameStats_1/FramesOut /TbEthernetFifo/FrameStats_1/BytesIn /TbEthernetFifo/FrameStats_1/BytesOut /TbEthernetFifo/FrameStats_1/StallIn /TbEthernetFifo/FrameStats_1/StallOut}
    puts $fp {run all}
    close $fp
    puts "  xsim TbEthernetFifo_sim -gui"
    exec xsim TbEthernetFifo_sim -gui -tclbatch $wcfg_do &
    puts "run_sim.tcl: xsim GUI launched (runs to completion, then interactive)"
} else {
    # Batch: run to the OSVVM std.env.stop and echo the transcript
    set start_ms [clock milliseconds]
    puts "  xsim TbEthernetFifo_sim -runall"
    if {[catch {exec xsim TbEthernetFifo_sim -runall 2>@1} sim_out]} {
        puts $sim_out
        error "run_sim.tcl: xsim failed"
    }
    puts $sim_out
    set elapsed [format "%.2f" [expr {([clock milliseconds] - $start_ms) / 1000.0}]]

    puts "=========================================="
    puts "Simulation Complete!"
    puts "Wall clock time: $elapsed seconds"
    puts "=========================================="

    # Propagate an unambiguous pass/fail to the caller
    if {![string match "*DONE   PASSED*" $sim_out] && ![string match "*DONE  PASSED*" $sim_out]} {
        error "run_sim.tcl: test did not report DONE PASSED - inspect the transcript above"
    }
}

cd $orig_dir
puts "run_sim.tcl: done"
}
# end if !full_sim
