--
--  File Name:         TbFullBd.vhd
--  Design Unit Name:  TbFullBd
--
--  Description:
--    FULL block-design test harness (--full_sim).  Instantiates the
--    Vivado-generated BD wrapper (Top_wrapper) in its entirety: both
--    AXI 1G/2.5G Ethernet Subsystems with TEMAC, SGMII PCS/PMA and the
--    GT transceivers as encrypted SecureIP models, the clock wizard,
--    reset block, packet FIFO and Frame_Stats.
--
--    Board-level wiring provided here:
--      * 200 MHz differential system clock, 125 MHz differential GT
--        reference clocks (one per MAC, driven from a common source)
--      * active-low system reset
--      * SGMII serial cross-loopback: egress TX -> ingress RX and
--        ingress TX -> egress RX, so both PCS/PMA + GT links can come up
--        against each other over the modeled serial lanes
--      * MDIO bus pull-ups
--      * three CsrAxiLiteManager VVCs on the exported AXI4-Lite ports
--        (ingress MAC, egress MAC, Frame_Stats), clocked by the BD's own
--        exported 125 MHz AXI clock
--
--    The Verilog DUT binds via mixed-language default component binding
--    (component name/ports match Top_wrapper; resolved with -L).
--
library ieee ;
  use ieee.std_logic_1164.all ;
  use ieee.numeric_std.all ;

library osvvm ;
  context osvvm.OsvvmContext ;

library osvvm_common ;
  context osvvm_common.OsvvmCommonContext ;

entity TbFullBd is
end entity TbFullBd ;

