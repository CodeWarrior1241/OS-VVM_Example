--
--  File Name:         frame_stats.vhd
--  Design Unit Name:  frame_stats
--
--  Description:
--    AXI4-Lite frame statistics block for the Ethernet-loopback design,
--    built on open-logic's olo_axi_lite_slave (the AXI4-Lite protocol
--    engine; this file adds only the counters and the register file).
--
--    Two AXI4-Stream monitor taps observe the frame FIFO's ingress
--    (MON_IN, the ingress MAC m_axis_rxd -> FIFO S_AXIS link) and egress
--    (MON_OUT, the FIFO M_AXIS -> egress MAC s_axis_txd link). Purely
--    passive: only TVALID/TREADY/TKEEP/TLAST are sampled, nothing is
--    driven.
--
--    Register map (32-bit registers, byte addresses):
--      0x00  MAGIC       RO  0x46535431 ("FST1")
--      0x04  CTRL        WO  bit0: write 1 to clear all counters (reads 0)
--      0x08  FRAMES_IN   RO  TLAST beats accepted on MON_IN
--      0x0C  FRAMES_OUT  RO  TLAST beats accepted on MON_OUT
--      0x10  BYTES_IN    RO  Sum of set TKEEP bits accepted on MON_IN
--      0x14  BYTES_OUT   RO  Sum of set TKEEP bits accepted on MON_OUT
--      0x18  STALL_IN    RO  Cycles with TVALID and not TREADY on MON_IN
--      0x1C  STALL_OUT   RO  Cycles with TVALID and not TREADY on MON_OUT
--    Counters are free-running and wrap at 2**32.
--
--    Reset (Rst) is active-high synchronous, per open-logic convention;
--    in the block design it is driven by AXI_Reset/peripheral_reset.
--
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity frame_stats is
    generic (
        AxiAddrWidth_g : positive := 8
    );
    port (
        Clk               : in    std_logic;
        Rst               : in    std_logic;

        -- AXI4-Lite management interface (protocol handled by open-logic)
        S_AxiLite_ArAddr  : in    std_logic_vector(AxiAddrWidth_g - 1 downto 0);
        S_AxiLite_ArValid : in    std_logic;
        S_AxiLite_ArReady : out   std_logic;
        S_AxiLite_AwAddr  : in    std_logic_vector(AxiAddrWidth_g - 1 downto 0);
        S_AxiLite_AwValid : in    std_logic;
        S_AxiLite_AwReady : out   std_logic;
        S_AxiLite_WData   : in    std_logic_vector(31 downto 0);
        S_AxiLite_WStrb   : in    std_logic_vector(3 downto 0);
        S_AxiLite_WValid  : in    std_logic;
        S_AxiLite_WReady  : out   std_logic;
        S_AxiLite_BResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_BValid  : out   std_logic;
        S_AxiLite_BReady  : in    std_logic;
        S_AxiLite_RData   : out   std_logic_vector(31 downto 0);
        S_AxiLite_RResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_RValid  : out   std_logic;
        S_AxiLite_RReady  : in    std_logic;

        -- Passive AXI4-Stream monitor taps
        MonIn_TValid      : in    std_logic;
        MonIn_TReady      : in    std_logic;
        MonIn_TKeep       : in    std_logic_vector(3 downto 0);
        MonIn_TLast       : in    std_logic;

        MonOut_TValid     : in    std_logic;
        MonOut_TReady     : in    std_logic;
        MonOut_TKeep      : in    std_logic_vector(3 downto 0);
        MonOut_TLast      : in    std_logic
    );

end entity frame_stats;

