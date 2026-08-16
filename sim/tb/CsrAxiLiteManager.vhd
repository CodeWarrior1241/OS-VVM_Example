--
--  File Name:         CsrAxiLiteManager.vhd
--  Design Unit Name:  CsrAxiLiteManager
--
--  Description:
--    Minimal project-authored AXI4-Lite manager verification component
--    built on OSVVM Model Independent Transactions (AddressBusRecType).
--    The test sequencer uses the standard OSVVM address-bus API
--    (Write / Read / ReadCheck / WaitForClock) exactly as it would with
--    the full osvvm_AXI4 Axi4LiteManager.
--
--    Why not the stock Axi4LiteManager?  Its functional bus interface is
--    a resolved record port (Axi4LiteRecType), and XSim 2026.1 corrupts
--    driver contributions on record subelements of an inout composite
--    port (readback arrives partially 'U').  This component exposes the
--    bus as DISCRETE ports instead -- the OSVVM transaction record
--    (proven to work on XSim by the AxiStream VVCs) stays, the record
--    bus goes.  Structure follows the OSVVM blocking-VVC pattern
--    (OsvvmLibraries/DpRam/src/DpRamController_Blocking.vhd).
--
library ieee ;
  use ieee.std_logic_1164.all ;
  use ieee.numeric_std.all ;

library osvvm ;
  context osvvm.OsvvmContext ;

library osvvm_common ;
  context osvvm_common.OsvvmCommonContext ;

entity CsrAxiLiteManager is
  generic (
    MODEL_ID_NAME : string := "CsrAxiLiteManager" ;
    tperiod_Clk   : time   := 8 ns ;
    tpd           : time   := 2 ns
  ) ;
  port (
    Clk      : in    std_logic ;
    nReset   : in    std_logic ;

    -- AXI4-Lite manager functional interface (discrete signals)
    AwAddr   : out   std_logic_vector ;
    AwValid  : out   std_logic ;
    AwReady  : in    std_logic ;
    WData    : out   std_logic_vector ;
    WStrb    : out   std_logic_vector ;
    WValid   : out   std_logic ;
    WReady   : in    std_logic ;
    BResp    : in    std_logic_vector(1 downto 0) ;
    BValid   : in    std_logic ;
    BReady   : out   std_logic ;
    ArAddr   : out   std_logic_vector ;
    ArValid  : out   std_logic ;
    ArReady  : in    std_logic ;
    RData    : in    std_logic_vector ;
    RResp    : in    std_logic_vector(1 downto 0) ;
    RValid   : in    std_logic ;
    RReady   : out   std_logic ;

    -- Testbench Transaction Interface
    TransRec : inout AddressBusRecType
  ) ;
end entity CsrAxiLiteManager ;

architecture Blocking of CsrAxiLiteManager is
  constant AXI_RESP_OKAY : std_logic_vector(1 downto 0) := "00" ;
  signal ModelID : AlertLogIDType ;
begin

  Initialize : process
  begin
    ModelID <= NewID(MODEL_ID_NAME) ;
    wait ;
  end process Initialize ;

  TransactionHandler : process
    alias Operation : AddressBusOperationType is TransRec.Operation ;
    variable Addr     : AwAddr'subtype ;
    variable Data     : WData'subtype ;
    variable RdData   : RData'subtype ;
    variable Expected : RData'subtype ;
    variable AwDone, WDone : boolean ;
  begin
    -- Initialize outputs
    AwAddr  <= (AwAddr'range => '0') ;
    AwValid <= '0' ;
    WData   <= (WData'range => '0') ;
    WStrb   <= (WStrb'range => '0') ;
    WValid  <= '0' ;
    BReady  <= '0' ;
    ArAddr  <= (ArAddr'range => '0') ;
    ArValid <= '0' ;
    RReady  <= '0' ;

    wait for 0 ns ;  -- Allow ModelID to become valid

    TransactionLoop : loop
      WaitForTransaction(
        Clk => Clk,
        Rdy => TransRec.Rdy,
        Ack => TransRec.Ack
      ) ;

      case Operation is
        -- Standard directive transactions
        when WAIT_FOR_TRANSACTION =>
          wait for 0 ns ;

        when WAIT_FOR_CLOCK =>
          WaitForClock(Clk, TransRec.IntToModel) ;

        when GET_ALERTLOG_ID =>
          TransRec.IntFromModel <= integer(ModelID) ;

        -- Model transactions
        when WRITE_OP =>
          Addr := SafeResize(ModelID, TransRec.Address, Addr'length) ;
          Data := SafeResize(ModelID, TransRec.DataToModel, Data'length) ;
          -- AW and W issued together; each channel completes independently
          AwAddr  <= Addr after tpd ;
          AwValid <= '1' after tpd ;
          WData   <= Data after tpd ;
          WStrb   <= (WStrb'range => '1') after tpd ;
          WValid  <= '1' after tpd ;
          AwDone := FALSE ;
          WDone  := FALSE ;
          while not (AwDone and WDone) loop
            wait until rising_edge(Clk) ;
            if not AwDone and AwReady = '1' then
              AwValid <= '0' after tpd ;
              AwDone  := TRUE ;
            end if ;
            if not WDone and WReady = '1' then
              WValid <= '0' after tpd ;
              WDone  := TRUE ;
            end if ;
          end loop ;
          -- Write response
          BReady <= '1' after tpd ;
          loop
            wait until rising_edge(Clk) ;
            exit when BValid = '1' ;
          end loop ;
          BReady <= '0' after tpd ;
          AffirmIfEqual(ModelID, BResp, AXI_RESP_OKAY,
                        "BRESP, Write Address: " & to_hxstring(Addr)) ;
          Log(ModelID,
              "Write Address: " & to_hxstring(Addr) &
              "  Data: " & to_hxstring(Data),
              INFO, TransRec.StatusMsgOn) ;

        when READ_OP | READ_CHECK =>
          Addr := SafeResize(ModelID, TransRec.Address, Addr'length) ;
          ArAddr  <= Addr after tpd ;
          ArValid <= '1' after tpd ;
          loop
            wait until rising_edge(Clk) ;
            exit when ArReady = '1' ;
          end loop ;
          ArValid <= '0' after tpd ;
          RReady  <= '1' after tpd ;
          loop
            wait until rising_edge(Clk) ;
            exit when RValid = '1' ;
          end loop ;
          RdData := RData ;
          RReady <= '0' after tpd ;
          AffirmIfEqual(ModelID, RResp, AXI_RESP_OKAY,
                        "RRESP, Read Address: " & to_hxstring(Addr)) ;
          TransRec.DataFromModel <=
              SafeResize(ModelID, RdData, TransRec.DataFromModel'length) ;
          if Operation = READ_CHECK then
            Expected := SafeResize(ModelID, TransRec.DataToModel, Expected'length) ;
            AffirmIfEqual(ModelID, RdData, Expected,
                          "Read Address: " & to_hxstring(Addr) & "  Data") ;
          else
            Log(ModelID,
                "Read Address: " & to_hxstring(Addr) &
                "  Data: " & to_hxstring(RdData),
                INFO, TransRec.StatusMsgOn) ;
          end if ;

        when others =>
          Alert(ModelID, "CsrAxiLiteManager: unimplemented transaction", FAILURE) ;
      end case ;
    end loop TransactionLoop ;
  end process TransactionHandler ;

end architecture Blocking ;
