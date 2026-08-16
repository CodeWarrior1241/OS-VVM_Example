###############################################################################
#
# Top-level build script for the OSVVM Ethernet-loopback demonstration project
#
# Synthesizable design: two AXI 1G/2.5G Ethernet Subsystems (SGMII over
# GT transceivers) bridged by an AXI4-Stream FIFO Generator (packet mode).
# The design targets the Alinx AXAU15 board part (xcau15p) but is intended
# for behavioral simulation + synthesis only -- no pinout, no implementation.
#
# Usage (from Vivado TCL console):
#   cd {path/to/OS-VVM_Test}
#   source build_all.tcl
#   build_all
#
# Usage (batch mode -- build_all runs automatically):
#   vivado -mode batch -source build_all.tcl
#
###############################################################################

###############################################################################
# Project configuration (global variables)
###############################################################################

variable project_name "OSVVM_Ethernet_Sim"
variable part "xcau15p-ffvb676-2-e"
variable project_dir [file normalize [file dirname [info script]]]
variable top_level_bd_name "Top"

###############################################################################
# IP version resolution
###############################################################################
#
# create_bd_cell needs a fully-versioned VLNV, but Xilinx bumps IP major.minor
# versions between Vivado releases. Resolve the version against the IP catalog
# at build time: prefer the version this script was validated with, otherwise
# fall back to the newest version in the catalog with a warning. This keeps
# the script working across Vivado releases without editing every
# create_bd_cell call.
#
proc resolve_ip_vlnv {vlnv_base {validated_version ""}} {
    # Exact match on the validated version, if the catalog still ships it
    if {$validated_version ne ""} {
        set exact [get_ipdefs -quiet "${vlnv_base}:${validated_version}"]
        if {[llength $exact] > 0} {
            return [lindex $exact 0]
        }
    }

    # Fall back to the newest version present in the catalog
    set defs [get_ipdefs -quiet "${vlnv_base}:*"]
    if {[llength $defs] == 0} {
        error "resolve_ip_vlnv: no IP matching '${vlnv_base}:*' in the IP\
 catalog. Check that the required IP repositories are set up and the catalog\
 is up to date."
    }
    set best ""
    set best_version ""
    foreach def $defs {
        set version [lindex [split $def ":"] 3]
        if {$best eq "" || [package vcompare $version $best_version] > 0} {
            set best $def
            set best_version $version
        }
    }
    if {$validated_version ne ""} {
        puts "WARNING: ${vlnv_base}:${validated_version} not found in the IP\
 catalog; using $best instead."
    }
    return $best
}

###############################################################################
# Block design component names
###############################################################################

# Clocking and reset infrastructure
variable system_clock "System_Clock"
variable axi_reset "AXI_Reset"

# Ethernet subsystems (ingress = SGMII in -> AXIS RX, egress = AXIS TX -> SGMII out)
variable eth_ingress "Ethernet_MAC_Ingress"
variable eth_egress "Ethernet_MAC_Egress"

# AXI4-Stream frame FIFO (FIFO Generator, packet mode)
variable axis_frame_fifo "Axis_Frame_Fifo"

# Frame statistics block (project RTL on top of open-logic olo_axi_lite_slave)
variable frame_stats "Frame_Stats"

###############################################################################
# Main build procedure
###############################################################################

