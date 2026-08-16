--
--  File Name:         TestCtrl_FullTraffic.vhd
--  Design Unit Name:  TestCtrlFull (architecture FullTraffic)
--
--  Description:
--    Full block-design TRAFFIC test (--full_sim): bring-up first (as the
--    FullBringup architecture: clocks, MDIO, AN off, links up, jumbo
--    bits), then REAL FRAMES pushed through the entire UUT over the
--    serial lanes:
--
--      TB GMII -> PHY partner -> GT serial -> ingress MAC -> FIFO ->
--        egress MAC -> GT serial -> PHY partner -> TB GMII
--
--    Stimulus is constrained-random (sizes from 64 B to 9018 B jumbo,
--    ~1 in 6 frames FCS-corrupted) and every wire frame is written to a
--    fresh PCAP. Checking is OSVVM-scoreboard based:
--
--      * The ingress TEMAC validates and STRIPS the FCS and its buffer
--        DISCARDS errored frames, so only clean frames cross the FIFO.
--      * The egress TEMAC REGENERATES the FCS, which for clean frames
--        equals the original -- so wire-out must equal wire-in byte for
--        byte, and each received frame's FCS is also re-validated
--        independently.
--      * Frame_Stats (in-BD, monitor taps on the FIFO) must agree with
--        the clean-frame count and client byte count -- register
--        observability against wire truth, through AMD's own MACs.
--
library ieee ;
  use ieee.std_logic_1164.all ;
  use ieee.numeric_std.all ;

library osvvm ;
  context osvvm.OsvvmContext ;
  use osvvm.ScoreboardPkg_slv.all ;

library osvvm_common ;
  context osvvm_common.OsvvmCommonContext ;

use work.EthFramePkg.all ;