architecture TestHarness of TbFullBd is

  constant tperiod_SysClk : time := 5 ns ;   -- 200 MHz board oscillator
  constant tperiod_MgtClk : time := 8 ns ;   -- 125 MHz GT reference
  constant tperiod_AxiClk : time := 8 ns ;   -- BD-generated AXI clock
  constant tpd            : time := 2 ns ;

  -- Board clocks and reset
  signal SysClkP, SysClkN : std_logic := '0' ;
  signal MgtClkP, MgtClkN : std_logic := '0' ;
  signal SystemResetn     : std_logic := '0' ;

  -- BD outputs
  signal AxiClk       : std_logic ;
  signal ClocksLocked : std_logic ;
  signal nReset       : std_logic ;

  -- SGMII serial lanes (egress TX -> ingress RX, ingress TX -> egress RX)
  signal SgmiiIngressTxP, SgmiiIngressTxN : std_logic ;
  signal SgmiiEgressTxP,  SgmiiEgressTxN  : std_logic ;

  -- MDIO
  signal MdioIngress, MdioEgress : std_logic ;

  -- AXI4-Lite: ingress MAC management (18-bit address)
  signal IngAwAddr, IngArAddr : std_logic_vector(17 downto 0) ;
  signal IngAwValid, IngAwReady, IngWValid, IngWReady : std_logic ;
  signal IngBValid, IngBReady, IngArValid, IngArReady : std_logic ;
  signal IngRValid, IngRReady : std_logic ;
  signal IngWData, IngRData   : std_logic_vector(31 downto 0) ;
  signal IngWStrb             : std_logic_vector(3 downto 0) ;
  signal IngBResp, IngRResp   : std_logic_vector(1 downto 0) ;

  -- AXI4-Lite: egress MAC management (18-bit address)
  signal EgrAwAddr, EgrArAddr : std_logic_vector(17 downto 0) ;
  signal EgrAwValid, EgrAwReady, EgrWValid, EgrWReady : std_logic ;
  signal EgrBValid, EgrBReady, EgrArValid, EgrArReady : std_logic ;
  signal EgrRValid, EgrRReady : std_logic ;
  signal EgrWData, EgrRData   : std_logic_vector(31 downto 0) ;
  signal EgrWStrb             : std_logic_vector(3 downto 0) ;
  signal EgrBResp, EgrRResp   : std_logic_vector(1 downto 0) ;

  -- AXI4-Lite: Frame_Stats. The DUT port is 8 bits, but the VVC-side
  -- signals and transaction record are 18 bits so that ALL THREE
  -- AddressBusRecType signals carry identical element constraints --
  -- XSim mis-resolves record constraints when signals of the same
  -- unconstrained record type differ in element widths (transactions on
  -- one record got resized against another record's width).
  signal StsAwAddr, StsArAddr : std_logic_vector(17 downto 0) ;
  signal StsAwValid, StsAwReady, StsWValid, StsWReady : std_logic ;
  signal StsBValid, StsBReady, StsArValid, StsArReady : std_logic ;
  signal StsRValid, StsRReady : std_logic ;
  signal StsWData, StsRData   : std_logic_vector(31 downto 0) ;
  signal StsWStrb             : std_logic_vector(3 downto 0) ;
  signal StsBResp, StsRResp   : std_logic_vector(1 downto 0) ;

  -- Transaction interfaces (identical constraints on all three -- see the
  -- Frame_Stats signal comment above)
  signal IngressRec, EgressRec, StatsRec : AddressBusRecType(
    Address(17 downto 0),
    DataToModel(31 downto 0),
    DataFromModel(31 downto 0)
  ) ;

  -- Verilog BD wrapper (default component binding, resolved via -L)
  component Top_wrapper is
    port (
      axi_clk_125MHz        : out   std_logic ;
      clocks_locked         : out   std_logic ;
      mdio_egress_mdc       : out   std_logic ;
      mdio_egress_mdio_io   : inout std_logic ;
      mdio_ingress_mdc      : out   std_logic ;
      mdio_ingress_mdio_io  : inout std_logic ;
      mgt_clk_egress_clk_n  : in    std_logic ;
      mgt_clk_egress_clk_p  : in    std_logic ;
      mgt_clk_ingress_clk_n : in    std_logic ;
      mgt_clk_ingress_clk_p : in    std_logic ;
      s_axi_egress_araddr   : in    std_logic_vector(17 downto 0) ;
      s_axi_egress_arready  : out   std_logic ;
      s_axi_egress_arvalid  : in    std_logic ;
      s_axi_egress_awaddr   : in    std_logic_vector(17 downto 0) ;
      s_axi_egress_awready  : out   std_logic ;
      s_axi_egress_awvalid  : in    std_logic ;
      s_axi_egress_bready   : in    std_logic ;
      s_axi_egress_bresp    : out   std_logic_vector(1 downto 0) ;
      s_axi_egress_bvalid   : out   std_logic ;
      s_axi_egress_rdata    : out   std_logic_vector(31 downto 0) ;
      s_axi_egress_rready   : in    std_logic ;
      s_axi_egress_rresp    : out   std_logic_vector(1 downto 0) ;
      s_axi_egress_rvalid   : out   std_logic ;
      s_axi_egress_wdata    : in    std_logic_vector(31 downto 0) ;
      s_axi_egress_wready   : out   std_logic ;
      s_axi_egress_wstrb    : in    std_logic_vector(3 downto 0) ;
      s_axi_egress_wvalid   : in    std_logic ;
      s_axi_ingress_araddr  : in    std_logic_vector(17 downto 0) ;
      s_axi_ingress_arready : out   std_logic ;
      s_axi_ingress_arvalid : in    std_logic ;
      s_axi_ingress_awaddr  : in    std_logic_vector(17 downto 0) ;
      s_axi_ingress_awready : out   std_logic ;
      s_axi_ingress_awvalid : in    std_logic ;
      s_axi_ingress_bready  : in    std_logic ;
      s_axi_ingress_bresp   : out   std_logic_vector(1 downto 0) ;
      s_axi_ingress_bvalid  : out   std_logic ;
      s_axi_ingress_rdata   : out   std_logic_vector(31 downto 0) ;
      s_axi_ingress_rready  : in    std_logic ;
      s_axi_ingress_rresp   : out   std_logic_vector(1 downto 0) ;
      s_axi_ingress_rvalid  : out   std_logic ;
      s_axi_ingress_wdata   : in    std_logic_vector(31 downto 0) ;
      s_axi_ingress_wready  : out   std_logic ;
      s_axi_ingress_wstrb   : in    std_logic_vector(3 downto 0) ;
      s_axi_ingress_wvalid  : in    std_logic ;
      s_axi_stats_araddr    : in    std_logic_vector(7 downto 0) ;
      s_axi_stats_arready   : out   std_logic ;
      s_axi_stats_arvalid   : in    std_logic ;
      s_axi_stats_awaddr    : in    std_logic_vector(7 downto 0) ;
      s_axi_stats_awready   : out   std_logic ;
      s_axi_stats_awvalid   : in    std_logic ;
      s_axi_stats_bready    : in    std_logic ;
      s_axi_stats_bresp     : out   std_logic_vector(1 downto 0) ;
      s_axi_stats_bvalid    : out   std_logic ;
      s_axi_stats_rdata     : out   std_logic_vector(31 downto 0) ;
      s_axi_stats_rready    : in    std_logic ;
      s_axi_stats_rresp     : out   std_logic_vector(1 downto 0) ;
      s_axi_stats_rvalid    : out   std_logic ;
      s_axi_stats_wdata     : in    std_logic_vector(31 downto 0) ;
      s_axi_stats_wready    : out   std_logic ;
      s_axi_stats_wstrb     : in    std_logic_vector(3 downto 0) ;
      s_axi_stats_wvalid    : in    std_logic ;
      sgmii_egress_rxn      : in    std_logic ;
      sgmii_egress_rxp      : in    std_logic ;
      sgmii_egress_txn      : out   std_logic ;
      sgmii_egress_txp      : out   std_logic ;
      sgmii_ingress_rxn     : in    std_logic ;
      sgmii_ingress_rxp     : in    std_logic ;
      sgmii_ingress_txn     : out   std_logic ;
      sgmii_ingress_txp     : out   std_logic ;
      sys_clk_in_clk_n      : in    std_logic ;
      sys_clk_in_clk_p      : in    std_logic ;
      system_resetn         : in    std_logic
    ) ;
  end component Top_wrapper ;

begin

  ------------------------------------------------------------
  -- Board clocks and reset
  ------------------------------------------------------------
  SysClkP <= not SysClkP after tperiod_SysClk / 2 ;
  SysClkN <= not SysClkP ;
  MgtClkP <= not MgtClkP after tperiod_MgtClk / 2 ;
  MgtClkN <= not MgtClkP ;

  SystemResetn <= '0', '1' after 20 * tperiod_SysClk ;

  -- VVC-side reset: released once the BD's clocks are locked
  nReset <= ClocksLocked ;

  -- MDIO bus pull-ups (open-drain bus, no external PHY attached)
  MdioIngress <= 'H' ;
  MdioEgress  <= 'H' ;

  ------------------------------------------------------------
  -- DUT: the complete block design
  ------------------------------------------------------------
  Dut_1 : Top_wrapper
    port map (
      axi_clk_125MHz        => AxiClk,
      clocks_locked         => ClocksLocked,
      mdio_egress_mdc       => open,
      mdio_egress_mdio_io   => MdioEgress,
      mdio_ingress_mdc      => open,
      mdio_ingress_mdio_io  => MdioIngress,
      mgt_clk_egress_clk_n  => MgtClkN,
      mgt_clk_egress_clk_p  => MgtClkP,
      mgt_clk_ingress_clk_n => MgtClkN,
      mgt_clk_ingress_clk_p => MgtClkP,
      s_axi_egress_araddr   => EgrArAddr,
      s_axi_egress_arready  => EgrArReady,
      s_axi_egress_arvalid  => EgrArValid,
      s_axi_egress_awaddr   => EgrAwAddr,
      s_axi_egress_awready  => EgrAwReady,
      s_axi_egress_awvalid  => EgrAwValid,
      s_axi_egress_bready   => EgrBReady,
      s_axi_egress_bresp    => EgrBResp,
      s_axi_egress_bvalid   => EgrBValid,
      s_axi_egress_rdata    => EgrRData,
      s_axi_egress_rready   => EgrRReady,
      s_axi_egress_rresp    => EgrRResp,
      s_axi_egress_rvalid   => EgrRValid,
      s_axi_egress_wdata    => EgrWData,
      s_axi_egress_wready   => EgrWReady,
      s_axi_egress_wstrb    => EgrWStrb,
      s_axi_egress_wvalid   => EgrWValid,
      s_axi_ingress_araddr  => IngArAddr,
      s_axi_ingress_arready => IngArReady,
      s_axi_ingress_arvalid => IngArValid,
      s_axi_ingress_awaddr  => IngAwAddr,
      s_axi_ingress_awready => IngAwReady,
      s_axi_ingress_awvalid => IngAwValid,
      s_axi_ingress_bready  => IngBReady,
      s_axi_ingress_bresp   => IngBResp,
      s_axi_ingress_bvalid  => IngBValid,
      s_axi_ingress_rdata   => IngRData,
      s_axi_ingress_rready  => IngRReady,
      s_axi_ingress_rresp   => IngRResp,
      s_axi_ingress_rvalid  => IngRValid,
      s_axi_ingress_wdata   => IngWData,
      s_axi_ingress_wready  => IngWReady,
      s_axi_ingress_wstrb   => IngWStrb,
      s_axi_ingress_wvalid  => IngWValid,
      s_axi_stats_araddr    => StsArAddr(7 downto 0),
      s_axi_stats_arready   => StsArReady,
      s_axi_stats_arvalid   => StsArValid,
      s_axi_stats_awaddr    => StsAwAddr(7 downto 0),
      s_axi_stats_awready   => StsAwReady,
      s_axi_stats_awvalid   => StsAwValid,
      s_axi_stats_bready    => StsBReady,
      s_axi_stats_bresp     => StsBResp,
      s_axi_stats_bvalid    => StsBValid,
      s_axi_stats_rdata     => StsRData,
      s_axi_stats_rready    => StsRReady,
      s_axi_stats_rresp     => StsRResp,
      s_axi_stats_rvalid    => StsRValid,
      s_axi_stats_wdata     => StsWData,
      s_axi_stats_wready    => StsWReady,
      s_axi_stats_wstrb     => StsWStrb,
      s_axi_stats_wvalid    => StsWValid,
      -- Serial cross-loopback: each MAC's TX feeds the other MAC's RX
      sgmii_egress_rxn      => SgmiiIngressTxN,
      sgmii_egress_rxp      => SgmiiIngressTxP,
      sgmii_egress_txn      => SgmiiEgressTxN,
      sgmii_egress_txp      => SgmiiEgressTxP,
      sgmii_ingress_rxn     => SgmiiEgressTxN,
      sgmii_ingress_rxp     => SgmiiEgressTxP,
      sgmii_ingress_txn     => SgmiiIngressTxN,
      sgmii_ingress_txp     => SgmiiIngressTxP,
      sys_clk_in_clk_n      => SysClkN,
      sys_clk_in_clk_p      => SysClkP,
      system_resetn         => SystemResetn
    ) ;

  ------------------------------------------------------------
  -- AXI4-Lite manager VVCs
  ------------------------------------------------------------
  IngressManager_1 : entity work.CsrAxiLiteManager
    generic map (
      MODEL_ID_NAME => "IngressMacCsr",
      tperiod_Clk   => tperiod_AxiClk,
      tpd           => tpd
    )
    port map (
      Clk      => AxiClk,
      nReset   => nReset,
      AwAddr   => IngAwAddr,
      AwValid  => IngAwValid,
      AwReady  => IngAwReady,
      WData    => IngWData,
      WStrb    => IngWStrb,
      WValid   => IngWValid,
      WReady   => IngWReady,
      BResp    => IngBResp,
      BValid   => IngBValid,
      BReady   => IngBReady,
      ArAddr   => IngArAddr,
      ArValid  => IngArValid,
      ArReady  => IngArReady,
      RData    => IngRData,
      RResp    => IngRResp,
      RValid   => IngRValid,
      RReady   => IngRReady,
      TransRec => IngressRec
    ) ;

  EgressManager_1 : entity work.CsrAxiLiteManager
    generic map (
      MODEL_ID_NAME => "EgressMacCsr",
      tperiod_Clk   => tperiod_AxiClk,
      tpd           => tpd
    )
    port map (
      Clk      => AxiClk,
      nReset   => nReset,
      AwAddr   => EgrAwAddr,
      AwValid  => EgrAwValid,
      AwReady  => EgrAwReady,
      WData    => EgrWData,
      WStrb    => EgrWStrb,
      WValid   => EgrWValid,
      WReady   => EgrWReady,
      BResp    => EgrBResp,
      BValid   => EgrBValid,
      BReady   => EgrBReady,
      ArAddr   => EgrArAddr,
      ArValid  => EgrArValid,
      ArReady  => EgrArReady,
      RData    => EgrRData,
      RResp    => EgrRResp,
      RValid   => EgrRValid,
      RReady   => EgrRReady,
      TransRec => EgressRec
    ) ;

  StatsManager_1 : entity work.CsrAxiLiteManager
    generic map (
      MODEL_ID_NAME => "FrameStatsCsr",
      tperiod_Clk   => tperiod_AxiClk,
      tpd           => tpd
    )
    port map (
      Clk      => AxiClk,
      nReset   => nReset,
      AwAddr   => StsAwAddr,
      AwValid  => StsAwValid,
      AwReady  => StsAwReady,
      WData    => StsWData,
      WStrb    => StsWStrb,
      WValid   => StsWValid,
      WReady   => StsWReady,
      BResp    => StsBResp,
      BValid   => StsBValid,
      BReady   => StsBReady,
      ArAddr   => StsArAddr,
      ArValid  => StsArValid,
      ArReady  => StsArReady,
      RData    => StsRData,
      RResp    => StsRResp,
      RValid   => StsRValid,
      RReady   => StsRReady,
      TransRec => StatsRec
    ) ;

  ------------------------------------------------------------
  -- Test sequencer
  ------------------------------------------------------------
  TestCtrl_1 : entity work.TestCtrlFull
    port map (
      nReset       => nReset,
      ClocksLocked => ClocksLocked,
      IngressRec   => IngressRec,
      EgressRec    => EgressRec,
      StatsRec     => StatsRec
    ) ;

end architecture TestHarness ;