proc build_all {} {
    # Import global variables
    global project_name part project_dir top_level_bd_name
    global system_clock axi_reset
    global eth_ingress eth_egress
    global axis_frame_fifo
    global frame_stats

    puts ""
    puts "==============================================================================="
    puts "  OSVVM Ethernet Loopback Demonstration - Build Script"
    puts "==============================================================================="
    puts ""
    puts "  Project: $project_name"
    puts "  Part:    $part"
    puts "  Dir:     $project_dir"
    puts ""

    # Create the project targeting the AXAU15 part (xcau15p). The design is for
    # behavioral simulation + synthesis only, so the part is all that matters --
    # no board files, pinout, or implementation constraints are required.
    puts "INFO: Creating project..."

    if {[catch {create_project $project_name $project_dir -part $part -force} result]} {
        puts "ERROR: Failed to create project: $result"
        return -1
    }

    puts ""
    puts "INFO: Project created successfully."
    puts ""

    # Save off the critical sources names
    set synth_sources_name [get_filesets -filter {FILESET_TYPE == "DesignSrcs"}]
    set sim_sources_name [get_filesets -filter {FILESET_TYPE == "SimulationSrcs"}]

    ###########################################################################
    # Project RTL: frame_stats + its open-logic dependencies
    ###########################################################################
    # frame_stats builds on open-logic's olo_axi_lite_slave. The olo sources
    # use plain `work` library references internally, so everything compiles
    # into the default library alongside frame_stats. VHDL-2008 throughout.
    set olo_dir [file normalize "$project_dir/deps/open-logic/src"]
    set olo_files [list \
        "$olo_dir/base/vhdl/olo_base_pkg_array.vhd" \
        "$olo_dir/base/vhdl/olo_base_pkg_math.vhd" \
        "$olo_dir/base/vhdl/olo_base_pkg_logic.vhd" \
        "$olo_dir/base/vhdl/olo_base_pkg_string.vhd" \
        "$olo_dir/axi/vhdl/olo_axi_pkg_protocol.vhd" \
        "$olo_dir/axi/vhdl/olo_axi_lite_slave.vhd" \
    ]
    foreach f $olo_files {
        if {![file exists $f]} {
            puts "ERROR: open-logic source not found: $f"
            puts "       Clone the dependency first:"
            puts "         cd deps && git clone https://github.com/open-logic/open-logic.git"
            return -1
        }
    }
    add_files -norecurse $olo_files
    add_files -norecurse "$project_dir/rtl/frame_stats.vhd"
    set_property file_type {VHDL 2008} [get_files [concat $olo_files [list "$project_dir/rtl/frame_stats.vhd"]]]

    # Create the top level block design
    create_bd_design $top_level_bd_name
    update_compile_order -fileset $synth_sources_name

    ###########################################################################
    # Clocking and reset
    ###########################################################################

    puts "INFO: Creating clock and reset infrastructure..."

    # System clock PLL: 200 MHz differential input -> 125 MHz AXIS/AXI-Lite
    # clock (clk_out1) + auxiliary reference clock (clk_out2) for the
    # axi_ethernet ref_clk input. The exact ref_clk frequency the subsystem
    # expects is queried from the IP after instantiation (it changed across
    # axi_ethernet releases), and clk_out2 is retuned to match below.
    create_bd_cell -type ip -vlnv [resolve_ip_vlnv xilinx.com:ip:clk_wiz 6.0] $system_clock
    set_property -dict [list \
        CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
        CONFIG.PRIM_IN_FREQ {200.000} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} \
        CONFIG.CLKOUT2_USED {true} \
        CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {300.000} \
        CONFIG.NUM_OUT_CLKS {2} \
        CONFIG.RESET_PORT {resetn} \
        CONFIG.RESET_TYPE {ACTIVE_LOW} \
        CONFIG.USE_LOCKED {true} \
        CONFIG.USE_RESET {true} \
    ] [get_bd_cells $system_clock]

    # External system clock input and reset
    startgroup
        make_bd_intf_pins_external [get_bd_intf_pins $system_clock/CLK_IN1_D]
        set_property name sys_clk_in [get_bd_intf_ports CLK_IN1_D_0]
        set_property CONFIG.FREQ_HZ 200000000 [get_bd_intf_ports /sys_clk_in]
        make_bd_pins_external [get_bd_pins $system_clock/resetn]
        set_property name system_resetn [get_bd_ports resetn_0]
        make_bd_pins_external [get_bd_pins $system_clock/locked]
        set_property name clocks_locked [get_bd_ports locked_0]
    endgroup

    # Reset synchronizer for the 125 MHz AXI/AXIS domain
    create_bd_cell -type ip -vlnv [resolve_ip_vlnv xilinx.com:ip:proc_sys_reset 5.0] $axi_reset
    connect_bd_net [get_bd_ports system_resetn] [get_bd_pins $axi_reset/ext_reset_in]
    connect_bd_net [get_bd_pins $system_clock/clk_out1] [get_bd_pins $axi_reset/slowest_sync_clk]
    connect_bd_net [get_bd_pins $system_clock/locked] [get_bd_pins $axi_reset/dcm_locked]

    ###########################################################################
    # Ethernet MAC subsystems (AXI 1G/2.5G Ethernet Subsystem, SGMII over GT)
    ###########################################################################

    puts "INFO: Instantiating AXI 1G/2.5G Ethernet Subsystems (SGMII)..."

    # signal_detect tie-off (no optical module present; permanently asserted)
    create_bd_cell -type ip -vlnv [resolve_ip_vlnv xilinx.com:ip:xlconstant 1.1] signal_detect_const
    set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] [get_bd_cells signal_detect_const]

    set ref_clk_retuned 0
    foreach {mac suffix} [list $eth_ingress ingress $eth_egress egress] {
        # SGMII internal PHY interface, brought off-chip through the GT
        # transceivers (PHY_TYPE SGMII selects the transceiver-based
        # gig_ethernet_pcs_pma core with shared logic in the subsystem).
        create_bd_cell -type ip -vlnv [resolve_ip_vlnv xilinx.com:ip:axi_ethernet 8.0] $mac
        # Jumbo frame support (9 KB frames): the TEMAC TX/RX frame buffers
        # must be able to hold a complete maximum-size frame, so the 4k
        # default is raised to 16k on both sides (build-time requirement).
        # The jumbo *enable* itself is a runtime register in the TEMAC
        # (Receiver Config Word 1 bit 30 / Transmitter Config bit 30, JUM),
        # written by host software through the s_axi_* management ports.
        set_property -dict [list \
            CONFIG.PHY_TYPE {SGMII} \
            CONFIG.TXMEM {16k} \
            CONFIG.RXMEM {16k} \
        ] [get_bd_cells $mac]

        # Retune clk_out2 to whatever ref_clk frequency this axi_ethernet
        # release expects (8.0/SGMII wants 50 MHz; earlier LVDS-style configs
        # wanted an IDELAY-legal 200-334 MHz). Do it once, off the first MAC,
        # before wiring the clock so validate_bd_design sees matching FREQ_HZ.
        if {!$ref_clk_retuned} {
            set ref_clk_hz [get_property CONFIG.FREQ_HZ [get_bd_pins $mac/ref_clk]]
            if {$ref_clk_hz ne ""} {
                set ref_clk_mhz [expr {double($ref_clk_hz) / 1.0e6}]
                puts "INFO: axi_ethernet ref_clk expects ${ref_clk_mhz} MHz; retuning clk_out2..."
                set_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $ref_clk_mhz [get_bd_cells $system_clock]
            }
            set ref_clk_retuned 1
        }

        # Clocks and resets: single 125 MHz AXI/AXIS domain + retuned ref_clk
        connect_bd_net [get_bd_pins $system_clock/clk_out1] [get_bd_pins $mac/s_axi_lite_clk]
        connect_bd_net [get_bd_pins $system_clock/clk_out1] [get_bd_pins $mac/axis_clk]
        connect_bd_net [get_bd_pins $system_clock/clk_out2] [get_bd_pins $mac/ref_clk]
        connect_bd_net [get_bd_pins $axi_reset/peripheral_aresetn] [get_bd_pins $mac/s_axi_lite_resetn]
        foreach rst {axi_rxd_arstn axi_rxs_arstn axi_txc_arstn axi_txd_arstn} {
            connect_bd_net [get_bd_pins $axi_reset/peripheral_aresetn] [get_bd_pins $mac/$rst]
        }
        connect_bd_net [get_bd_pins signal_detect_const/dout] [get_bd_pins $mac/signal_detect]

        # Off-chip I/O: GT reference clock in, SGMII serial lanes, MDIO to the
        # external PHY, and the AXI-Lite management port for the host.
        startgroup
            make_bd_intf_pins_external [get_bd_intf_pins $mac/mgt_clk]
            set_property name mgt_clk_$suffix [get_bd_intf_ports mgt_clk_0]
            set_property CONFIG.FREQ_HZ 125000000 [get_bd_intf_ports /mgt_clk_$suffix]
            make_bd_intf_pins_external [get_bd_intf_pins $mac/sgmii]
            set_property name sgmii_$suffix [get_bd_intf_ports sgmii_0]
            make_bd_intf_pins_external [get_bd_intf_pins $mac/mdio]
            set_property name mdio_$suffix [get_bd_intf_ports mdio_0]
            make_bd_intf_pins_external [get_bd_intf_pins $mac/s_axi]
            set_property name s_axi_$suffix [get_bd_intf_ports s_axi_0]
            set_property CONFIG.FREQ_HZ 125000000 [get_bd_intf_ports /s_axi_$suffix]
        endgroup
    }

    # The egress TX CONTROL stream is exported at the BD boundary: the AXI
    # Ethernet buffer's TX engine requires a 6-word control packet per
    # frame on s_axis_txc, and with it unconnected the egress MAC never
    # transmits a single beat (discovered by the full-BD traffic test --
    # the packet FIFO filled to 32 KB while FRAMES_OUT stayed 0). At board
    # level the host DMA provides these words; in the full-BD testbench an
    # OSVVM AxiStreamTransmitter VVC does.
    startgroup
        make_bd_intf_pins_external [get_bd_intf_pins $eth_egress/s_axis_txc]
        set_property name s_axis_txc [get_bd_intf_ports s_axis_txc_0]
        set_property CONFIG.FREQ_HZ 125000000 [get_bd_intf_ports /s_axis_txc]
    endgroup

    # Export the 125 MHz AXI/AXIS clock so the external AXI-Lite management
    # ports have an associated clock at the BD boundary (and so a testbench
    # driving s_axi_* has the right clock available).
    create_bd_port -dir O -type clk axi_clk_125MHz
    connect_bd_net [get_bd_ports axi_clk_125MHz] [get_bd_pins $system_clock/clk_out1]
    set_property CONFIG.FREQ_HZ 125000000 [get_bd_ports axi_clk_125MHz]
    set_property CONFIG.ASSOCIATED_BUSIF {s_axi_ingress:s_axi_egress:s_axi_stats:s_axis_txc} [get_bd_ports axi_clk_125MHz]

    ###########################################################################
    # AXI4-Stream Frame FIFO (FIFO Generator, embedded AXI4-Stream interface)
    ###########################################################################

    puts "INFO: Instantiating AXI4-Stream FIFO Generator (packet mode)..."

    # FIFO Generator in AXI4-Stream mode. Packet-FIFO application type gives
    # store-and-forward behavior: a frame is only presented on M_AXIS once its
    # TLAST has been written, which is the correct bridging discipline between
    # two MACs (the egress MAC must never underrun mid-frame).
    # 4-byte TDATA + TKEEP + TLAST matches the axi_ethernet AXIS client
    # interfaces exactly. 8192 words = 32 KB: a 9018-byte jumbo frame is
    # 2255 words, so the packet FIFO can store-and-forward three complete
    # jumbo frames (packet mode requires at least one whole frame to fit).
    create_bd_cell -type ip -vlnv [resolve_ip_vlnv xilinx.com:ip:fifo_generator 13.2] $axis_frame_fifo
    set_property -dict [list \
        CONFIG.INTERFACE_TYPE {AXI_STREAM} \
        CONFIG.Clock_Type_AXI {Common_Clock} \
        CONFIG.TDATA_NUM_BYTES {4} \
        CONFIG.TUSER_WIDTH {0} \
        CONFIG.Enable_TLAST {true} \
        CONFIG.HAS_TKEEP {true} \
        CONFIG.FIFO_Implementation_axis {Common_Clock_Block_RAM} \
        CONFIG.FIFO_Application_Type_axis {Packet_FIFO} \
        CONFIG.Input_Depth_axis {8192} \
    ] [get_bd_cells $axis_frame_fifo]

    connect_bd_net [get_bd_pins $system_clock/clk_out1] [get_bd_pins $axis_frame_fifo/s_aclk]
    connect_bd_net [get_bd_pins $axi_reset/peripheral_aresetn] [get_bd_pins $axis_frame_fifo/s_aresetn]

    # The verified datapath: ingress MAC RX client stream -> frame FIFO ->
    # egress MAC TX client stream, AXI4-Stream end to end.
    connect_bd_intf_net [get_bd_intf_pins $eth_ingress/m_axis_rxd] [get_bd_intf_pins $axis_frame_fifo/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins $axis_frame_fifo/M_AXIS] [get_bd_intf_pins $eth_egress/s_axis_txd]

    # Deliberately unconnected AXIS interfaces (single-direction bridge demo):
    #   - $eth_ingress/m_axis_rxs  (RX status: checksum-offload metadata)
    #   - $eth_ingress/s_axis_txd + s_axis_txc, $eth_egress/m_axis_rxd + m_axis_rxs
    # The verification target is the AXIS frame datapath; the offload sideband
    # streams and the reverse direction are out of scope (see README).
    # NOTE: $eth_egress/s_axis_txc is NOT in this list -- it is mandatory
    # for TX and is exported at the BD boundary below.

    ###########################################################################
    # Frame statistics block (open-logic based, module reference)
    ###########################################################################

    puts "INFO: Instantiating Frame_Stats (open-logic olo_axi_lite_slave)..."

    create_bd_cell -type module -reference frame_stats $frame_stats

    connect_bd_net [get_bd_pins $system_clock/clk_out1] [get_bd_pins $frame_stats/Clk]
    # Active-high synchronous reset, per open-logic convention
    connect_bd_net [get_bd_pins $axi_reset/peripheral_reset] [get_bd_pins $frame_stats/Rst]

    # Passive monitor taps on the two frame-FIFO links: connecting the
    # monitor-mode pin to the master endpoint joins the existing interface net
    connect_bd_intf_net [get_bd_intf_pins $eth_ingress/m_axis_rxd] \
        [get_bd_intf_pins $frame_stats/MON_IN]
    connect_bd_intf_net [get_bd_intf_pins $axis_frame_fifo/M_AXIS] \
        [get_bd_intf_pins $frame_stats/MON_OUT]

    # External AXI-Lite statistics port
    startgroup
        make_bd_intf_pins_external [get_bd_intf_pins $frame_stats/S_AXI_STATS]
        set_property name s_axi_stats [get_bd_intf_ports S_AXI_STATS_0]
        set_property CONFIG.FREQ_HZ 125000000 [get_bd_intf_ports /s_axi_stats]
    endgroup

    ###########################################################################
    # Address assignment (external AXI-Lite management ports)
    ###########################################################################

    puts "INFO: Assigning addresses..."
    assign_bd_address

    ###########################################################################
    # Save and generate
    ###########################################################################

    validate_bd_design
    save_bd_design
    set_property target_language Verilog [current_project]
    make_wrapper -files [get_files $project_dir/$project_name.srcs/$synth_sources_name/bd/$top_level_bd_name/$top_level_bd_name.bd] -top
    add_files -norecurse $project_dir/$project_name.gen/$synth_sources_name/bd/$top_level_bd_name/hdl/${top_level_bd_name}_wrapper.v
    save_bd_design

    # Pin the Design Sources top explicitly. Without this, Vivado's auto
    # top detection can promote frame_stats (a plain project source that is
    # ALSO consumed by the BD as a module reference) to top level, showing
    # it parallel to Top_wrapper in the hierarchy instead of under Top.
    set_property top ${top_level_bd_name}_wrapper [get_filesets sources_1]

    # Generate output products for all IP so they can be used for simulation
    update_compile_order -fileset sources_1

    # Build path to block design file using variables
    set bd_file "$project_dir/$project_name.srcs/$synth_sources_name/bd/$top_level_bd_name/$top_level_bd_name.bd"

    # Create all of the synthesis HDL for subsequent simulation use
    generate_target all [get_files $bd_file]

    # Export IP cache for all blocks
    foreach bd_ip [get_ips -all] {
        catch { config_ip_cache -export $bd_ip }
    }

    export_ip_user_files -of_objects [get_files $bd_file] -no_script -sync -force -quiet
    create_ip_run [get_files -of_objects [get_fileset sources_1] $bd_file]
    update_compile_order -fileset sources_1

    ###########################################################################
    # Simulation Sources: testbench fileset for GUI browsing
    ###########################################################################
    # The OSVVM testbenches are COMPILED by the sim/ flows (run_sim.sh /
    # run_sim.tcl), never by Vivado -- OSVVM lives outside the project. They
    # are still registered in a dedicated simulation fileset so the GUI's
    # Simulation Sources window shows the real verification hierarchy:
    # TbFullBd at the top with the Top_wrapper UUT instantiated beneath it
    # (plus the TbEthernetFifo datapath testbench alongside). sim_1 stays
    # DUT-only; full_sim_export.tcl depends on that to generate DUT-only
    # compile scripts.

    ###########################################################################
    # TB-only IP: SGMII PHY partner for the full-BD traffic test
    ###########################################################################
    # A standalone gig_ethernet_pcs_pma with the same proven configuration
    # as the cores inside the Ethernet subsystems (SGMII over GTH, 125 MHz
    # refclk, shared logic in core) but with no management interface and
    # autonegotiation DISABLED at generation. The full-BD testbench drives
    # its GMII with frames; its serial lanes chain into the UUT's SGMII
    # pins (see TbFullBd.vhd). Simulation-only: never instantiated in the
    # BD, never synthesized to a netlist for implementation.
    puts "INFO: Creating SGMII PHY-partner IP (full-BD traffic test)..."
    create_ip -vlnv [resolve_ip_vlnv xilinx.com:ip:gig_ethernet_pcs_pma 17.0] \
        -module_name phy_partner_pcs_pma
    set_property -dict [list \
        CONFIG.Standard {SGMII} \
        CONFIG.Physical_Interface {Transceiver} \
        CONFIG.Management_Interface {FALSE} \
        CONFIG.Auto_Negotiation {FALSE} \
        CONFIG.SGMII_Mode {10_100_1000} \
        CONFIG.SupportLevel {Include_Shared_Logic_in_Core} \
        CONFIG.GT_Type {GTH} \
        CONFIG.RefClkRate {125} \
        CONFIG.DrpClkRate {50.0} \
    ] [get_ips phy_partner_pcs_pma]
    generate_target all [get_ips phy_partner_pcs_pma]
    export_ip_user_files -of_objects [get_ips phy_partner_pcs_pma] -no_script -sync -force -quiet

    puts "INFO: Registering OSVVM testbenches in simulation fileset sim_tb..."
    if {[llength [get_filesets -quiet sim_tb]] == 0} {
        create_fileset -simset sim_tb
    }
    set tb_files [list \
        "$project_dir/sim/tb/EthFramePkg.vhd" \
        "$project_dir/sim/tb/CsrAxiLiteManager.vhd" \
        "$project_dir/sim/tb/TestCtrl_e.vhd" \
        "$project_dir/sim/tb/TbEthernetFifo.vhd" \
        "$project_dir/sim/tb/TestCtrl_FrameLoopback.vhd" \
        "$project_dir/sim/tb/TestCtrlFull_e.vhd" \
        "$project_dir/sim/tb/TbFullBd.vhd" \
        "$project_dir/sim/tb/TestCtrl_FullBringup.vhd" \
        "$project_dir/sim/tb/TestCtrl_FullTraffic.vhd" \
    ]
    add_files -fileset sim_tb -norecurse $tb_files
    set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_tb] $tb_files]
    if {[catch {set_property top TbFullBd [get_filesets sim_tb]} msg]} {
        puts "WARNING: could not set sim_tb top to TbFullBd: $msg"
    }
    catch {update_compile_order -fileset sim_tb}
    # Open the Simulation Sources view on the testbench hierarchy
    current_fileset -simset [get_filesets sim_tb]

    ###########################################################################
    # Synthesis (and no further -- simulation-only design, no implementation)
    ###########################################################################

    puts "INFO: Launching synthesis..."
    launch_runs synth_1 -jobs 16
    wait_on_runs synth_1

    set synth_progress [get_property PROGRESS [get_runs synth_1]]
    set synth_status [get_property STATUS [get_runs synth_1]]
    puts "INFO: synth_1 status: $synth_status (progress: $synth_progress)"
    if {$synth_progress ne "100%"} {
        puts "ERROR: Synthesis did not complete successfully."
        return -1
    }

    puts ""
    puts "==============================================================================="
    puts "  Build complete!  Synthesis passed -- stopping here by design."
    puts "  (Simulation-only project: no implementation, no bitstream.)"
    puts "==============================================================================="
    puts ""

    return 0
}
# End of build_all procedure

puts ""
puts "==============================================================================="
puts "  build_all.tcl loaded successfully"
puts "==============================================================================="
puts ""
puts "  Usage: build_all"
puts ""

# In batch mode (vivado -mode batch -source build_all.tcl), run the build
# automatically; from an interactive TCL console, leave it to the user.
if {![catch {set vivado_mode $::rdi::mode}] && $vivado_mode eq "batch"} {
    if {[build_all] != 0} {
        error "build_all failed"
    }
}
