#!/usr/bin/env bash
# ================================================================================
# OSVVM Ethernet FIFO Simulation - Questa Launcher (Unix/Linux/macOS)
# ================================================================================
# Launches the OSVVM constrained-random Ethernet frame loopback simulation.
#
# The test is COVERAGE-DRIVEN: it sends constrained-random frames until the
# OSVVM functional coverage models (frame size, error injection, inter-frame
# gap, size-x-error cross) all reach 100%, then self-checks and stops.
#
# Two simulation modes are available:
#
#   DEFAULT (fast):   +acc=rn optimization, no waveform logging.
#                     Suitable for functional pass/fail runs where the
#                     OSVVM transcript/report output is all that is needed.
#
#  ./run_sim.sh                    # +acc=rn, no waveforms
#  ./run_sim.sh --batch            # same, headless
#
#   DETAILED:         +acc optimization, waveform logging of the AXIS
#                     interfaces. Use for debugging and demonstrations.
#
#  ./run_sim.sh --detailed         # +acc, waveforms
#  ./run_sim.sh --detailed --batch # same, headless
#
# ================================================================================

set -e

# Configuration
VSIM="${VSIM:-vsim}"
SIM_MODE="gui"
# The OSVVM test self-terminates when functional coverage closes (or its
# 30 ms watchdog fires), so the default is to run until std.env.stop.
SIM_TIME="-all"
DETAILED="no"
FULL_SIM="no"

# Change to script directory
cd "$(dirname "$0")"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --time)
            SIM_TIME="$2"
            shift 2
            ;;
        --gui)
            SIM_MODE="gui"
            shift
            ;;
        --batch)
            SIM_MODE="batch"
            shift
            ;;
        --detailed)
            DETAILED="yes"
            shift
            ;;
        --full_sim)
            FULL_SIM="yes"
            shift
            ;;
        --clean)
            echo "Cleaning work directories and simulation artifacts..."
            rm -rf questa_lib VHDL_LIBS logs work reports results
            rm -f *.wlf *.log *.vstf transcript modelsim.ini *.yml *.html vsim_stacktrace.vstf
            echo "Done."
            exit 0
            ;;
        --help)
            echo "OSVVM Ethernet FIFO Questa Simulation Script"
            echo ""
            echo "Usage: ./run_sim.sh [options]"
            echo ""
            echo "Options:"
            echo "  --time TIME    Set simulation time (default: -all, coverage-driven)"
            echo "  --gui          Run in GUI mode (default)"
            echo "  --batch        Run in batch/command-line mode"
            echo "  --detailed     Full signal visibility (+acc) with waveforms"
            echo "  --full_sim     Simulate the FULL block design (both Ethernet"
            echo "                 subsystems incl. GT SecureIP) instead of the"
            echo "                 FIFO-datapath testbench. Needs the precompiled"
            echo "                 Xilinx Questa libraries (see README 5.4)."
            echo "  --clean        Remove work directories and generated files"
            echo "  --help         Show this help message"
            echo ""
            echo "Examples:"
            echo "  ./run_sim.sh                       Run coverage-driven (GUI, +acc=rn)"
            echo "  ./run_sim.sh --detailed            Run with waveforms"
            echo "  ./run_sim.sh --batch               Run headless until coverage closes"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if Questa/Vsim is available; fall back to the known local install
if ! command -v "$VSIM" &> /dev/null; then
    QUESTA_FALLBACK="/media/fpgadev/Dev_Tools/Mentor_Graphics/Questa_2025.1/questasim/bin/vsim"
    if [ -x "$QUESTA_FALLBACK" ]; then
        VSIM="$QUESTA_FALLBACK"
        echo "INFO: vsim not in PATH, using $VSIM"
    else
        echo "ERROR: Questa (vsim) not found in PATH!"
        echo "Please ensure Questa is installed and added to your system PATH."
        exit 1
    fi
fi

