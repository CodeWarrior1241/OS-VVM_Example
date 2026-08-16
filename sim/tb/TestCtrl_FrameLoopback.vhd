--
--  File Name:         TestCtrl_FrameLoopback.vhd
--  Design Unit Name:  TestCtrl (architecture FrameLoopback)
--
--  Description:
--    Constrained-random Ethernet frame loopback test for the AXI4-Stream
--    frame FIFO datapath, demonstrating the core OSVVM methodology:
--
--      * RandomPkg      -- constrained-random frame length, payload,
--                          inter-frame gap and FCS error injection
--      * ScoreboardPkg  -- self-checking: every transmitted byte is
--                          pushed as "expected"; every received byte is
--                          checked in order.  No eyeballing waveforms.
--      * CoveragePkg    -- functional coverage bins (frame-size bins from
--                          64-byte runts to 9018-byte jumbo frames,
--                          error injection, inter-frame gap / back-to-back
--                          timing, and a size-x-error cross).  The test
--                          runs UNTIL COVERAGE CLOSES, making "done" an
--                          objective, queryable property of the run.
--      * AlertLogPkg    -- AffirmIf/Alert based pass/fail accounting with
--                          a final EndOfTestReports summary + YAML output
--
--    Frame content is real: DA/SA, 802.3 length field, random payload and
--    a genuine CRC-32 FCS.  Error injection corrupts the FCS, and the
--    receive side independently recomputes the CRC and cross-checks the
--    outcome against the injection flag carried in the metadata
--    scoreboard.
--
architecture FrameLoopback of TestCtrl is

  -- Test completion barrier (ControlProc + Transmitter + Receiver)
  signal TestDone : integer_barrier := 1 ;
  -- Data-structure initialization barrier: scoreboards and coverage models
  -- are created AT RUNTIME by ControlProc (not as architecture constants)
  -- and published through the ID signals below. Rationale: XSim 2026.1
  -- re-initializes some OSVVM protected-type shared variables between
  -- constant elaboration and process execution, so elaboration-time NewID
  -- calls desynchronize the OSVVM singletons ("Index of LocalNameStore /=
  -- ScoreboardID" alerts, escalating to a null-access crash). Runtime
  -- creation behaves identically on Questa and keeps XSim working.
  signal InitDone : integer_barrier := 1 ;
  signal TxDone   : boolean := FALSE ;

  -- Safety cap: constrained-random with these weights typically closes
  -- coverage in 200-500 frames; hitting the cap raises an Alert (FAIL).
  constant MAX_FRAMES : integer := 2000 ;

  -- Self-checking scoreboards (created in ControlProc)
  --   SB_Data: every frame byte, in order (checked byte-for-byte on RX)
  --   SB_Meta: one entry per frame: bit 15 = FCS error injected,
  --            bits 13:0 = frame length in bytes (9018 max needs 14 bits)
  signal SB_Data : ScoreboardIdType ;
  signal SB_Meta : ScoreboardIdType ;

  -- Functional coverage models (created in ControlProc)
  signal CovLen     : CoverageIDType ;
  signal CovErr     : CoverageIDType ;
  signal CovGap     : CoverageIDType ;
  signal CovLenXErr : CoverageIDType ;

  -- Frame_Stats register map (byte addresses) and expected magic value
  constant STATS_MAGIC       : std_logic_vector(7 downto 0) := x"00" ;
  constant STATS_CTRL        : std_logic_vector(7 downto 0) := x"04" ;
  constant STATS_FRAMES_IN   : std_logic_vector(7 downto 0) := x"08" ;
  constant STATS_FRAMES_OUT  : std_logic_vector(7 downto 0) := x"0C" ;
  constant STATS_BYTES_IN    : std_logic_vector(7 downto 0) := x"10" ;
  constant STATS_BYTES_OUT   : std_logic_vector(7 downto 0) := x"14" ;
  constant STATS_STALL_IN    : std_logic_vector(7 downto 0) := x"18" ;
  constant STATS_STALL_OUT   : std_logic_vector(7 downto 0) := x"1C" ;
  constant STATS_MAGIC_VALUE : std_logic_vector(31 downto 0) := x"46535431" ;  -- "FST1"

  ------------------------------------------------------------
  -- End-of-test register dump: one fixed-format, greppable line per
  -- readable Frame_Stats register (prefix FRAME_STATS_DUMP), logged at
  -- ALWAYS so it survives log-level filtering and lands in the OSVVM
  -- transcript artifact. CTRL (0x04) is write-only and skipped.
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

  -- Frame length bins reused by the cross model (pure functions - safe as
  -- an elaboration-time constant)
  constant LEN_BINS : CovBinType :=
    GenBin(ETH_MIN_FRAME) &
    GenBin(  65,  127, 1) &
    GenBin( 128,  255, 1) &
    GenBin( 256,  511, 1) &
    GenBin( 512, 1023, 1) &
    GenBin(1024, 1517, 1) &
    GenBin(ETH_MAX_FRAME) &
    GenBin(1519, 4095, 1) &
    GenBin(4096, 8191, 1) &
    GenBin(8192, 9017, 1) &
    GenBin(ETH_MAX_JUMBO_FRAME) ;

begin

  ------------------------------------------------------------
  -- ControlProc
  --   Set up AlertLog, create scoreboards + coverage models,
  --   and wait for end of test
  ------------------------------------------------------------
  ControlProc : process
    variable vSbData, vSbMeta : ScoreboardIdType ;
    variable vCovLen, vCovErr, vCovGap, vCovLenXErr : CoverageIDType ;
  begin
    -- Initialization of test
    SetTestName("TbEthernetFifo_FrameLoopback") ;
    SetLogEnable(PASSED, TRUE) ;   -- Enable PASSED logs
    SetLogEnable(INFO, TRUE) ;     -- Enable INFO logs

    -- Wait for testbench initialization
    wait for 0 ns ;  wait for 0 ns ;
    TranscriptOpen ;
    SetTranscriptMirror(TRUE) ;

    -- Create the OSVVM data structures (runtime NewID - see InitDone note)
    vSbData := NewID("FrameData") ;
    vSbMeta := NewID("FrameMeta") ;
    -- Jumbo scaling: a run now makes ~10^6 byte-level scoreboard checks.
    -- Suppress the per-byte PASSED log lines (failures still alert, and
    -- the affirmation counts still accumulate) so the transcript stays
    -- readable and I/O does not dominate the wall-clock time.
    SetLogEnable(GetAlertLogID(vSbData), PASSED, FALSE) ;
    vCovLen     := NewID("FrameLength") ;
    vCovErr     := NewID("FcsErrorInjection") ;
    vCovGap     := NewID("InterFrameGap") ;
    vCovLenXErr := NewID("FrameLength_x_FcsError") ;

    -- Functional coverage: the objective definition of "done".
    -- Frame-size bins from 64-byte minimum to 9018-byte jumbo, with the
    -- exact corner sizes (64, 1518, 9018) as their own bins. The 1519+
    -- bins only pass through the datapath because the MACs are configured
    -- for jumbo (TXMEM/RXMEM 16k) and the packet FIFO holds 32 KB.
    AddBins(vCovLen, "Len_64_min",     3, GenBin(ETH_MIN_FRAME)) ;
    AddBins(vCovLen, "Len_65_127",    10, GenBin(  65,  127, 1)) ;
    AddBins(vCovLen, "Len_128_255",   10, GenBin( 128,  255, 1)) ;
    AddBins(vCovLen, "Len_256_511",   10, GenBin( 256,  511, 1)) ;
    AddBins(vCovLen, "Len_512_1023",  10, GenBin( 512, 1023, 1)) ;
    AddBins(vCovLen, "Len_1024_1517", 10, GenBin(1024, 1517, 1)) ;
    AddBins(vCovLen, "Len_1518_std",   3, GenBin(ETH_MAX_FRAME)) ;
    AddBins(vCovLen, "Len_1519_4095",  8, GenBin(1519, 4095, 1)) ;
    AddBins(vCovLen, "Len_4096_8191",  8, GenBin(4096, 8191, 1)) ;
    AddBins(vCovLen, "Len_8192_9017",  8, GenBin(8192, 9017, 1)) ;
    AddBins(vCovLen, "Len_9018_jumbo", 3, GenBin(ETH_MAX_JUMBO_FRAME)) ;

    -- Error injection: enough clean and corrupted frames
    AddBins(vCovErr, "Clean",      40, GenBin(0)) ;
    AddBins(vCovErr, "FcsError",    8, GenBin(1)) ;

    -- Inter-frame gap (idle cycles between frames on the TX side):
    -- back-to-back is its own bin -- it must be exercised deliberately
    AddBins(vCovGap, "BackToBack",  5, GenBin(0)) ;
    AddBins(vCovGap, "Gap_1_4",    10, GenBin( 1,  4, 1)) ;
    AddBins(vCovGap, "Gap_5_20",   10, GenBin( 5, 20, 1)) ;
    AddBins(vCovGap, "Gap_21_63",   5, GenBin(21, 63, 1)) ;

    -- Cross: every size bin must be seen both clean and corrupted
    AddCross(vCovLenXErr, GenCross(1, LEN_BINS, GenBin(0, 1, 2))) ;

    -- Publish the ID handles and release the other processes
    SB_Data    <= vSbData ;
    SB_Meta    <= vSbMeta ;
    CovLen     <= vCovLen ;
    CovErr     <= vCovErr ;
    CovGap     <= vCovGap ;
    CovLenXErr <= vCovLenXErr ;
    wait for 0 ns ;
    WaitForBarrier(InitDone) ;

    -- Wait for Design Reset
    wait until nReset = '1' ;
    ClearAlerts ;

    -- Wait for test to finish
    WaitForBarrier(TestDone, 30 ms) ;
    AlertIf(now >= 30 ms, "Test finished due to timeout") ;

    -- Human-readable coverage report into the transcript
    WriteBin(CovLen) ;
    WriteBin(CovErr) ;
    WriteBin(CovGap) ;
    WriteBin(CovLenXErr) ;

    TranscriptClose ;

    EndOfTestReports(TimeOut => (now >= 30 ms)) ;
    std.env.stop ;
    wait ;
  end process ControlProc ;

  ------------------------------------------------------------
  -- TransmitterProc
  --   Constrained-random frame generation, driven by coverage closure
  ------------------------------------------------------------
  TransmitterProc : process
    variable RV         : RandomPType ;
    variable Frame      : ByteArrayType(0 to ETH_MAX_JUMBO_FRAME-1) ;
    variable Fcs        : ByteArrayType(0 to ETH_FCS_LEN-1) ;
    variable FrameLen   : integer ;
    variable PayloadLen : integer ;
    variable Gap        : integer ;
    variable LenBin     : integer ;
    variable GapBin     : integer ;
    variable ErrInj     : integer ;
    variable CorruptIdx : integer ;
    variable FrameCount : integer := 0 ;
    variable Meta       : std_logic_vector(15 downto 0) ;
    variable TxLogID    : AlertLogIDType ;
  begin
    WaitForBarrier(InitDone) ;
    wait until nReset = '1' ;
    WaitForClock(StreamTxRec, 2) ;
    SetBurstMode(StreamTxRec, STREAM_BURST_BYTE_MODE) ;
    -- The VVC logs every stream word at INFO ("Axi Stream Send"); at
    -- jumbo-frame volume that is ~10^6 lines per run. Quiet the VVC,
    -- keep test-level INFO and all alerts.
    GetAlertLogID(StreamTxRec, TxLogID) ;
    SetLogEnable(TxLogID, INFO, FALSE) ;
    RV.InitSeed(RV'instance_name) ;

    -- Send constrained-random frames until every coverage model reports
    -- 100% -- the objective "we are done" criterion for this test.
    CoverageLoop : while not (    IsCovered(CovLen)
                              and IsCovered(CovErr)
                              and IsCovered(CovGap)
                              and IsCovered(CovLenXErr)) loop

      if FrameCount >= MAX_FRAMES then
        Alert("Functional coverage did not close within " &
              to_string(MAX_FRAMES) & " frames") ;
        exit CoverageLoop ;
      end if ;

      -- Constrained-random frame length: weighted bin choice first, then
      -- uniform within the bin (RandomPkg DistInt + RandInt). Standard
      -- sizes keep the majority of the weight (fast to simulate, most
      -- corner-rich), but a third of all frames land in jumbo territory
      -- up to the exact 9018-byte maximum.
      LenBin := RV.DistInt((4, 13, 13, 11, 10, 9, 4, 14, 10, 7, 5)) ;
      case LenBin is
        when 0      => FrameLen := ETH_MIN_FRAME ;
        when 1      => FrameLen := RV.RandInt(  65,  127) ;
        when 2      => FrameLen := RV.RandInt( 128,  255) ;
        when 3      => FrameLen := RV.RandInt( 256,  511) ;
        when 4      => FrameLen := RV.RandInt( 512, 1023) ;
        when 5      => FrameLen := RV.RandInt(1024, 1517) ;
        when 6      => FrameLen := ETH_MAX_FRAME ;
        when 7      => FrameLen := RV.RandInt(1519, 4095) ;
        when 8      => FrameLen := RV.RandInt(4096, 8191) ;
        when 9      => FrameLen := RV.RandInt(8192, 9017) ;
        when others => FrameLen := ETH_MAX_JUMBO_FRAME ;
      end case ;

      -- 20% of frames get a corrupted FCS
      ErrInj := RV.DistInt((4, 1)) ;

      -- Inter-frame gap: back-to-back, short, medium, long
      GapBin := RV.DistInt((30, 25, 25, 20)) ;
      case GapBin is
        when 0      => Gap := 0 ;
        when 1      => Gap := RV.RandInt( 1,  4) ;
        when 2      => Gap := RV.RandInt( 5, 20) ;
        when others => Gap := RV.RandInt(21, 63) ;
      end case ;

      -- Assemble a real Ethernet frame:
      -- DA / SA: locally-administered unicast (first octet 0x02)
      PayloadLen := FrameLen - ETH_HEADER_LEN - ETH_FCS_LEN ;
      Frame(0) := x"02" ;
      Frame(6) := x"02" ;
      for i in 1 to 5 loop
        Frame(i)   := RV.RandSlv(8) ;
        Frame(6+i) := RV.RandSlv(8) ;
      end loop ;
      -- Type/Length field: an 802.3 length field is only defined up to
      -- 1500, so standard frames carry the payload length and jumbo
      -- payloads carry an EtherType instead (0x88B5, the IEEE 802 local
      -- experimental EtherType), exactly as real jumbo traffic would.
      if PayloadLen <= 1500 then
        Frame(12) := std_logic_vector(to_unsigned(PayloadLen, 16)(15 downto 8)) ;
        Frame(13) := std_logic_vector(to_unsigned(PayloadLen, 16)( 7 downto 0)) ;
      else
        Frame(12) := x"88" ;
        Frame(13) := x"B5" ;
      end if ;
      -- Random payload
      for i in 0 to PayloadLen-1 loop
        Frame(ETH_HEADER_LEN + i) := RV.RandSlv(8) ;
      end loop ;

      -- Genuine CRC-32 FCS, optionally corrupted (error injection)
      Fcs := CalcFcs(Frame(0 to FrameLen-ETH_FCS_LEN-1)) ;
      if ErrInj = 1 then
        CorruptIdx := RV.RandInt(0, ETH_FCS_LEN-1) ;
        Fcs(CorruptIdx) := Fcs(CorruptIdx) xor RV.RandSlv(1, 255, 8) ;
      end if ;
      for i in 0 to ETH_FCS_LEN-1 loop
        Frame(FrameLen-ETH_FCS_LEN+i) := Fcs(i) ;
      end loop ;

      -- Queue expectations (scoreboards), then send the burst
      Meta := (others => '0') ;
      Meta(13 downto 0) := std_logic_vector(to_unsigned(FrameLen, 14)) ;
      if ErrInj = 1 then
        Meta(15) := '1' ;
      end if ;
      Push(SB_Meta, Meta) ;
      for i in 0 to FrameLen-1 loop
        Push(SB_Data, Frame(i)) ;
        Push(TxBurstFifo, Frame(i)) ;
      end loop ;

      SendBurst(StreamTxRec, FrameLen) ;

      -- Record what this frame exercised
      ICover(CovLen, FrameLen) ;
      ICover(CovErr, ErrInj) ;
      ICover(CovGap, Gap) ;
      ICover(CovLenXErr, (FrameLen, ErrInj)) ;

      if Gap > 0 then
        WaitForClock(StreamTxRec, Gap) ;
      end if ;
      FrameCount := FrameCount + 1 ;
    end loop CoverageLoop ;

    Log("TransmitterProc: coverage closed after " & to_string(FrameCount) &
        " constrained-random frames", INFO) ;

    TxDone <= TRUE ;
    WaitForBarrier(TestDone) ;
    wait ;
  end process TransmitterProc ;

  ------------------------------------------------------------
  -- ReceiverProc
  --   Drain, check ordering/content via scoreboard, verify FCS status
  ------------------------------------------------------------
  ReceiverProc : process
    variable RV            : RandomPType ;
    variable RxCount       : integer := 0 ;
    variable Avail         : boolean ;
    variable Meta          : std_logic_vector(15 downto 0) ;
    variable ExpLen        : integer ;
    variable ErrExp        : std_logic ;
    variable RxFrame       : ByteArrayType(0 to ETH_MAX_JUMBO_FRAME-1) ;
    variable ExpFcs        : ByteArrayType(0 to ETH_FCS_LEN-1) ;
    variable FcsOk         : boolean ;
    variable FramesChecked : integer := 0 ;
    variable TotalBytes    : integer := 0 ;
    variable StallVal      : std_logic_vector(31 downto 0) ;
    variable RxLogID       : AlertLogIDType ;
  begin
    WaitForBarrier(InitDone) ;
    wait until nReset = '1' ;
    WaitForClock(StreamRxRec, 2) ;
    SetBurstMode(StreamRxRec, STREAM_BURST_BYTE_MODE) ;
    -- Quiet the receiver VVC's per-word INFO logging (see TransmitterProc)
    GetAlertLogID(StreamRxRec, RxLogID) ;
    SetLogEnable(RxLogID, INFO, FALSE) ;
    RV.InitSeed(RV'instance_name) ;

    -- Frame_Stats sanity check before traffic: magic register readable,
    -- exercised through the Axi4LiteManager VVC
    ReadCheck(ManagerRec, STATS_MAGIC, STATS_MAGIC_VALUE) ;
    Log("Frame_Stats MAGIC register verified via AXI4-Lite", INFO) ;

    ReceiveLoop : loop
      -- Periodically re-randomize READY backpressure to stress the DUT's
      -- flow control (VVC option, no signal wiggling in the test)
      if FramesChecked mod 8 = 0 then
        SetAxiStreamOptions(StreamRxRec, RECEIVE_READY_DELAY_CYCLES, RV.RandInt(0, 3)) ;
      end if ;

      TryGetBurst(StreamRxRec, RxCount, Avail) ;
      if Avail then
        Meta   := Pop(SB_Meta) ;
        ExpLen := to_integer(unsigned(Meta(13 downto 0))) ;
        ErrExp := Meta(15) ;

        AffirmIfEqual(RxCount, ExpLen, "Received frame length") ;

        -- Byte-for-byte in-order content check against the scoreboard
        for i in 0 to RxCount-1 loop
          RxFrame(i) := Pop(RxBurstFifo) ;
          Check(SB_Data, RxFrame(i)) ;
        end loop ;

        -- Independent FCS verification, cross-checked against injection
        ExpFcs := CalcFcs(RxFrame(0 to RxCount-ETH_FCS_LEN-1)) ;
        FcsOk  := TRUE ;
        for i in 0 to ETH_FCS_LEN-1 loop
          if RxFrame(RxCount-ETH_FCS_LEN+i) /= ExpFcs(i) then
            FcsOk := FALSE ;
          end if ;
        end loop ;
        if ErrExp = '1' then
          AffirmIf(not FcsOk, "FCS invalid as expected (error-injected frame " &
                   to_string(FramesChecked) & ")") ;
        else
          AffirmIf(FcsOk, "FCS valid (clean frame " &
                   to_string(FramesChecked) & ")") ;
        end if ;

        FramesChecked := FramesChecked + 1 ;
        TotalBytes    := TotalBytes + RxCount ;
      else
        exit ReceiveLoop when TxDone and IsEmpty(SB_Meta) ;
        WaitForClock(StreamRxRec, 10) ;
      end if ;
    end loop ReceiveLoop ;

    Log("ReceiverProc: checked " & to_string(FramesChecked) & " frames", INFO) ;

    -- Cross-check the hardware Frame_Stats counters against the testbench's
    -- own accounting: register observability must agree with stream truth.
    WaitForClock(ManagerRec, 4) ;

    -- Post-run register dump: fixed-format lines for after-the-fact review
    -- (grep FRAME_STATS_DUMP in the transcript)
    DumpStatsReg(ManagerRec, "MAGIC     ", STATS_MAGIC) ;
    DumpStatsReg(ManagerRec, "FRAMES_IN ", STATS_FRAMES_IN) ;
    DumpStatsReg(ManagerRec, "FRAMES_OUT", STATS_FRAMES_OUT) ;
    DumpStatsReg(ManagerRec, "BYTES_IN  ", STATS_BYTES_IN) ;
    DumpStatsReg(ManagerRec, "BYTES_OUT ", STATS_BYTES_OUT) ;
    DumpStatsReg(ManagerRec, "STALL_IN  ", STATS_STALL_IN) ;
    DumpStatsReg(ManagerRec, "STALL_OUT ", STATS_STALL_OUT) ;

    ReadCheck(ManagerRec, STATS_FRAMES_IN,
              std_logic_vector(to_unsigned(FramesChecked, 32))) ;
    ReadCheck(ManagerRec, STATS_FRAMES_OUT,
              std_logic_vector(to_unsigned(FramesChecked, 32))) ;
    ReadCheck(ManagerRec, STATS_BYTES_IN,
              std_logic_vector(to_unsigned(TotalBytes, 32))) ;
    ReadCheck(ManagerRec, STATS_BYTES_OUT,
              std_logic_vector(to_unsigned(TotalBytes, 32))) ;

    -- Randomized READY backpressure must have produced egress stalls
    Read(ManagerRec, STATS_STALL_OUT, StallVal) ;
    AffirmIf(unsigned(StallVal) > 0,
             "Egress stall counter nonzero (" & to_string(to_integer(unsigned(StallVal))) &
             " cycles) - backpressure was exercised") ;

    -- Counter-clear function: write CTRL.CLEAR, verify counters zeroed
    Write(ManagerRec, STATS_CTRL, x"00000001") ;
    ReadCheck(ManagerRec, STATS_FRAMES_IN,  x"00000000") ;
    ReadCheck(ManagerRec, STATS_BYTES_OUT,  x"00000000") ;
    Log("Frame_Stats counters verified and cleared via AXI4-Lite", INFO) ;

    WaitForBarrier(TestDone) ;
    wait ;
  end process ReceiverProc ;

end architecture FrameLoopback ;
