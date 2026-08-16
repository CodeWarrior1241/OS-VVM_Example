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
--        reference clocks, 50 MHz independent clock for the PHY partner
--      * active-low system reset
--      * a TB-side SGMII PHY PARTNER (standalone gig_ethernet_pcs_pma,
--        same proven configuration as the cores inside the subsystems,
--        AN disabled at generation) whose GMII is the traffic injection/
--        extraction point for the full-BD traffic test
--      * SGMII serial CHAIN so every receiver has a live partner and
--        traffic traverses the whole UUT:
--          partner TX -> ingress RX   (frames in)
--          ingress TX -> egress  RX   (idles; gives egress PCS a link)
--          egress  TX -> partner RX   (frames out, checked at GMII)
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

library osvvm_AXI4 ;
  context osvvm_AXI4.AxiStreamContext ;

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

  -- SGMII serial chain nets (see header)
  signal SgmiiIngressTxP, SgmiiIngressTxN : std_logic ;
  signal SgmiiEgressTxP,  SgmiiEgressTxN  : std_logic ;
  signal PartnerTxP,      PartnerTxN      : std_logic ;

  -- PHY partner (TB-side gig_ethernet_pcs_pma)
  signal IndepClk         : std_logic := '0' ;   -- 50 MHz DRP/independent clock
  signal PartnerReset     : std_logic ;
  signal PartnerClk       : std_logic ;          -- userclk2 (125 MHz GMII clock)
  signal PartnerClkEn     : std_logic ;          -- sgmii_clk_en
  signal PartnerGmiiTxd   : std_logic_vector(7 downto 0) ;
  signal PartnerGmiiTxEn  : std_logic ;
  signal PartnerGmiiTxEr  : std_logic ;
  signal PartnerGmiiRxd   : std_logic_vector(7 downto 0) ;
  signal PartnerGmiiRxDv  : std_logic ;
  signal PartnerGmiiRxEr  : std_logic ;
  signal PartnerStatus    : std_logic_vector(15 downto 0) ;
  signal PartnerResetDone : std_logic ;

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

  -- Egress TX control stream (s_axis_txc): the AXI Ethernet buffer's TX
  -- engine needs a 6-word control packet per frame; an OSVVM
  -- AxiStreamTransmitter VVC plays the host DMA's role.
  constant TXC_TID_W   : integer := 8 ;
  constant TXC_TDEST_W : integer := 4 ;
  constant TXC_TUSER_W : integer := 4 ;
  constant TXC_INIT_ID   : std_logic_vector(TXC_TID_W-1 downto 0)   := (others => '0') ;
  constant TXC_INIT_DEST : std_logic_vector(TXC_TDEST_W-1 downto 0) := (others => '0') ;
  constant TXC_INIT_USER : std_logic_vector(TXC_TUSER_W-1 downto 0) := (others => '0') ;
  signal TxcTValid, TxcTReady, TxcTLast : std_logic ;
  signal TxcTData : std_logic_vector(31 downto 0) ;
  signal TxcTStrb, TxcTKeep : std_logic_vector(3 downto 0) ;
  signal TxcTID   : std_logic_vector(TXC_TID_W-1 downto 0) ;
  signal TxcTDest : std_logic_vector(TXC_TDEST_W-1 downto 0) ;
  signal TxcTUser : std_logic_vector(TXC_TUSER_W-1 downto 0) ;
  signal TxcRec : StreamRecType(
    DataToModel   (31 downto 0),
    DataFromModel (31 downto 0),
    ParamToModel  (TXC_TID_W + TXC_TDEST_W + TXC_TUSER_W downto 0),
    ParamFromModel(TXC_TID_W + TXC_TDEST_W + TXC_TUSER_W downto 0)
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
      s_axis_txc_tdata      : in    std_logic_vector(31 downto 0) ;
      s_axis_txc_tkeep      : in    std_logic_vector(3 downto 0) ;
      s_axis_txc_tlast      : in    std_logic ;
      s_axis_txc_tready     : out   std_logic ;
      s_axis_txc_tvalid     : in    std_logic ;
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

  -- TB-side SGMII PHY partner (Verilog IP, default binding via -L)
  component phy_partner_pcs_pma is
    port (
      gtrefclk_p             : in  std_logic ;
      gtrefclk_n             : in  std_logic ;
      gtrefclk_out           : out std_logic ;
      txn                    : out std_logic ;
      txp                    : out std_logic ;
      rxn                    : in  std_logic ;
      rxp                    : in  std_logic ;
      independent_clock_bufg : in  std_logic ;
      userclk_out            : out std_logic ;
      userclk2_out           : out std_logic ;
      rxuserclk_out          : out std_logic ;
      rxuserclk2_out         : out std_logic ;
      gtpowergood            : out std_logic ;
      resetdone              : out std_logic ;
      pma_reset_out          : out std_logic ;
      mmcm_locked_out        : out std_logic ;
      sgmii_clk_r            : out std_logic ;
      sgmii_clk_f            : out std_logic ;
      sgmii_clk_en           : out std_logic ;
      gmii_txd               : in  std_logic_vector(7 downto 0) ;
      gmii_tx_en             : in  std_logic ;
      gmii_tx_er             : in  std_logic ;
      gmii_rxd               : out std_logic_vector(7 downto 0) ;
      gmii_rx_dv             : out std_logic ;
      gmii_rx_er             : out std_logic ;
      gmii_isolate           : out std_logic ;
      configuration_vector   : in  std_logic_vector(4 downto 0) ;
      speed_is_10_100        : in  std_logic ;
      speed_is_100           : in  std_logic ;
      status_vector          : out std_logic_vector(15 downto 0) ;
      reset                  : in  std_logic ;
      signal_detect          : in  std_logic
    ) ;
  end component phy_partner_pcs_pma ;

begin

  ------------------------------------------------------------
  -- Board clocks and reset
  ------------------------------------------------------------
  SysClkP <= not SysClkP after tperiod_SysClk / 2 ;
  SysClkN <= not SysClkP ;
  MgtClkP <= not MgtClkP after tperiod_MgtClk / 2 ;
  MgtClkN <= not MgtClkP ;
  IndepClk <= not IndepClk after 10 ns ;   -- 50 MHz for the PHY partner

  SystemResetn <= '0', '1' after 20 * tperiod_SysClk ;
  PartnerReset <= not SystemResetn ;

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
      s_axis_txc_tdata      => TxcTData,
      s_axis_txc_tkeep      => TxcTKeep,
      s_axis_txc_tlast      => TxcTLast,
      s_axis_txc_tready     => TxcTReady,
      s_axis_txc_tvalid     => TxcTValid,
      -- Serial chain: partner TX -> ingress RX; ingress TX -> egress RX
      -- (idles, link partner); egress TX -> partner RX (checked traffic)
      sgmii_egress_rxn      => SgmiiIngressTxN,
      sgmii_egress_rxp      => SgmiiIngressTxP,
      sgmii_egress_txn      => SgmiiEgressTxN,
      sgmii_egress_txp      => SgmiiEgressTxP,
      sgmii_ingress_rxn     => PartnerTxN,
      sgmii_ingress_rxp     => PartnerTxP,
      sgmii_ingress_txn     => SgmiiIngressTxN,
      sgmii_ingress_txp     => SgmiiIngressTxP,
      sys_clk_in_clk_n      => SysClkN,
      sys_clk_in_clk_p      => SysClkP,
      system_resetn         => SystemResetn
    ) ;

  ------------------------------------------------------------
  -- TB-side SGMII PHY partner (traffic injection/extraction)
  ------------------------------------------------------------
  PhyPartner_1 : phy_partner_pcs_pma
    port map (
      gtrefclk_p             => MgtClkP,
      gtrefclk_n             => MgtClkN,
      gtrefclk_out           => open,
      txn                    => PartnerTxN,
      txp                    => PartnerTxP,
      rxn                    => SgmiiEgressTxN,
      rxp                    => SgmiiEgressTxP,
      independent_clock_bufg => IndepClk,
      userclk_out            => open,
      userclk2_out           => PartnerClk,
      rxuserclk_out          => open,
      rxuserclk2_out         => open,
      gtpowergood            => open,
      resetdone              => PartnerResetDone,
      pma_reset_out          => open,
      mmcm_locked_out        => open,
      sgmii_clk_r            => open,
      sgmii_clk_f            => open,
      sgmii_clk_en           => PartnerClkEn,
      gmii_txd               => PartnerGmiiTxd,
      gmii_tx_en             => PartnerGmiiTxEn,
      gmii_tx_er             => PartnerGmiiTxEr,
      gmii_rxd               => PartnerGmiiRxd,
      gmii_rx_dv             => PartnerGmiiRxDv,
      gmii_rx_er             => PartnerGmiiRxEr,
      gmii_isolate           => open,
      configuration_vector   => "00000",
      speed_is_10_100        => '0',
      speed_is_100           => '0',
      status_vector          => PartnerStatus,
      reset                  => PartnerReset,
      signal_detect          => '1'
    ) ;

  ------------------------------------------------------------
  -- Egress TX-control VVC (plays the host DMA: one 6-word control
  -- packet per frame on s_axis_txc)
  ------------------------------------------------------------
  TxcTransmitter_1 : AxiStreamTransmitter
    generic map (
      INIT_ID        => TXC_INIT_ID,
      INIT_DEST      => TXC_INIT_DEST,
      INIT_USER      => TXC_INIT_USER,
      INIT_LAST      => 0,
      tperiod_Clk    => tperiod_AxiClk,
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
      Clk      => AxiClk,
      nReset   => nReset,
      TValid   => TxcTValid,
      TReady   => TxcTReady,
      TID      => TxcTID,
      TDest    => TxcTDest,
      TUser    => TxcTUser,
      TData    => TxcTData,
      TStrb    => TxcTStrb,
      TKeep    => TxcTKeep,
      TLast    => TxcTLast,
      TransRec => TxcRec
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
  -- Test sequencer (the FullTraffic architecture: bring-up + traffic)
  ------------------------------------------------------------
  TestCtrl_1 : entity work.TestCtrlFull(FullTraffic)
    port map (
      nReset           => nReset,
      ClocksLocked     => ClocksLocked,
      IngressRec       => IngressRec,
      EgressRec        => EgressRec,
      StatsRec         => StatsRec,
      GmiiClk          => PartnerClk,
      GmiiClkEn        => PartnerClkEn,
      GmiiTxd          => PartnerGmiiTxd,
      GmiiTxEn         => PartnerGmiiTxEn,
      GmiiTxEr         => PartnerGmiiTxEr,
      GmiiRxd          => PartnerGmiiRxd,
      GmiiRxDv         => PartnerGmiiRxDv,
      GmiiRxEr         => PartnerGmiiRxEr,
      PartnerStatus    => PartnerStatus,
      PartnerResetDone => PartnerResetDone,
      TxcRec           => TxcRec
    ) ;

end architecture TestHarness ;
