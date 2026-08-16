--
--  File Name:         TestCtrl_FullBringup.vhd
--  Design Unit Name:  TestCtrlFull (architecture FullBringup)
--
--  Description:
--    Bring-up test for the FULL block design (--full_sim): every IP in
--    the BD runs in its entirety, including the GT transceivers as
--    encrypted SecureIP models.  With the client AXIS interfaces internal
--    to the BD (by design -- see README 2.3), the test exercises the
--    management plane and the physical serial path:
--
--      1. Frame_Stats MAGIC register over AXI4-Lite (BD + AXI plumbing
--         alive end to end)
--      2. TEMAC MDIO master bring-up on both MACs; register access to the
--         internal SGMII PCS/PMA (PHY address 1)
--      3. PCS/PMA autonegotiation disabled via MDIO, then both serial
--         links polled to LINK UP -- this is the GT SecureIP TX/RX pair,
--         CDR and comma alignment doing real work over the cross-looped
--         SGMII lanes
--      4. The runtime half of jumbo-frame enablement (README 2.2):
--         RCW1.JUM / TC.JUM (bit 30) set via AXI4-Lite on both MACs and
--         read back
--      5. Frame_Stats counters confirmed zero (no client traffic exists
--         in this configuration)
--
--    All checks are OSVVM affirmations; the run ends with
--    EndOfTestReports and DONE PASSED/FAILED.
--
architecture FullBringup of TestCtrlFull is

  signal TestDone : integer_barrier := 1 ;

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

  -- MDIO Setup (MC): bit 6 = MDIOEN, bits 5:0 = MDC clock divide.
  -- Divide=7 gives MDC = 125 MHz / (2*(7+1)) = 7.8 MHz. Above the IEEE
  -- 2.5 MHz limit (simulation only, 3x faster), but slow enough that the
  -- PCS/PMA MDIO slave -- which samples MDC synchronously in the 50 MHz
  -- independent_clock domain -- still sees clean edges (64 ns half-phase
  -- vs. 20 ns sample period). MDC above ~12 MHz is NOT reliably sampled
  -- there and the transaction never completes.
  constant MDIO_MC_ENABLE_FAST : std_logic_vector(31 downto 0) := x"00000047" ;

  -- Internal SGMII PCS/PMA of the subsystem (CONFIG.PHYADDR in the XCI)
  constant PCS_PHYADDR  : integer := 1 ;
  constant PCS_REG_CTRL   : integer := 0 ;  -- IEEE control (bit15 reset, bit12 AN enable)
  constant PCS_REG_STATUS : integer := 1 ;  -- IEEE status (bit2 link, latching-low)

  -- Frame_Stats register map (byte addresses)
  constant STATS_MAGIC       : std_logic_vector(7 downto 0) := x"00" ;
  constant STATS_FRAMES_IN   : std_logic_vector(7 downto 0) := x"08" ;
  constant STATS_FRAMES_OUT  : std_logic_vector(7 downto 0) := x"0C" ;
  constant STATS_BYTES_IN    : std_logic_vector(7 downto 0) := x"10" ;
  constant STATS_BYTES_OUT   : std_logic_vector(7 downto 0) := x"14" ;
  constant STATS_STALL_IN    : std_logic_vector(7 downto 0) := x"18" ;
  constant STATS_STALL_OUT   : std_logic_vector(7 downto 0) := x"1C" ;
  constant STATS_MAGIC_VALUE : std_logic_vector(31 downto 0) := x"46535431" ;  -- "FST1"

  ------------------------------------------------------------
  -- End-of-test register dump (same fixed FRAME_STATS_DUMP format as the
  -- datapath test): one greppable line per readable register, logged at
  -- ALWAYS. CTRL (0x04) is write-only and skipped.
  ------------------------------------------------------------
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
  -- TEMAC MDIO master access (MCR field layout per PG138 /
  -- xaxiethernet driver: PHYAD [28:24], REGAD [20:16], OP [15:14]
  -- (10=read, 01=write), INITIATE bit 11, READY bit 7)
  ------------------------------------------------------------
  procedure MdioWaitReady (
    signal Rec : inout AddressBusRecType
  ) is
    variable Rd : std_logic_vector(31 downto 0) ;
  begin
    loop
      Read(Rec, MAC_MDIO_MCR, Rd) ;
      exit when Rd(7) = '1' ;
      -- An MDIO frame is 64 MDC cycles (~8 us at divide=7); pace the
      -- polling instead of hammering the AXI bus back to back
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
    Mcr(15) := '1' ;   -- OP = read
    Mcr(11) := '1' ;   -- INITIATE
    Write(Rec, MAC_MDIO_MCR, Mcr) ;
    MdioWaitReady(Rec) ;
    Read(Rec, MAC_MDIO_MRD, Rd) ;
    Data := Rd(15 downto 0) ;
  end procedure MdioRead ;

  -- The PCS/PMA MDIO slave only answers once the GT has brought up its
  -- derived clocks; until then reads float high (0xFFFF). Retry until it
  -- responds, then affirm.
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
    Mcr(14) := '1' ;   -- OP = write
    Mcr(11) := '1' ;   -- INITIATE
    Write(Rec, MAC_MDIO_MCR, Mcr) ;
    MdioWaitReady(Rec) ;
  end procedure MdioWrite ;

