--
--  File Name:         TestCtrl_e.vhd
--  Design Unit Name:  TestCtrl
--
--  Description:
--    Test sequencer entity for the OSVVM AXI4-Stream frame-loopback
--    testbench.  Follows the standard OSVVM TestCtrl pattern: the
--    entity carries the transaction-interface ports, each test case is
--    a separate architecture of this entity.
--
--    Adapted from OsvvmLibraries/AXI4/AxiStream/testbench/TestCtrl_e.vhd
--    (Apache-2.0, SynthWorks Design Inc.)
--
library ieee ;
  use ieee.std_logic_1164.all ;
  use ieee.numeric_std.all ;
  use ieee.numeric_std_unsigned.all ;

library OSVVM ;
  context OSVVM.OsvvmContext ;
  use osvvm.ScoreboardPkg_slv.all ;

library osvvm_AXI4 ;
  context osvvm_AXI4.AxiStreamContext ;

use work.EthFramePkg.all ;

entity TestCtrl is
  generic (
    ID_LEN       : integer ;
    DEST_LEN     : integer ;
    USER_LEN     : integer
  ) ;
  port (
      -- Global Signal Interface
      nReset             : In    std_logic ;

      -- Transaction Interfaces
      StreamTxRec        : InOut StreamRecType ;
      StreamRxRec        : InOut StreamRecType ;

      -- Frame_Stats AXI4-Lite management interface (Axi4LiteManager VVC)
      ManagerRec         : InOut AddressBusRecType
  ) ;

  -- Derive AXI interface properties from the StreamTxRec
  constant DATA_WIDTH : integer := StreamTxRec.DataToModel'length ;
  constant DATA_BYTES : integer := DATA_WIDTH/8 ;

  -- Simplifying access to Burst FIFOs using aliases
  alias TxBurstFifo : ScoreboardIdType is StreamTxRec.BurstFifo ;
  alias RxBurstFifo : ScoreboardIdType is StreamRxRec.BurstFifo ;
end entity TestCtrl ;
