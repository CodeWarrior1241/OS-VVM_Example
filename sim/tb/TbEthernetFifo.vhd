--
--  File Name:         TbEthernetFifo.vhd
--  Design Unit Name:  TbEthernetFifo
--
--  Description:
--    OSVVM test harness for the AXI4-Stream frame FIFO datapath of the
--    Ethernet-loopback block design (Vivado FIFO Generator, packet mode).
--
--    The DUT is the exact FIFO Generator instance that sits between the
--    two AXI 1G/2.5G Ethernet Subsystems in the Vivado block design
--    (generated simulation netlist Top_Axis_Frame_Fifo_0).  The two MACs
--    are represented at their AXI4-Stream client boundaries by OSVVM
--    verification components:
--
--      AxiStreamTransmitter  -> plays the ingress MAC RX client stream
--                               (m_axis_rxd) into the FIFO S_AXIS port
--      AxiStreamReceiver     -> plays the egress MAC TX client stream
--                               (s_axis_txd), draining the FIFO M_AXIS port
--
--    The harness also instantiates the project's frame_stats block (the
--    open-logic olo_axi_lite_slave based statistics counters that monitor
--    the same two AXIS links in the block design), verified through an
--    OSVVM Axi4LiteManager VVC on its AXI4-Lite management port.
--
--    Structure follows the standard OSVVM AxiStream testbench
--    (OsvvmLibraries/AXI4/AxiStream/testbench/TbStream.vhd).
--
library ieee ;
  use ieee.std_logic_1164.all ;
  use ieee.numeric_std.all ;
  use ieee.numeric_std_unsigned.all ;

library osvvm ;
  context osvvm.OsvvmContext ;

library osvvm_AXI4 ;
  context osvvm_AXI4.AxiStreamContext ;

entity TbEthernetFifo is
end entity TbEthernetFifo ;
architecture TestHarness of TbEthernetFifo is

  -- 125 MHz AXIS clock, as driven by System_Clock/clk_out1 in the BD
  constant tperiod_Clk : time := 8 ns ;
  constant tpd         : time := 2 ns ;

  signal Clk    : std_logic := '1' ;
  signal nReset : std_logic ;

  constant AXI_DATA_WIDTH  : integer := 32 ;
  constant AXI_BYTE_WIDTH  : integer := AXI_DATA_WIDTH/8 ;
  constant TID_MAX_WIDTH   : integer := 8 ;
  constant TDEST_MAX_WIDTH : integer := 4 ;
  constant TUSER_MAX_WIDTH : integer := 4 ;

  constant INIT_ID   : std_logic_vector(TID_MAX_WIDTH-1 downto 0)   := (others => '0') ;
  constant INIT_DEST : std_logic_vector(TDEST_MAX_WIDTH-1 downto 0) := (others => '0') ;
  constant INIT_USER : std_logic_vector(TUSER_MAX_WIDTH-1 downto 0) := (others => '0') ;

  -- S_AXIS side: OSVVM transmitter -> DUT (ingress MAC m_axis_rxd stand-in)
  signal SAxisTValid : std_logic ;
  signal SAxisTReady : std_logic ;
  signal SAxisTID    : std_logic_vector(TID_MAX_WIDTH-1 downto 0) ;
  signal SAxisTDest  : std_logic_vector(TDEST_MAX_WIDTH-1 downto 0) ;
  signal SAxisTUser  : std_logic_vector(TUSER_MAX_WIDTH-1 downto 0) ;
  signal SAxisTData  : std_logic_vector(AXI_DATA_WIDTH-1 downto 0) ;
  signal SAxisTStrb  : std_logic_vector(AXI_BYTE_WIDTH-1 downto 0) ;
  signal SAxisTKeep  : std_logic_vector(AXI_BYTE_WIDTH-1 downto 0) ;
  signal SAxisTLast  : std_logic ;

  -- M_AXIS side: DUT -> OSVVM receiver (egress MAC s_axis_txd stand-in)
  signal MAxisTValid : std_logic ;
  signal MAxisTReady : std_logic ;
  signal MAxisTData  : std_logic_vector(AXI_DATA_WIDTH-1 downto 0) ;
  signal MAxisTKeep  : std_logic_vector(AXI_BYTE_WIDTH-1 downto 0) ;
  signal MAxisTLast  : std_logic ;

  constant AXI_PARAM_WIDTH : integer := TID_MAX_WIDTH + TDEST_MAX_WIDTH + TUSER_MAX_WIDTH + 1 ;

  signal StreamTxRec, StreamRxRec : StreamRecType(
      DataToModel   (AXI_DATA_WIDTH-1  downto 0),
      DataFromModel (AXI_DATA_WIDTH-1  downto 0),
      ParamToModel  (AXI_PARAM_WIDTH-1 downto 0),
      ParamFromModel(AXI_PARAM_WIDTH-1 downto 0)
    ) ;

  -- Frame_Stats AXI4-Lite management interface
  constant STATS_ADDR_WIDTH : integer := 8 ;
  constant STATS_DATA_WIDTH : integer := 32 ;

  signal Reset_H : std_logic ;

  signal ManagerRec : AddressBusRecType(
      Address      (STATS_ADDR_WIDTH-1 downto 0),
      DataToModel  (STATS_DATA_WIDTH-1 downto 0),
      DataFromModel(STATS_DATA_WIDTH-1 downto 0)
    ) ;

  -- Discrete AXI4-Lite bus between the CSR manager VVC and frame_stats.
  -- The stock osvvm_AXI4 Axi4LiteManager exposes its bus as a resolved
  -- record port, which XSim 2026.1 corrupts (partial-U readback on record
  -- subelement drivers); CsrAxiLiteManager keeps the same OSVVM MIT
  -- transaction interface but drives discrete signals instead.
  signal StatsArAddr  : std_logic_vector(STATS_ADDR_WIDTH-1 downto 0) ;
  signal StatsArValid : std_logic ;
  signal StatsArReady : std_logic ;
  signal StatsAwAddr  : std_logic_vector(STATS_ADDR_WIDTH-1 downto 0) ;
  signal StatsAwValid : std_logic ;
  signal StatsAwReady : std_logic ;
  signal StatsWData   : std_logic_vector(STATS_DATA_WIDTH-1 downto 0) ;
  signal StatsWStrb   : std_logic_vector(STATS_DATA_WIDTH/8-1 downto 0) ;
  signal StatsWValid  : std_logic ;
  signal StatsWReady  : std_logic ;
  signal StatsBResp   : std_logic_vector(1 downto 0) ;
  signal StatsBValid  : std_logic ;
  signal StatsBReady  : std_logic ;
  signal StatsRData   : std_logic_vector(STATS_DATA_WIDTH-1 downto 0) ;
  signal StatsRResp   : std_logic_vector(1 downto 0) ;
  signal StatsRValid  : std_logic ;
  signal StatsRReady  : std_logic ;

  -- Vivado-generated simulation netlist of the BD FIFO Generator instance.
  -- Bound by Questa's mixed-language default binding against the Verilog
  -- module of the same name (compiled into the fifo_dut library).
  component Top_Axis_Frame_Fifo_0 is
    port (
      s_aclk        : in  std_logic ;
      s_aresetn     : in  std_logic ;
      s_axis_tvalid : in  std_logic ;
      s_axis_tready : out std_logic ;
      s_axis_tdata  : in  std_logic_vector(31 downto 0) ;
      s_axis_tkeep  : in  std_logic_vector(3 downto 0) ;
      s_axis_tlast  : in  std_logic ;
      m_axis_tvalid : out std_logic ;
      m_axis_tready : in  std_logic ;
      m_axis_tdata  : out std_logic_vector(31 downto 0) ;
      m_axis_tkeep  : out std_logic_vector(3 downto 0) ;
      m_axis_tlast  : out std_logic
    ) ;
  end component Top_Axis_Frame_Fifo_0 ;

