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

end package body EthFramePkg ;
