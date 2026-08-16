--
--  File Name:         TestCtrlFull_e.vhd
--  Design Unit Name:  TestCtrlFull
--
--  Description:
--    Test sequencer entity for the FULL block-design simulation
--    (--full_sim): the entire BD -- both AXI 1G/2.5G Ethernet Subsystems
--    (TEMAC + PCS/PMA + GT SecureIP), clocking, reset, packet FIFO and
--    Frame_Stats -- elaborated for real.  The only controllable/observable
--    boundaries at BD level are the three AXI4-Lite management ports, the
--    SGMII serial lanes (cross-connected in the harness), MDIO, clocks and
--    resets, so the transaction interfaces here are three address-bus
--    records driven through CsrAxiLiteManager VVCs.
--
--    Each full-BD test case is an architecture of this entity.
--
library ieee ;
  use ieee.std_logic_1164.all ;
  use ieee.numeric_std.all ;

library OSVVM ;
  context OSVVM.OsvvmContext ;

library osvvm_common ;
  context osvvm_common.OsvvmCommonContext ;

entity TestCtrlFull is
  port (
      -- Global Signal Interface
      nReset             : In    std_logic ;
      ClocksLocked       : In    std_logic ;

      -- AXI4-Lite management interfaces (CsrAxiLiteManager VVCs)
      IngressRec         : InOut AddressBusRecType ;  -- ingress MAC s_axi
      EgressRec          : InOut AddressBusRecType ;  -- egress MAC s_axi
      StatsRec           : InOut AddressBusRecType ;  -- Frame_Stats s_axi

      -- GMII of the TB-side SGMII PHY partner: the traffic injection and
      -- extraction point for the full-BD traffic test. All discrete
      -- signals (never records) -- see README 7.12d for the XSim reason.
      GmiiClk            : In    std_logic ;                      -- partner userclk2
      GmiiClkEn          : In    std_logic ;                      -- sgmii_clk_en
      GmiiTxd            : Out   std_logic_vector(7 downto 0) ;
      GmiiTxEn           : Out   std_logic ;
      GmiiTxEr           : Out   std_logic ;
      GmiiRxd            : In    std_logic_vector(7 downto 0) ;
      GmiiRxDv           : In    std_logic ;
      GmiiRxEr           : In    std_logic ;
      PartnerStatus      : In    std_logic_vector(15 downto 0) ;  -- pcs status_vector
      PartnerResetDone   : In    std_logic ;

      -- Egress TX-control stream VVC (AxiStreamTransmitter on s_axis_txc):
      -- the AXI Ethernet buffer needs a 6-word control packet per frame
      TxcRec             : InOut StreamRecType
  ) ;
end entity TestCtrlFull ;
