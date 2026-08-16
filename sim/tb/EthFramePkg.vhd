--
--  File Name:         EthFramePkg.vhd
--  Design Unit Name:  EthFramePkg
--
--  Description:
--    Ethernet frame helpers for the OSVVM AXI4-Stream frame-loopback
--    testbench: byte-array type, IEEE 802.3 CRC-32 (FCS) computation,
--    and frame geometry constants.
--
--    The CRC implementation is the standard reflected (LSB-first)
--    algorithm with polynomial 0xEDB88320 (the bit-reverse of the
--    802.3 polynomial 0x04C11DB7), initial value 0xFFFFFFFF and final
--    complement.  The four FCS bytes are returned in wire order
--    (least-significant CRC byte first), i.e. exactly the bytes that
--    follow the payload on an Ethernet link.
--
library ieee ;
  use ieee.std_logic_1164.all ;
  use ieee.numeric_std.all ;

package EthFramePkg is

  -- Frame geometry (all lengths in bytes, FCS included)
  constant ETH_HEADER_LEN : integer := 14 ;    -- DA(6) + SA(6) + Type/Len(2)
  constant ETH_FCS_LEN    : integer := 4 ;
  constant ETH_MIN_FRAME  : integer := 64 ;
  constant ETH_MAX_FRAME  : integer := 1518 ;  -- untagged 802.3 standard maximum
  -- Jumbo frames: 9000-byte payload + header + FCS. Everything above
  -- ETH_MAX_FRAME requires the MAC jumbo enable (TEMAC JUM bits) and
  -- 16k TX/RX frame buffers -- see build_all.tcl.
  constant ETH_MAX_JUMBO_FRAME : integer := 9018 ;

  type ByteArrayType is array (natural range <>) of std_logic_vector(7 downto 0) ;

  function CrcNextByte (
    Crc  : std_logic_vector(31 downto 0) ;
    Data : std_logic_vector(7 downto 0)
  ) return std_logic_vector ;

  -- CRC-32 over Frame, returned as the 4 FCS bytes in wire order
  function CalcFcs ( Frame : ByteArrayType ) return ByteArrayType ;

  ------------------------------------------------------------
  -- PCAP capture of generated frames (nanosecond libpcap format,
  -- LINKTYPE_ETHERNET; frames include the FCS so Wireshark can be told to
  -- validate it and flag the error-injected ones). Written with plain
  -- VHDL binary file I/O -- works on Questa and XSim alike.
  ------------------------------------------------------------
  type ByteFileType is file of character ;

  -- 24-byte global header; call once right after file_open (write_mode
  -- truncates, so every run produces a fresh capture)
  procedure PcapWriteGlobalHeader ( file F : ByteFileType ) ;

  -- One packet record stamped with the simulation time
  procedure PcapWriteFrame (
    file     F       : ByteFileType ;
    constant Frame   : in ByteArrayType ;
    constant TimeNow : in time
  ) ;

end package EthFramePkg ;

package body EthFramePkg is

  function CrcNextByte (
    Crc  : std_logic_vector(31 downto 0) ;
    Data : std_logic_vector(7 downto 0)
  ) return std_logic_vector is
    constant POLY : unsigned(31 downto 0) := x"EDB88320" ;
    variable C    : unsigned(31 downto 0) ;
  begin
    C := unsigned(Crc) xor resize(unsigned(Data), 32) ;
    for i in 0 to 7 loop
      if C(0) = '1' then
        C := shift_right(C, 1) xor POLY ;
      else
        C := shift_right(C, 1) ;
      end if ;
    end loop ;
    return std_logic_vector(C) ;
  end function CrcNextByte ;

  function CalcFcs ( Frame : ByteArrayType ) return ByteArrayType is
    variable Crc : std_logic_vector(31 downto 0) := (others => '1') ;
    variable Fcs : ByteArrayType(0 to ETH_FCS_LEN-1) ;
  begin
    for i in Frame'range loop
      Crc := CrcNextByte(Crc, Frame(i)) ;
    end loop ;
    Crc := not Crc ;
    Fcs(0) := Crc( 7 downto  0) ;
    Fcs(1) := Crc(15 downto  8) ;
    Fcs(2) := Crc(23 downto 16) ;
    Fcs(3) := Crc(31 downto 24) ;
    return Fcs ;
  end function CalcFcs ;

  -- 32-bit little-endian write (value must be < 2**31; the one constant
  -- that is not -- the nanosecond-pcap magic -- is written byte by byte)
  procedure PcapWriteU32 (
    file     F : ByteFileType ;
    constant V : in integer
  ) is
    variable U : unsigned(31 downto 0) ;
  begin
    U := to_unsigned(V, 32) ;
    write(F, character'val(to_integer(U( 7 downto  0)))) ;
    write(F, character'val(to_integer(U(15 downto  8)))) ;
    write(F, character'val(to_integer(U(23 downto 16)))) ;
    write(F, character'val(to_integer(U(31 downto 24)))) ;
  end procedure PcapWriteU32 ;

  procedure PcapWriteGlobalHeader ( file F : ByteFileType ) is
  begin
    -- magic 0xA1B23C4D (nanosecond pcap), little-endian
    write(F, character'val(16#4D#)) ;
    write(F, character'val(16#3C#)) ;
    write(F, character'val(16#B2#)) ;
    write(F, character'val(16#A1#)) ;
    PcapWriteU32(F, 16#00040002#) ;  -- version 2.4 (major, minor as u16 LE)
    PcapWriteU32(F, 0) ;             -- thiszone
    PcapWriteU32(F, 0) ;             -- sigfigs
    PcapWriteU32(F, 65535) ;         -- snaplen
    PcapWriteU32(F, 1) ;             -- network = LINKTYPE_ETHERNET
  end procedure PcapWriteGlobalHeader ;

  procedure PcapWriteFrame (
    file     F       : ByteFileType ;
    constant Frame   : in ByteArrayType ;
    constant TimeNow : in time
  ) is
    -- 32-bit integer holds ~2.1 s worth of nanoseconds; simulations here
    -- are milliseconds long
    variable TotalNs : integer ;
  begin
    TotalNs := TimeNow / 1 ns ;
    PcapWriteU32(F, TotalNs / 1_000_000_000) ;    -- ts_sec
    PcapWriteU32(F, TotalNs rem 1_000_000_000) ;  -- ts_nsec
    PcapWriteU32(F, Frame'length) ;               -- incl_len
    PcapWriteU32(F, Frame'length) ;               -- orig_len
    for i in Frame'range loop
      write(F, character'val(to_integer(unsigned(Frame(i))))) ;
    end loop ;
  end procedure PcapWriteFrame ;

end package body EthFramePkg ;