architecture rtl of frame_stats is

    -- Vivado module-reference interface inference. NOTE: strict LRM says
    -- port attribute specifications belong in the entity declarative part,
    -- but Vivado's module-reference scan only honors them here in the
    -- architecture; Questa and xvhdl both accept this placement.
    attribute X_INTERFACE_INFO      : string;
    attribute X_INTERFACE_MODE      : string;
    attribute X_INTERFACE_PARAMETER : string;

    attribute X_INTERFACE_INFO of Clk : signal is
        "xilinx.com:signal:clock:1.0 Clk CLK";
    attribute X_INTERFACE_PARAMETER of Clk : signal is
        "ASSOCIATED_BUSIF S_AXI_STATS:MON_IN:MON_OUT, ASSOCIATED_RESET Rst";
    attribute X_INTERFACE_INFO of Rst : signal is
        "xilinx.com:signal:reset:1.0 Rst RST";
    attribute X_INTERFACE_PARAMETER of Rst : signal is
        "POLARITY ACTIVE_HIGH";

    attribute X_INTERFACE_INFO of S_AxiLite_ArAddr  : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS ARADDR";
    attribute X_INTERFACE_INFO of S_AxiLite_ArValid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS ARVALID";
    attribute X_INTERFACE_INFO of S_AxiLite_ArReady : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS ARREADY";
    attribute X_INTERFACE_INFO of S_AxiLite_AwAddr  : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS AWADDR";
    attribute X_INTERFACE_INFO of S_AxiLite_AwValid : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS AWVALID";
    attribute X_INTERFACE_INFO of S_AxiLite_AwReady : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS AWREADY";
    attribute X_INTERFACE_INFO of S_AxiLite_WData   : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS WDATA";
    attribute X_INTERFACE_INFO of S_AxiLite_WStrb   : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS WSTRB";
    attribute X_INTERFACE_INFO of S_AxiLite_WValid  : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS WVALID";
    attribute X_INTERFACE_INFO of S_AxiLite_WReady  : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS WREADY";
    attribute X_INTERFACE_INFO of S_AxiLite_BResp   : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS BRESP";
    attribute X_INTERFACE_INFO of S_AxiLite_BValid  : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS BVALID";
    attribute X_INTERFACE_INFO of S_AxiLite_BReady  : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS BREADY";
    attribute X_INTERFACE_INFO of S_AxiLite_RData   : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS RDATA";
    attribute X_INTERFACE_INFO of S_AxiLite_RResp   : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS RRESP";
    attribute X_INTERFACE_INFO of S_AxiLite_RValid  : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS RVALID";
    attribute X_INTERFACE_INFO of S_AxiLite_RReady  : signal is "xilinx.com:interface:aximm:1.0 S_AXI_STATS RREADY";
    attribute X_INTERFACE_PARAMETER of S_AxiLite_AwValid : signal is
        "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8";

    attribute X_INTERFACE_INFO of MonIn_TValid  : signal is "xilinx.com:interface:axis:1.0 MON_IN TVALID";
    attribute X_INTERFACE_INFO of MonIn_TReady  : signal is "xilinx.com:interface:axis:1.0 MON_IN TREADY";
    attribute X_INTERFACE_INFO of MonIn_TKeep   : signal is "xilinx.com:interface:axis:1.0 MON_IN TKEEP";
    attribute X_INTERFACE_INFO of MonIn_TLast   : signal is "xilinx.com:interface:axis:1.0 MON_IN TLAST";
    attribute X_INTERFACE_MODE of MonIn_TValid  : signal is "monitor";
    -- No TDATA port on the monitor taps; declare the bus width explicitly so
    -- BD validation does not flag a TDATA_NUM_BYTES mismatch with the tapped net
    attribute X_INTERFACE_PARAMETER of MonIn_TValid : signal is
        "TDATA_NUM_BYTES 4";

    attribute X_INTERFACE_INFO of MonOut_TValid : signal is "xilinx.com:interface:axis:1.0 MON_OUT TVALID";
    attribute X_INTERFACE_INFO of MonOut_TReady : signal is "xilinx.com:interface:axis:1.0 MON_OUT TREADY";
    attribute X_INTERFACE_INFO of MonOut_TKeep  : signal is "xilinx.com:interface:axis:1.0 MON_OUT TKEEP";
    attribute X_INTERFACE_INFO of MonOut_TLast  : signal is "xilinx.com:interface:axis:1.0 MON_OUT TLAST";
    attribute X_INTERFACE_MODE of MonOut_TValid : signal is "monitor";
    attribute X_INTERFACE_PARAMETER of MonOut_TValid : signal is
        "TDATA_NUM_BYTES 4";

    constant Magic_c : std_logic_vector(31 downto 0) := x"46535431";  -- "FST1"

    -- Register-bank interface to olo_axi_lite_slave
    signal Rb_Addr    : std_logic_vector(AxiAddrWidth_g - 1 downto 0);
    signal Rb_Wr      : std_logic;
    signal Rb_ByteEna : std_logic_vector(3 downto 0);
    signal Rb_WrData  : std_logic_vector(31 downto 0);
    signal Rb_Rd      : std_logic;
    signal Rb_RdData  : std_logic_vector(31 downto 0);
    signal Rb_RdValid : std_logic;

    -- Counters
    signal FramesIn, FramesOut : unsigned(31 downto 0);
    signal BytesIn, BytesOut   : unsigned(31 downto 0);
    signal StallIn, StallOut   : unsigned(31 downto 0);
    signal ClearCounters       : std_logic;

    function count_ones (Vec : std_logic_vector) return natural is
        variable Count_v : natural := 0;
    begin
        for i in Vec'range loop
            if Vec(i) = '1' then
                Count_v := Count_v + 1;
            end if;
        end loop;
        return Count_v;
    end function count_ones;