begin

  DUT : Top_Axis_Frame_Fifo_0
    port map (
      s_aclk        => Clk,
      s_aresetn     => nReset,

      s_axis_tvalid => SAxisTValid,
      s_axis_tready => SAxisTReady,
      s_axis_tdata  => SAxisTData,
      s_axis_tkeep  => SAxisTKeep,
      s_axis_tlast  => SAxisTLast,

      m_axis_tvalid => MAxisTValid,
      m_axis_tready => MAxisTReady,
      m_axis_tdata  => MAxisTData,
      m_axis_tkeep  => MAxisTKeep,
      m_axis_tlast  => MAxisTLast
    ) ;

  -- Frame statistics block (same RTL instance as in the block design),
  -- passively monitoring both sides of the FIFO
  Reset_H <= not nReset ;

  FrameStats_1 : entity work.frame_stats
    generic map (
      AxiAddrWidth_g => STATS_ADDR_WIDTH
    )
    port map (
      Clk               => Clk,
      Rst               => Reset_H,

      S_AxiLite_ArAddr  => StatsArAddr,
      S_AxiLite_ArValid => StatsArValid,
      S_AxiLite_ArReady => StatsArReady,
      S_AxiLite_AwAddr  => StatsAwAddr,
      S_AxiLite_AwValid => StatsAwValid,
      S_AxiLite_AwReady => StatsAwReady,
      S_AxiLite_WData   => StatsWData,
      S_AxiLite_WStrb   => StatsWStrb,
      S_AxiLite_WValid  => StatsWValid,
      S_AxiLite_WReady  => StatsWReady,
      S_AxiLite_BResp   => StatsBResp,
      S_AxiLite_BValid  => StatsBValid,
      S_AxiLite_BReady  => StatsBReady,
      S_AxiLite_RData   => StatsRData,
      S_AxiLite_RResp   => StatsRResp,
      S_AxiLite_RValid  => StatsRValid,
      S_AxiLite_RReady  => StatsRReady,

      MonIn_TValid      => SAxisTValid,
      MonIn_TReady      => SAxisTReady,
      MonIn_TKeep       => SAxisTKeep,
      MonIn_TLast       => SAxisTLast,

      MonOut_TValid     => MAxisTValid,
      MonOut_TReady     => MAxisTReady,
      MonOut_TKeep      => MAxisTKeep,
      MonOut_TLast      => MAxisTLast
    ) ;

  StatsManager_1 : entity work.CsrAxiLiteManager
    generic map (
      tperiod_Clk => tperiod_Clk,
      tpd         => tpd
    )
    port map (
      Clk      => Clk,
      nReset   => nReset,

      AwAddr   => StatsAwAddr,
      AwValid  => StatsAwValid,
      AwReady  => StatsAwReady,
      WData    => StatsWData,
      WStrb    => StatsWStrb,
      WValid   => StatsWValid,
      WReady   => StatsWReady,
      BResp    => StatsBResp,
      BValid   => StatsBValid,
      BReady   => StatsBReady,
      ArAddr   => StatsArAddr,
      ArValid  => StatsArValid,
      ArReady  => StatsArReady,
      RData    => StatsRData,
      RResp    => StatsRResp,
      RValid   => StatsRValid,
      RReady   => StatsRReady,

      TransRec => ManagerRec
    ) ;

  -- create Clock
  Osvvm.ClockResetPkg.CreateClock (
    Clk        => Clk,
    Period     => tperiod_Clk
  ) ;

  -- create nReset
  Osvvm.ClockResetPkg.CreateReset (
    Reset       => nReset,
    ResetActive => '0',
    Clk         => Clk,
    Period      => 7 * tperiod_Clk,
    tpd         => tpd
  ) ;

  Transmitter_1 : AxiStreamTransmitter
    generic map (
      INIT_ID        => INIT_ID  ,
      INIT_DEST      => INIT_DEST,
      INIT_USER      => INIT_USER,
      INIT_LAST      => 0,

      tperiod_Clk    => tperiod_Clk,

      tpd_Clk_TValid => tpd,
      tpd_Clk_TID    => tpd,
      tpd_Clk_TDest  => tpd,
      tpd_Clk_TUser  => tpd,
      tpd_Clk_TData  => tpd,
      tpd_Clk_TStrb  => tpd,
      tpd_Clk_TKeep  => tpd,
      tpd_Clk_TLast  => tpd
    )
    port map (
      -- Globals
      Clk       => Clk,
      nReset    => nReset,

      -- AXI Stream Interface into the DUT S_AXIS port
      TValid    => SAxisTValid,
      TReady    => SAxisTReady,
      TID       => SAxisTID   ,
      TDest     => SAxisTDest ,
      TUser     => SAxisTUser ,
      TData     => SAxisTData ,
      TStrb     => SAxisTStrb ,
      TKeep     => SAxisTKeep ,
      TLast     => SAxisTLast ,

      -- Testbench Transaction Interface
      TransRec  => StreamTxRec
    ) ;

  Receiver_1 : AxiStreamReceiver
    generic map (
      tperiod_Clk    => tperiod_Clk,
      INIT_ID        => INIT_ID  ,
      INIT_DEST      => INIT_DEST,
      INIT_USER      => INIT_USER,
      INIT_LAST      => 0,

      tpd_Clk_TReady => tpd
    )
    port map (
      -- Globals
      Clk       => Clk,
      nReset    => nReset,

      -- AXI Stream Interface from the DUT M_AXIS port.
      -- The FIFO carries TDATA/TKEEP/TLAST only (matching the MAC client
      -- streams): TID/TDEST/TUSER are static, and TSTRB mirrors TKEEP
      -- (every carried byte is a data byte).
      TValid    => MAxisTValid,
      TReady    => MAxisTReady,
      TID       => INIT_ID    ,
      TDest     => INIT_DEST  ,
      TUser     => INIT_USER  ,
      TData     => MAxisTData ,
      TStrb     => MAxisTKeep ,
      TKeep     => MAxisTKeep ,
      TLast     => MAxisTLast ,

      -- Testbench Transaction Interface
      TransRec  => StreamRxRec
    ) ;

  TestCtrl_1 : entity work.TestCtrl
    generic map (
      ID_LEN       => TID_MAX_WIDTH,
      DEST_LEN     => TDEST_MAX_WIDTH,
      USER_LEN     => TUSER_MAX_WIDTH
    )
    port map (
      -- Globals
      nReset       => nReset,

      -- Testbench Transaction Interfaces
      StreamTxRec  => StreamTxRec,
      StreamRxRec  => StreamRxRec,
      ManagerRec   => ManagerRec
    ) ;

end architecture TestHarness ;