# Check that the Vivado project has been built (DUT netlist exists)
DUT_NETLIST="../OSVVM_Ethernet_Sim.gen/sources_1/bd/Top/ip/Top_Axis_Frame_Fifo_0/sim/Top_Axis_Frame_Fifo_0.v"
if [ ! -f "$DUT_NETLIST" ]; then
    echo "ERROR: DUT netlist not found:"
    echo "  $DUT_NETLIST"
    echo "Build the Vivado project first:"
    echo "  cd .. && vivado -mode batch -source build_all.tcl"
    exit 1
fi

# ================================================================================
# FULL block-design simulation (--full_sim): everything in the BD elaborated
# for real, GT SecureIP included. Uses the Vivado-generated compile scripts
# (sim/full_sim_export.tcl -> <project>.sim/sim_1/behav/questa/) against the
# precompiled Xilinx Questa libraries, then layers the OSVVM bring-up
# testbench (TbFullBd / TestCtrl_FullBringup) on top.
# ================================================================================
if [[ "$FULL_SIM" == "yes" ]]; then
    QBIN="$(cd "$(dirname "$(command -v "$VSIM" || echo "$VSIM")")" && pwd)"
    SIM_DIR="$(pwd)"
    PROJ_ROOT="$(cd .. && pwd)"
    EXPQ="$PROJ_ROOT/OSVVM_Ethernet_Sim.sim/sim_1/behav/questa"

    echo "=========================================="
    echo "OSVVM FULL Block-Design Questa Simulation"
    echo "  (GT SecureIP + all IP, bring-up test)"
    echo "=========================================="

    # 1) Vivado-generated compile scripts (regenerate if absent)
    if [ ! -f "$EXPQ/Top_wrapper_compile.do" ]; then
        VIVADO_BIN="/media/fpgadev/Dev_Tools/Xilinx/2026.1/Vivado/bin/vivado"
        [ -x "$VIVADO_BIN" ] || VIVADO_BIN="$(command -v vivado || true)"
        if [ -z "$VIVADO_BIN" ]; then
            echo "ERROR: full-sim scripts not exported and vivado not found."
            echo "  Run: vivado -mode batch -source sim/full_sim_export.tcl"
            exit 1
        fi
        echo "INFO: exporting full-sim compile scripts (one-time, via Vivado)..."
        "$VIVADO_BIN" -mode batch -nojournal -nolog -source full_sim_export.tcl
    fi

    # 2) OSVVM libraries (shared cache with the fast flow)
    if [ ! -d "$SIM_DIR/VHDL_LIBS" ]; then
        echo "INFO: building OSVVM libraries (first run, a few minutes)..."
        [ -f "$SIM_DIR/modelsim.ini" ] || "$QBIN/vmap" -c > /dev/null
        MODELSIM="$SIM_DIR/modelsim.ini" "$VSIM" -c -do "source ../deps/OsvvmLibraries/Scripts/StartUp.tcl; build ../deps/OsvvmLibraries/osvvm; build ../deps/OsvvmLibraries/Common; build ../deps/OsvvmLibraries/AXI4; quit -f"
    fi

    # 3) Compile the complete BD (Vivado-generated script, absolute paths,
    #    references the precompiled Xilinx libraries via its modelsim.ini)
    echo "INFO: compiling the full block design..."
    (cd "$EXPQ" && bash compile.sh > full_bd_compile.log 2>&1) || {
        echo "ERROR: full-BD compile failed - see $EXPQ/full_bd_compile.log"
        tail -30 "$EXPQ/full_bd_compile.log"
        exit 1
    }

    # All Questa commands below operate on the exported dir's modelsim.ini,
    # which already maps every precompiled Xilinx library.
    export MODELSIM="$EXPQ/modelsim.ini"

    # 4) Map the OSVVM libraries into that context
    for lib in defaultlib osvvm osvvm_common osvvm_axi4; do
        d="$(ls -d "$SIM_DIR"/VHDL_LIBS/*/"$lib" 2> /dev/null | head -1)"
        if [ -n "$d" ]; then
            (cd "$EXPQ" && "$QBIN/vmap" "$lib" "$d" > /dev/null)
        fi
    done

    # 5) Compile the full-BD OSVVM testbench
    echo "INFO: compiling the OSVVM full-BD testbench..."
    (cd "$EXPQ" \
        && ("$QBIN/vlib" questa_lib/msim/tb_full 2> /dev/null || true) \
        && "$QBIN/vmap" tb_full "$EXPQ/questa_lib/msim/tb_full" > /dev/null \
        && "$QBIN/vcom" -64 -2008 -work tb_full \
            "$SIM_DIR/tb/CsrAxiLiteManager.vhd" \
            "$SIM_DIR/tb/TestCtrlFull_e.vhd" \
            "$SIM_DIR/tb/TbFullBd.vhd" \
            "$SIM_DIR/tb/TestCtrl_FullBringup.vhd")

    # 6) Elaborate: reuse the exact -L library list Vivado generated
    LFLAGS="$(grep -o '\-L [A-Za-z0-9_]*' "$EXPQ/Top_wrapper_elaborate.do" | sort -u | tr '\n' ' ')"
    echo "INFO: elaborating TbFullBd (this loads GT SecureIP)..."
    (cd "$EXPQ" && "$QBIN/vopt" -64 +acc=npr -suppress 10016 \
        $LFLAGS -L tb_full -work tb_full \
        tb_full.TbFullBd xil_defaultlib.glbl -o TbFullBd_opt \
        > full_bd_elaborate.log 2>&1) || {
        echo "ERROR: elaboration failed - see $EXPQ/full_bd_elaborate.log"
        tail -30 "$EXPQ/full_bd_elaborate.log"
        exit 1
    }

    # 7) Run. OSVVM's EndOfTestReports appends to OsvvmTemp_<tool>/OsvvmRun.yml
    # and fatals if the file does not exist (it is normally created by the
    # OSVVM scripting environment, which this flow bypasses).
    mkdir -p "$EXPQ/OsvvmTemp_Questa"
    touch "$EXPQ/OsvvmTemp_Questa/OsvvmRun.yml"
    SIM_DO="set NumericStdNoWarnings 1; set StdArithNoWarnings 1; run -all"
    if [[ "$SIM_MODE" == "batch" ]]; then
        echo "INFO: running (batch)..."
        (cd "$EXPQ" && "$VSIM" -c -t 1ps -suppress 8683 -lib tb_full TbFullBd_opt \
            -do "$SIM_DO; quit -f" | tee full_sim.log)
        if grep -qE "DONE +PASSED" "$EXPQ/full_sim.log"; then
            echo "=========================================="
            echo "Full-BD simulation PASSED"
            echo "=========================================="
        else
            echo "ERROR: full-BD simulation did not report DONE PASSED"
            exit 1
        fi
    else
        echo "INFO: running (GUI)..."
        (cd "$EXPQ" && "$VSIM" -t 1ps -suppress 8683 -lib tb_full TbFullBd_opt \
            -do "$SIM_DO")
    fi
    exit 0
fi

echo "=========================================="
echo "OSVVM Ethernet FIFO Questa Simulation"
echo "=========================================="
echo "Simulation time: $SIM_TIME"
echo "Simulation mode: $SIM_MODE"
echo "Detailed:        $DETAILED"
echo "=========================================="

SIM_VARS="set SIM_TIME {$SIM_TIME}; set DETAILED {$DETAILED}"

if [[ "$SIM_MODE" == "batch" ]]; then
    echo "Running in batch mode..."
    $VSIM -c -do "$SIM_VARS; set BATCH_MODE yes; do simulate.do; quit -f"

    echo ""
    echo "=========================================="
    echo "Simulation complete!"
    echo "=========================================="
else
    echo "Running in GUI mode..."
    $VSIM -do "$SIM_VARS; set BATCH_MODE no; do simulate.do"
fi