architecture FullTraffic of TestCtrlFull is

  signal TestDone : integer_barrier := 1 ;
  -- Runtime NewID + ID-handle signal + barrier: the XSim-safe OSVVM
  -- singleton pattern (README 7.8)
  signal InitDone : integer_barrier := 1 ;

  signal SB_Wire : ScoreboardIdType ;

  -- Burst FIFO of the egress TX-control VVC (same alias pattern as the
  -- datapath TestCtrl; transaction-record aliases are XSim-safe)
  alias TxcBurstFifo : ScoreboardIdType is TxcRec.BurstFifo ;

  -- Traffic coordination (TB-internal)
  signal TrafficStart    : boolean := FALSE ;
  signal TxTrafficDone   : boolean := FALSE ;
  signal CleanCount      : integer := 0 ;  -- frames the MACs should pass
  signal CleanClientBytes: integer := 0 ;  -- FCS-less bytes crossing the FIFO
  signal RxFramesChecked : integer := 0 ;

  constant TRAFFIC_FRAMES : integer := 40 ;

  ------------------------------------------------------------
  -- AXI Ethernet Subsystem register map (PG138) -- 18-bit addresses
  ------------------------------------------------------------
  subtype MacAddrType is std_logic_vector(17 downto 0) ;
  constant MAC_RCW1     : MacAddrType := std_logic_vector(to_unsigned(16#00404#, 18)) ;
  constant MAC_TC       : MacAddrType := std_logic_vector(to_unsigned(16#00408#, 18)) ;
  constant MAC_MDIO_MC  : MacAddrType := std_logic_vector(to_unsigned(16#00500#, 18)) ;
  constant MAC_MDIO_MCR : MacAddrType := std_logic_vector(to_unsigned(16#00504#, 18)) ;
  constant MAC_MDIO_MWD : MacAddrType := std_logic_vector(to_unsigned(16#00508#, 18)) ;
  constant MAC_MDIO_MRD : MacAddrType := std_logic_vector(to_unsigned(16#0050C#, 18)) ;
  -- Address Filter Mode: bit 31 = promiscuous. Random DAs in the traffic
  -- would otherwise be dropped by the ingress frame filter.
  constant MAC_AFM      : MacAddrType := std_logic_vector(to_unsigned(16#00708#, 18)) ;

  constant MDIO_MC_ENABLE_FAST : std_logic_vector(31 downto 0) := x"00000047" ;
  constant PCS_PHYADDR  : integer := 1 ;
  constant PCS_REG_CTRL   : integer := 0 ;
  constant PCS_REG_STATUS : integer := 1 ;

  -- Frame_Stats register map (byte addresses)
  constant STATS_MAGIC       : std_logic_vector(7 downto 0) := x"00" ;
  constant STATS_CTRL        : std_logic_vector(7 downto 0) := x"04" ;
  constant STATS_FRAMES_IN   : std_logic_vector(7 downto 0) := x"08" ;
  constant STATS_FRAMES_OUT  : std_logic_vector(7 downto 0) := x"0C" ;
  constant STATS_BYTES_IN    : std_logic_vector(7 downto 0) := x"10" ;
  constant STATS_BYTES_OUT   : std_logic_vector(7 downto 0) := x"14" ;
  constant STATS_STALL_IN    : std_logic_vector(7 downto 0) := x"18" ;
  constant STATS_STALL_OUT   : std_logic_vector(7 downto 0) := x"1C" ;
  constant STATS_MAGIC_VALUE : std_logic_vector(31 downto 0) := x"46535431" ;

  ------------------------------------------------------------
  -- TEMAC MDIO master access (same as FullBringup)
  ------------------------------------------------------------
  procedure MdioWaitReady (
    signal Rec : inout AddressBusRecType
  ) is
    variable Rd : std_logic_vector(31 downto 0) ;
  begin
    loop
      Read(Rec, MAC_MDIO_MCR, Rd) ;
      exit when Rd(7) = '1' ;
      WaitForClock(Rec, 50) ;
    end loop ;
  end procedure MdioWaitReady ;

  procedure MdioRead (
    signal   Rec     : inout AddressBusRecType ;
    constant PhyAddr : in    integer ;
    constant RegAddr : in    integer ;
    variable Data    : out   std_logic_vector(15 downto 0)
  ) is
    variable Mcr : std_logic_vector(31 downto 0) := (others => '0') ;
    variable Rd  : std_logic_vector(31 downto 0) ;
  begin
    MdioWaitReady(Rec) ;
    Mcr(28 downto 24) := std_logic_vector(to_unsigned(PhyAddr, 5)) ;
    Mcr(20 downto 16) := std_logic_vector(to_unsigned(RegAddr, 5)) ;
    Mcr(15) := '1' ;
    Mcr(11) := '1' ;
    Write(Rec, MAC_MDIO_MCR, Mcr) ;
    MdioWaitReady(Rec) ;
    Read(Rec, MAC_MDIO_MRD, Rd) ;
    Data := Rd(15 downto 0) ;
  end procedure MdioRead ;

  procedure MdioWrite (
    signal   Rec     : inout AddressBusRecType ;
    constant PhyAddr : in    integer ;
    constant RegAddr : in    integer ;
    constant Data    : in    std_logic_vector(15 downto 0)
  ) is
    variable Mcr : std_logic_vector(31 downto 0) := (others => '0') ;
  begin
    MdioWaitReady(Rec) ;
    Write(Rec, MAC_MDIO_MWD, x"0000" & Data) ;
    Mcr(28 downto 24) := std_logic_vector(to_unsigned(PhyAddr, 5)) ;
    Mcr(20 downto 16) := std_logic_vector(to_unsigned(RegAddr, 5)) ;
    Mcr(14) := '1' ;
    Mcr(11) := '1' ;
    Write(Rec, MAC_MDIO_MCR, Mcr) ;
    MdioWaitReady(Rec) ;
  end procedure MdioWrite ;

  procedure WaitPcsAlive (
    signal   Rec  : inout AddressBusRecType ;
    constant Name : in    string
  ) is
    variable PhyReg : std_logic_vector(15 downto 0) ;
    variable Polls  : integer := 0 ;
  begin
    loop
      MdioRead(Rec, PCS_PHYADDR, PCS_REG_STATUS, PhyReg) ;
      exit when PhyReg /= x"FFFF" or Polls >= 100 ;
      Polls := Polls + 1 ;
      WaitForClock(Rec, 200) ;
    end loop ;
    AffirmIf(PhyReg /= x"FFFF",
             Name & " PCS/PMA responds on MDIO (status = 0x" & to_hstring(PhyReg) &
             ", " & to_string(Polls) & " retries)") ;
  end procedure WaitPcsAlive ;

  procedure DumpStatsReg (
    signal   Rec  : inout AddressBusRecType ;
    constant Name : in    string ;
    constant Addr : in    std_logic_vector
  ) is
    variable V : std_logic_vector(31 downto 0) ;
  begin
    Read(Rec, Addr, V) ;
    Log("FRAME_STATS_DUMP " & Name & " = 0x" & to_hstring(V) &
        " (" & to_string(to_integer(unsigned(V))) & ")", ALWAYS) ;
  end procedure DumpStatsReg ;

  ------------------------------------------------------------
  -- GMII byte-level driving (partner MAC-side GMII, 1 Gb/s: one byte per
  -- GmiiClk cycle qualified by GmiiClkEn)
  ------------------------------------------------------------
  procedure GmiiSendFrame (
    signal   Clk   : in  std_logic ;
    signal   ClkEn : in  std_logic ;
    signal   Txd   : out std_logic_vector(7 downto 0) ;
    signal   TxEn  : out std_logic ;
    constant Frame : in  ByteArrayType
  ) is
  begin
    for i in 1 to 7 loop
      wait until rising_edge(Clk) and ClkEn = '1' ;
      Txd  <= x"55" ;
      TxEn <= '1' ;
    end loop ;
    wait until rising_edge(Clk) and ClkEn = '1' ;
    Txd <= x"D5" ;
    for i in Frame'range loop
      wait until rising_edge(Clk) and ClkEn = '1' ;
      Txd <= Frame(i) ;
    end loop ;
    wait until rising_edge(Clk) and ClkEn = '1' ;
    TxEn <= '0' ;
    Txd  <= (others => '0') ;
  end procedure GmiiSendFrame ;

begin

  ------------------------------------------------------------
  -- ControlProc: AlertLog, runtime scoreboard creation, watchdog
  ------------------------------------------------------------
  ControlProc : process
    variable vSbWire : ScoreboardIdType ;
  begin
    SetTestName("TbFullBd_FullTraffic") ;
    SetLogEnable(PASSED, TRUE) ;
    SetLogEnable(INFO, TRUE) ;

    wait for 0 ns ;  wait for 0 ns ;
    TranscriptOpen ;
    SetTranscriptMirror(TRUE) ;

    vSbWire := NewID("WireFrames") ;
    -- ~100 KB of byte-level checks; keep the transcript frame-level
    SetLogEnable(GetAlertLogID(vSbWire), PASSED, FALSE) ;
    SB_Wire <= vSbWire ;
    wait for 0 ns ;
    WaitForBarrier(InitDone) ;

    -- Bring-up is ~120 us; wire traffic adds ~1 ms of 1 Gb/s serial
    WaitForBarrier(TestDone, 50 ms) ;
    AlertIf(now >= 50 ms, "Test finished due to timeout") ;

    TranscriptClose ;
    EndOfTestReports(TimeOut => (now >= 50 ms)) ;
    std.env.stop ;
    wait ;
  end process ControlProc ;

  ------------------------------------------------------------
  -- MainProc: bring-up, MAC configuration, traffic control, final checks
  ------------------------------------------------------------
  MainProc : process
    variable PhyReg   : std_logic_vector(15 downto 0) ;
    variable RegVal   : std_logic_vector(31 downto 0) ;
    variable LinkUp   : boolean ;
    variable Polls    : integer ;
  begin
    WaitForBarrier(InitDone) ;

    -- 1) Clocks and reset
    wait until ClocksLocked = '1' for 200 us ;
    AlertIf(ClocksLocked /= '1', "clk_wiz never asserted clocks_locked") ;
    Log("clocks_locked asserted at " & to_string(now), INFO) ;
    WaitForClock(StatsRec, 10) ;

    -- 2) Frame_Stats alive
    ReadCheck(StatsRec, STATS_MAGIC, STATS_MAGIC_VALUE) ;
    Log("Frame_Stats MAGIC verified over AXI4-Lite", INFO) ;

    -- 3) MDIO up, PCS/PMA reachable on both MACs
    Write(IngressRec, MAC_MDIO_MC, MDIO_MC_ENABLE_FAST) ;
    Write(EgressRec,  MAC_MDIO_MC, MDIO_MC_ENABLE_FAST) ;
    WaitPcsAlive(IngressRec, "Ingress") ;
    WaitPcsAlive(EgressRec,  "Egress") ;

    -- 4) AN off on both MAC-side PCS (the TB partner was generated with
    -- AN disabled, so all three links come up on 8b/10b sync alone)
    MdioRead(IngressRec, PCS_PHYADDR, PCS_REG_CTRL, PhyReg) ;
    PhyReg(12) := '0' ;
    MdioWrite(IngressRec, PCS_PHYADDR, PCS_REG_CTRL, PhyReg) ;
    MdioRead(EgressRec, PCS_PHYADDR, PCS_REG_CTRL, PhyReg) ;
    PhyReg(12) := '0' ;
    MdioWrite(EgressRec, PCS_PHYADDR, PCS_REG_CTRL, PhyReg) ;
    Log("PCS/PMA autonegotiation disabled on both MACs", INFO) ;

    -- 5) All three links up: ingress (from partner TX), egress (from
    -- ingress TX), partner (from egress TX; status_vector bit 0)
    for Mac in 0 to 1 loop
      LinkUp := FALSE ;
      Polls  := 0 ;
      while not LinkUp and Polls < 400 loop
        if Mac = 0 then
          MdioRead(IngressRec, PCS_PHYADDR, PCS_REG_STATUS, PhyReg) ;
          MdioRead(IngressRec, PCS_PHYADDR, PCS_REG_STATUS, PhyReg) ;
          LinkUp := PhyReg(2) = '1' ;
          exit when LinkUp ;
          WaitForClock(IngressRec, 200) ;
        else
          MdioRead(EgressRec, PCS_PHYADDR, PCS_REG_STATUS, PhyReg) ;
          MdioRead(EgressRec, PCS_PHYADDR, PCS_REG_STATUS, PhyReg) ;
          LinkUp := PhyReg(2) = '1' ;
          exit when LinkUp ;
          WaitForClock(EgressRec, 200) ;
        end if ;
        Polls := Polls + 1 ;
      end loop ;
      if Mac = 0 then
        AffirmIf(LinkUp, "Ingress SGMII link UP through GT serial (" &
                 to_string(Polls) & " polls, t = " & to_string(now) & ")") ;
      else
        AffirmIf(LinkUp, "Egress SGMII link UP through GT serial (" &
                 to_string(Polls) & " polls, t = " & to_string(now) & ")") ;
      end if ;
    end loop ;
    if PartnerResetDone /= '1' then
      wait until PartnerResetDone = '1' for 500 us ;
    end if ;
    Polls := 0 ;
    while PartnerStatus(0) /= '1' and Polls < 400 loop
      WaitForClock(StatsRec, 200) ;
      Polls := Polls + 1 ;
    end loop ;
    AffirmIf(PartnerStatus(0) = '1',
             "PHY partner link UP (status_vector(0), " & to_string(Polls) & " polls)") ;

    -- 6) Jumbo enable (RCW1/TC bit 30) on both MACs, verified
    for Mac in 0 to 1 loop
      if Mac = 0 then
        Read(IngressRec, MAC_RCW1, RegVal) ;
        RegVal(30) := '1' ;
        Write(IngressRec, MAC_RCW1, RegVal) ;
        ReadCheck(IngressRec, MAC_RCW1, RegVal) ;
        Read(IngressRec, MAC_TC, RegVal) ;
        RegVal(30) := '1' ;
        Write(IngressRec, MAC_TC, RegVal) ;
        ReadCheck(IngressRec, MAC_TC, RegVal) ;
      else
        Read(EgressRec, MAC_RCW1, RegVal) ;
        RegVal(30) := '1' ;
        Write(EgressRec, MAC_RCW1, RegVal) ;
        ReadCheck(EgressRec, MAC_RCW1, RegVal) ;
        Read(EgressRec, MAC_TC, RegVal) ;
        RegVal(30) := '1' ;
        Write(EgressRec, MAC_TC, RegVal) ;
        ReadCheck(EgressRec, MAC_TC, RegVal) ;
      end if ;
    end loop ;
    Log("Jumbo (JUM) bits set and verified on both MACs", INFO) ;

    -- 7) Promiscuous mode on the ingress MAC: the constrained-random DAs
    -- would otherwise be dropped by the address filter
    Read(IngressRec, MAC_AFM, RegVal) ;
    RegVal(31) := '1' ;
    Write(IngressRec, MAC_AFM, RegVal) ;
    ReadCheck(IngressRec, MAC_AFM, RegVal) ;
    Log("Ingress MAC promiscuous mode enabled (AFM bit 31)", INFO) ;

    -- 8) Traffic. The wait is PROGRESS-based: as long as frames keep
    -- arriving, keep waiting; a 2 ms window with no new frames is a
    -- stall (a flat long timeout at idle wire speed costs the better
    -- part of an hour of wall time -- learned the hard way).
    Log("Starting wire traffic: " & to_string(TRAFFIC_FRAMES) &
        " constrained-random frames through the full BD", INFO) ;
    TrafficStart <= TRUE ;
    WaitOnTraffic : loop
      exit WaitOnTraffic when TxTrafficDone and RxFramesChecked = CleanCount ;
      Polls := RxFramesChecked ;
      wait until (TxTrafficDone and RxFramesChecked = CleanCount) for 2 ms ;
      exit WaitOnTraffic when TxTrafficDone and RxFramesChecked = CleanCount ;
      if RxFramesChecked = Polls then
        Alert("Traffic stalled: " & to_string(RxFramesChecked) & "/" &
              to_string(CleanCount) & " clean frames received, no progress in 2 ms") ;
        exit WaitOnTraffic ;
      end if ;
    end loop WaitOnTraffic ;
    AffirmIfEqual(RxFramesChecked, CleanCount, "Clean frames received at partner GMII") ;
    AffirmIf(IsEmpty(SB_Wire), "Wire scoreboard drained (no lost frames)") ;

    -- 9) Frame_Stats measured the real traffic: register observability
    -- against wire truth, through AMD's MACs (client bytes are FCS-less)
    WaitForClock(StatsRec, 20) ;
    ReadCheck(StatsRec, STATS_FRAMES_IN,
              std_logic_vector(to_unsigned(CleanCount, 32))) ;
    ReadCheck(StatsRec, STATS_FRAMES_OUT,
              std_logic_vector(to_unsigned(CleanCount, 32))) ;
    ReadCheck(StatsRec, STATS_BYTES_IN,
              std_logic_vector(to_unsigned(CleanClientBytes, 32))) ;
    ReadCheck(StatsRec, STATS_BYTES_OUT,
              std_logic_vector(to_unsigned(CleanClientBytes, 32))) ;
    Log("Frame_Stats counters match wire truth (" & to_string(CleanCount) &
        " frames, " & to_string(CleanClientBytes) & " client bytes)", INFO) ;

    DumpStatsReg(StatsRec, "MAGIC     ", STATS_MAGIC) ;
    DumpStatsReg(StatsRec, "FRAMES_IN ", STATS_FRAMES_IN) ;
    DumpStatsReg(StatsRec, "FRAMES_OUT", STATS_FRAMES_OUT) ;
    DumpStatsReg(StatsRec, "BYTES_IN  ", STATS_BYTES_IN) ;
    DumpStatsReg(StatsRec, "BYTES_OUT ", STATS_BYTES_OUT) ;
    DumpStatsReg(StatsRec, "STALL_IN  ", STATS_STALL_IN) ;
    DumpStatsReg(StatsRec, "STALL_OUT ", STATS_STALL_OUT) ;

    WaitForClock(StatsRec, 4) ;
    WaitForBarrier(TestDone) ;
    wait ;
  end process MainProc ;

  ------------------------------------------------------------
  -- GmiiTxProc: constrained-random wire frames into the partner GMII,
  -- PCAP'd and scoreboarded (clean frames only -- the ingress MAC
  -- discards the FCS-corrupted ones)
  ------------------------------------------------------------
  GmiiTxProc : process
    file     PcapFile  : ByteFileType ;
    constant PCAP_NAME : string := "TbFullBd_FullTraffic_tx.pcap" ;
    variable RV         : RandomPType ;
    variable Frame      : ByteArrayType(0 to ETH_MAX_JUMBO_FRAME-1) ;
    variable Fcs        : ByteArrayType(0 to ETH_FCS_LEN-1) ;
    variable FrameLen   : integer ;
    variable PayloadLen : integer ;
    variable LenBin     : integer ;
    variable ErrInj     : integer ;
    variable CorruptIdx : integer ;
    variable Gap        : integer ;
    variable vClean     : integer := 0 ;
    variable vBytes     : integer := 0 ;
  begin
    GmiiTxd  <= (others => '0') ;
    GmiiTxEn <= '0' ;
    GmiiTxEr <= '0' ;
    WaitForBarrier(InitDone) ;
    wait until TrafficStart ;
    SetBurstMode(TxcRec, STREAM_BURST_BYTE_MODE) ;
    RV.InitSeed(RV'instance_name) ;

    file_open(PcapFile, PCAP_NAME, write_mode) ;
    PcapWriteGlobalHeader(PcapFile) ;

    for FrameNum in 0 to TRAFFIC_FRAMES-1 loop
      -- Size: pinned corners first, then weighted random
      case FrameNum is
        when 0 | 1 | 2 => FrameLen := ETH_MIN_FRAME ;
        when 3 | 4     => FrameLen := ETH_MAX_JUMBO_FRAME ;
        when 5 | 6 | 7 => FrameLen := ETH_MAX_FRAME ;
        when others =>
          LenBin := RV.DistInt((30, 30, 25, 10, 5)) ;
          case LenBin is
            when 0      => FrameLen := RV.RandInt(  65,  127) ;
            when 1      => FrameLen := RV.RandInt( 128,  511) ;
            when 2      => FrameLen := RV.RandInt( 512, 1517) ;
            when 3      => FrameLen := RV.RandInt(1519, 4095) ;
            when others => FrameLen := RV.RandInt(4096, 9017) ;
          end case ;
      end case ;

      -- ~1 in 6 frames FCS-corrupted (frame 8 always, for determinism)
      if FrameNum = 8 then
        ErrInj := 1 ;
      else
        ErrInj := RV.DistInt((5, 1)) ;
      end if ;

      -- Real frame content (same construction as the datapath test)
      PayloadLen := FrameLen - ETH_HEADER_LEN - ETH_FCS_LEN ;
      Frame(0) := x"02" ;
      Frame(6) := x"02" ;
      for i in 1 to 5 loop
        Frame(i)   := RV.RandSlv(8) ;
        Frame(6+i) := RV.RandSlv(8) ;
      end loop ;
      if PayloadLen <= 1500 then
        Frame(12) := std_logic_vector(to_unsigned(PayloadLen, 16)(15 downto 8)) ;
        Frame(13) := std_logic_vector(to_unsigned(PayloadLen, 16)( 7 downto 0)) ;
      else
        Frame(12) := x"88" ;
        Frame(13) := x"B5" ;
      end if ;
      for i in 0 to PayloadLen-1 loop
        Frame(ETH_HEADER_LEN + i) := RV.RandSlv(8) ;
      end loop ;
      Fcs := CalcFcs(Frame(0 to FrameLen-ETH_FCS_LEN-1)) ;
      if ErrInj = 1 then
        CorruptIdx := RV.RandInt(0, ETH_FCS_LEN-1) ;
        Fcs(CorruptIdx) := Fcs(CorruptIdx) xor RV.RandSlv(1, 255, 8) ;
      end if ;
      for i in 0 to ETH_FCS_LEN-1 loop
        Frame(FrameLen-ETH_FCS_LEN+i) := Fcs(i) ;
      end loop ;

      -- Capture the wire frame (corrupted ones included -- Wireshark's
      -- FCS validation flags them), scoreboard only the clean ones
      PcapWriteFrame(PcapFile, Frame(0 to FrameLen-1), now) ;
      if ErrInj = 0 then
        for i in 0 to FrameLen-1 loop
          Push(SB_Wire, Frame(i)) ;
        end loop ;
        vClean := vClean + 1 ;
        vBytes := vBytes + FrameLen - ETH_FCS_LEN ;
        CleanCount       <= vClean ;
        CleanClientBytes <= vBytes ;
        -- Host-DMA stand-in: the AXI Ethernet buffer releases a TX frame
        -- only when a control packet accompanies it on s_axis_txc -- one
        -- 6-word null-offload packet per frame that will reach the egress
        -- MAC (flag word 0xA0000000, app words zero; corrupted frames are
        -- dropped at ingress and must NOT get one)
        Push(TxcBurstFifo, x"00") ;
        Push(TxcBurstFifo, x"00") ;
        Push(TxcBurstFifo, x"00") ;
        Push(TxcBurstFifo, x"A0") ;
        for i in 1 to 20 loop
          Push(TxcBurstFifo, x"00") ;
        end loop ;
        SendBurst(TxcRec, 24) ;
      end if ;

      GmiiSendFrame(GmiiClk, GmiiClkEn, GmiiTxd, GmiiTxEn, Frame(0 to FrameLen-1)) ;

      -- Inter-frame gap: legal minimum plus a random stretch
      Gap := 12 + RV.RandInt(0, 20) ;
      for i in 1 to Gap loop
        wait until rising_edge(GmiiClk) and GmiiClkEn = '1' ;
      end loop ;
    end loop ;

    file_close(PcapFile) ;
    Log("GmiiTxProc: sent " & to_string(TRAFFIC_FRAMES) & " wire frames (" &
        to_string(vClean) & " clean), wrote " & PCAP_NAME, INFO) ;
    TxTrafficDone <= TRUE ;
    WaitForBarrier(TestDone) ;
    wait ;
  end process GmiiTxProc ;

  ------------------------------------------------------------
  -- GmiiRxProc: capture frames at the partner GMII RX (egress MAC wire
  -- output), check byte-for-byte and re-validate the regenerated FCS
  ------------------------------------------------------------
  GmiiRxProc : process
    variable Buf     : ByteArrayType(0 to ETH_MAX_JUMBO_FRAME-1) ;
    variable N       : integer ;
    variable SeenSfd : boolean ;
    variable B       : std_logic_vector(7 downto 0) ;
    variable ExpFcs  : ByteArrayType(0 to ETH_FCS_LEN-1) ;
    variable FcsOk   : boolean ;
    variable Count   : integer := 0 ;
  begin
    WaitForBarrier(InitDone) ;
    loop
      wait until rising_edge(GmiiClk) and GmiiClkEn = '1' ;
      if GmiiRxDv = '1' then
        SeenSfd := FALSE ;
        N := 0 ;
        while GmiiRxDv = '1' loop
          B := GmiiRxd ;
          if SeenSfd then
            Buf(N) := B ;
            N := N + 1 ;
          elsif B = x"D5" then
            SeenSfd := TRUE ;
          end if ;
          wait until rising_edge(GmiiClk) and GmiiClkEn = '1' ;
        end loop ;
        if SeenSfd and N > ETH_FCS_LEN then
          for i in 0 to N-1 loop
            Check(SB_Wire, Buf(i)) ;
          end loop ;
          ExpFcs := CalcFcs(Buf(0 to N-ETH_FCS_LEN-1)) ;
          FcsOk  := TRUE ;
          for i in 0 to ETH_FCS_LEN-1 loop
            if Buf(N-ETH_FCS_LEN+i) /= ExpFcs(i) then
              FcsOk := FALSE ;
            end if ;
          end loop ;
          AffirmIf(FcsOk, "Egress-regenerated FCS valid (frame " &
                   to_string(Count) & ", " & to_string(N) & " bytes)") ;
          Count := Count + 1 ;
          RxFramesChecked <= Count ;
        end if ;
      end if ;
    end loop ;
  end process GmiiRxProc ;

end architecture FullTraffic ;