begin

    -- AXI4-Lite protocol engine from open-logic
    i_axi_slave : entity work.olo_axi_lite_slave
        generic map (
            AxiAddrWidth_g    => AxiAddrWidth_g,
            AxiDataWidth_g    => 32,
            ReadTimeoutClks_g => 16
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            S_AxiLite_ArAddr  => S_AxiLite_ArAddr,
            S_AxiLite_ArValid => S_AxiLite_ArValid,
            S_AxiLite_ArReady => S_AxiLite_ArReady,
            S_AxiLite_AwAddr  => S_AxiLite_AwAddr,
            S_AxiLite_AwValid => S_AxiLite_AwValid,
            S_AxiLite_AwReady => S_AxiLite_AwReady,
            S_AxiLite_WData   => S_AxiLite_WData,
            S_AxiLite_WStrb   => S_AxiLite_WStrb,
            S_AxiLite_WValid  => S_AxiLite_WValid,
            S_AxiLite_WReady  => S_AxiLite_WReady,
            S_AxiLite_BResp   => S_AxiLite_BResp,
            S_AxiLite_BValid  => S_AxiLite_BValid,
            S_AxiLite_BReady  => S_AxiLite_BReady,
            S_AxiLite_RData   => S_AxiLite_RData,
            S_AxiLite_RResp   => S_AxiLite_RResp,
            S_AxiLite_RValid  => S_AxiLite_RValid,
            S_AxiLite_RReady  => S_AxiLite_RReady,
            Rb_Addr           => Rb_Addr,
            Rb_Wr             => Rb_Wr,
            Rb_ByteEna        => Rb_ByteEna,
            Rb_WrData         => Rb_WrData,
            Rb_Rd             => Rb_Rd,
            Rb_RdData         => Rb_RdData,
            Rb_RdValid        => Rb_RdValid
        );

    -- Statistics counters
    p_counters : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Rst = '1' or ClearCounters = '1' then
                FramesIn  <= (others => '0');
                FramesOut <= (others => '0');
                BytesIn   <= (others => '0');
                BytesOut  <= (others => '0');
                StallIn   <= (others => '0');
                StallOut  <= (others => '0');
            else
                if MonIn_TValid = '1' and MonIn_TReady = '1' then
                    BytesIn <= BytesIn + count_ones(MonIn_TKeep);
                    if MonIn_TLast = '1' then
                        FramesIn <= FramesIn + 1;
                    end if;
                elsif MonIn_TValid = '1' then
                    StallIn <= StallIn + 1;
                end if;

                if MonOut_TValid = '1' and MonOut_TReady = '1' then
                    BytesOut <= BytesOut + count_ones(MonOut_TKeep);
                    if MonOut_TLast = '1' then
                        FramesOut <= FramesOut + 1;
                    end if;
                elsif MonOut_TValid = '1' then
                    StallOut <= StallOut + 1;
                end if;
            end if;
        end if;
    end process p_counters;

    -- Register bank (one register per 32-bit word address)
    p_regs : process (Clk) is
    begin
        if rising_edge(Clk) then
            ClearCounters <= '0';
            Rb_RdValid    <= '0';

            if Rb_Wr = '1' then
                case Rb_Addr(7 downto 2) is
                    when "000001" =>          -- 0x04 CTRL
                        if Rb_ByteEna(0) = '1' and Rb_WrData(0) = '1' then
                            ClearCounters <= '1';
                        end if;
                    when others => null;      -- other registers are read-only
                end case;
            end if;

            if Rb_Rd = '1' then
                Rb_RdValid <= '1';
                case Rb_Addr(7 downto 2) is
                    when "000000" => Rb_RdData <= Magic_c;                       -- 0x00
                    when "000001" => Rb_RdData <= (others => '0');               -- 0x04
                    when "000010" => Rb_RdData <= std_logic_vector(FramesIn);    -- 0x08
                    when "000011" => Rb_RdData <= std_logic_vector(FramesOut);   -- 0x0C
                    when "000100" => Rb_RdData <= std_logic_vector(BytesIn);     -- 0x10
                    when "000101" => Rb_RdData <= std_logic_vector(BytesOut);    -- 0x14
                    when "000110" => Rb_RdData <= std_logic_vector(StallIn);     -- 0x18
                    when "000111" => Rb_RdData <= std_logic_vector(StallOut);    -- 0x1C
                    when others =>
                        Rb_RdData  <= (others => '0');
                        Rb_RdValid <= '0';    -- unmapped: fail by read timeout
                end case;
            end if;

            if Rst = '1' then
                ClearCounters <= '0';
                Rb_RdValid    <= '0';
            end if;
        end if;
    end process p_regs;

end architecture rtl;