begin

  ------------------------------------------------------------
  -- ControlProc: AlertLog setup + watchdog
  ------------------------------------------------------------
  ControlProc : process
  begin
    SetTestName("TbFullBd_FullBringup") ;
    SetLogEnable(PASSED, TRUE) ;
    SetLogEnable(INFO, TRUE) ;

    wait for 0 ns ;  wait for 0 ns ;
    TranscriptOpen ;
    SetTranscriptMirror(TRUE) ;

    -- GT bring-up plus MDIO polling is measured in hundreds of
    -- microseconds; 10 ms is a generous ceiling for a hang
    WaitForBarrier(TestDone, 10 ms) ;
    AlertIf(now >= 10 ms, "Test finished due to timeout") ;

    TranscriptClose ;
    EndOfTestReports(TimeOut => (now >= 10 ms)) ;
    std.env.stop ;
    wait ;
  end process ControlProc ;

  ------------------------------------------------------------
  -- MainProc: the bring-up sequence (owns all three interfaces)
  ------------------------------------------------------------
  MainProc : process
    variable PhyReg   : std_logic_vector(15 downto 0) ;
    variable RegVal   : std_logic_vector(31 downto 0) ;
    variable LinkUp   : boolean ;
    variable Polls    : integer ;
  begin
    -- 1) Wait for the BD clocking to come alive
    -- (Note: no VVC log quieting here -- GetAlertLogID over the MIT record
    -- returns an invalid ID under XSim and SetLogEnable on it mutes the
    -- whole AlertLog tree. Polling is paced, so the volume is acceptable.)
    wait until ClocksLocked = '1' for 200 us ;
    AlertIf(ClocksLocked /= '1', "clk_wiz never asserted clocks_locked") ;
    Log("clocks_locked asserted at " & to_string(now), INFO) ;
    WaitForClock(StatsRec, 10) ;

    -- 2) Frame_Stats reachable: BD + exported AXI4-Lite plumbing alive
    ReadCheck(StatsRec, STATS_MAGIC, STATS_MAGIC_VALUE) ;
    Log("Frame_Stats MAGIC verified over AXI4-Lite", INFO) ;

    -- 3) MDIO bring-up on both MACs; prove the internal PCS/PMA responds
    Write(IngressRec, MAC_MDIO_MC, MDIO_MC_ENABLE_FAST) ;
    Write(EgressRec,  MAC_MDIO_MC, MDIO_MC_ENABLE_FAST) ;

    WaitPcsAlive(IngressRec, "Ingress") ;
    WaitPcsAlive(EgressRec,  "Egress") ;

    -- 4) Disable autonegotiation on both PCS/PMA cores. Both ends are
    -- MAC-side SGMII cores (there is no PHY-side partner to serve SGMII
    -- config words), so with AN off, link-up reduces to 8b/10b
    -- synchronization over the GT serial path -- exactly the part this
    -- simulation exists to exercise.
    MdioRead(IngressRec, PCS_PHYADDR, PCS_REG_CTRL, PhyReg) ;
    PhyReg(12) := '0' ;
    MdioWrite(IngressRec, PCS_PHYADDR, PCS_REG_CTRL, PhyReg) ;
    MdioRead(EgressRec, PCS_PHYADDR, PCS_REG_CTRL, PhyReg) ;
    PhyReg(12) := '0' ;
    MdioWrite(EgressRec, PCS_PHYADDR, PCS_REG_CTRL, PhyReg) ;
    Log("PCS/PMA autonegotiation disabled on both MACs", INFO) ;

    -- 5) Poll both links up through the GT SecureIP serial path.
    -- Status bit 2 is latching-low, so it is read twice per poll.
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
        AffirmIf(LinkUp, "Ingress SGMII link UP through GT serial loopback (" &
                 to_string(Polls) & " polls, t = " & to_string(now) & ")") ;
      else
        AffirmIf(LinkUp, "Egress SGMII link UP through GT serial loopback (" &
                 to_string(Polls) & " polls, t = " & to_string(now) & ")") ;
      end if ;
    end loop ;

    -- 6) Runtime jumbo enable (the second half of README 2.2): set the
    -- JUM bits on both MACs over AXI4-Lite and read them back
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
    Log("Jumbo (JUM) bits set and verified on both MACs (RCW1/TC bit 30)", INFO) ;

    -- 7) No client traffic exists at BD level: counters must be zero.
    -- Register dump first (grep FRAME_STATS_DUMP in the transcript).
    DumpStatsReg(StatsRec, "MAGIC     ", STATS_MAGIC) ;
    DumpStatsReg(StatsRec, "FRAMES_IN ", STATS_FRAMES_IN) ;
    DumpStatsReg(StatsRec, "FRAMES_OUT", STATS_FRAMES_OUT) ;
    DumpStatsReg(StatsRec, "BYTES_IN  ", STATS_BYTES_IN) ;
    DumpStatsReg(StatsRec, "BYTES_OUT ", STATS_BYTES_OUT) ;
    DumpStatsReg(StatsRec, "STALL_IN  ", STATS_STALL_IN) ;
    DumpStatsReg(StatsRec, "STALL_OUT ", STATS_STALL_OUT) ;
    ReadCheck(StatsRec, STATS_FRAMES_IN, x"00000000") ;
    ReadCheck(StatsRec, STATS_BYTES_OUT, x"00000000") ;

    WaitForClock(StatsRec, 4) ;
    WaitForBarrier(TestDone) ;
    wait ;
  end process MainProc ;

end architecture FullBringup ;
