-- Ostomachion — Opal Kelly XEM7310-A200 board-level top
-- Copyright (c) 2026 A P Nicholson , intothemist@gmail.com
-- SPDX-License-Identifier: Apache-2.0
--
-- Architecture:
--   xem7310_top (this file)
--   ├── IBUFDS              (LVDS→single-ended for 200 MHz onboard oscillator)
--   ├── ostomachion_bd_wrapper  (Vivado-generated; only Xilinx IP inside)
--   ├── neorv32_top             (RISC-V SoC, library neorv32, std_ulogic ports)
--   ├── xbus2axi4_bridge        (upstream NEORV32 XBUS→AXI4, std_ulogic XBUS side)
--   ├── IOBUF_SDA / IOBUF_SCL  (open-drain I2C pads, Xilinx primitive)
--   ├── okHost + okWireIn/Out + okBTPipeIn/Out  (FrontPanel USB interface)
--   └── fp_uart_bridge          (UART ↔ FrontPanel Pipes, async FIFOs)
--
-- Target: xc7a200tfbg484-1  (Opal Kelly XEM7310-A200)
-- Clock:  200 MHz LVDS oscillator → IBUFDS → MMCM (in BD) → 100 MHz system clock
--
-- Pin assignments:
--   On-board LEDs D1-D8 (Bank 14, LVCMOS15) — active-low, accent inverted in RTL
--   MC1 (Bank 34, LVCMOS33) for UART / SPI / I2C / Reset
--   MC2 (Bank 35, LVCMOS33) for the NEORV32 on-chip debugger JTAG
-- See xem7310.xdc for the complete pin map.
--
-- Type strategy:
--   Internal AXI and board signals use std_logic / std_logic_vector.
--   NEORV32 uses std_ulogic / std_ulogic_vector on all ports.
--   The upstream xbus2axi4_bridge accepts std_ulogic on the XBUS side natively,
--   so no type casting is needed for XBUS signals.  AXI side uses std_logic.

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library neorv32;
use neorv32.neorv32_package.all;

entity xem7310_top is
  port (
    -- 200 MHz LVDS oscillator (W11/W12, Bank 13)
    sys_clk_p    : in    std_logic;
    sys_clk_n    : in    std_logic;

    -- Active-low external reset (active-low, directly from MC1 connector)
    ext_rstn     : in    std_logic;

    -- UART (MC1, Bank 34)
    uart_txd_out : out   std_logic;
    uart_rxd_in  : in    std_logic;

    -- On-board LEDs D1–D8 (Bank 14, LVCMOS15, active-low hardware)
    led          : out   std_logic_vector(7 downto 0);

    -- SPI master (MC1, Bank 34)
    spi_clk_o    : out   std_logic;
    spi_dat_o    : out   std_logic;
    spi_dat_i    : in    std_logic;
    spi_csn_o    : out   std_logic;

    -- I2C / TWI open-drain (MC1, Bank 34)
    twi_sda      : inout std_logic;
    twi_scl      : inout std_logic;

    -- NEORV32 on-chip debugger JTAG (MC2, Bank 35)
    jtag_tck_i   : in    std_logic;
    jtag_tdi_i   : in    std_logic;
    jtag_tdo_o   : out   std_logic;
    jtag_tms_i   : in    std_logic;

    -- FrontPanel USB controller (directly wired to Cypress FX3 on XEM7310)
    okUH         : in    std_logic_vector(4 downto 0);
    okHU         : out   std_logic_vector(2 downto 0);
    okUHU        : inout std_logic_vector(31 downto 0);
    okAA         : inout std_logic
  );
end entity xem7310_top;

architecture rtl of xem7310_top is

  -- ── LVDS → single-ended clock ───────────────────────────────────────────
  signal sys_clk_se : std_logic;

  -- ── BD outputs ───────────────────────────────────────────────────────────
  signal clk         : std_logic;
  signal periph_rstn : std_logic_vector(0 downto 0);
  signal mext_irq    : std_logic;

  -- ── NEORV32 scalar outputs (std_ulogic → converted to std_logic) ─────────
  signal uart0_txd_u : std_ulogic;
  signal spi_clk_u   : std_ulogic;
  signal spi_mosi_u  : std_ulogic;
  signal jtag_tdo_u  : std_ulogic;

  -- ── NEORV32 vector outputs (std_ulogic_vector) ────────────────────────────
  signal gpio_out_u  : std_ulogic_vector(31 downto 0);
  signal spi_csn_u   : std_ulogic_vector(7 downto 0);

  -- ── NEORV32 XBUS outputs → upstream bridge (native std_ulogic) ───────────
  signal xbus_adr_u  : std_ulogic_vector(31 downto 0);
  signal xbus_wdat_u : std_ulogic_vector(31 downto 0);
  signal xbus_we_u   : std_ulogic;
  signal xbus_sel_u  : std_ulogic_vector(3 downto 0);
  signal xbus_stb_u  : std_ulogic;
  signal xbus_cti_u  : std_ulogic_vector(2 downto 0);
  signal xbus_tag_u  : std_ulogic_vector(2 downto 0);

  -- ── Bridge XBUS outputs → NEORV32 input (native std_ulogic) ────────────
  signal xbus_rdat_u : std_ulogic_vector(31 downto 0);
  signal xbus_ack_u  : std_ulogic;
  signal xbus_err_u  : std_ulogic;

  -- ── TWI split signals (std_ulogic ← NEORV32, std_logic ↔ IOBUF) ─────────
  signal twi_sda_out_u : std_ulogic;
  signal twi_scl_out_u : std_ulogic;
  signal twi_sda_in_l  : std_logic;
  signal twi_scl_in_l  : std_logic;

  -- ── FrontPanel components (from okLibrary.vhd in FrontPanel SDK) ─────────
  component okHost port (
    okUH  : in    std_logic_vector(4 downto 0);
    okHU  : out   std_logic_vector(2 downto 0);
    okUHU : inout std_logic_vector(31 downto 0);
    okAA  : inout std_logic;
    okClk : out   std_logic;
    okHE  : out   std_logic_vector(112 downto 0);
    okEH  : in    std_logic_vector(64 downto 0)
  );
  end component;

  component okWireIn port (
    okHE       : in  std_logic_vector(112 downto 0);
    ep_addr    : in  std_logic_vector(7 downto 0);
    ep_dataout : out std_logic_vector(31 downto 0)
  );
  end component;

  component okWireOut port (
    okHE      : in  std_logic_vector(112 downto 0);
    okEH      : out std_logic_vector(64 downto 0);
    ep_addr   : in  std_logic_vector(7 downto 0);
    ep_datain : in  std_logic_vector(31 downto 0)
  );
  end component;

  component okBTPipeIn port (
    okHE           : in  std_logic_vector(112 downto 0);
    okEH           : out std_logic_vector(64 downto 0);
    ep_addr        : in  std_logic_vector(7 downto 0);
    ep_write       : out std_logic;
    ep_blockstrobe : out std_logic;
    ep_dataout     : out std_logic_vector(31 downto 0);
    ep_ready       : in  std_logic
  );
  end component;

  component okBTPipeOut port (
    okHE           : in  std_logic_vector(112 downto 0);
    okEH           : out std_logic_vector(64 downto 0);
    ep_addr        : in  std_logic_vector(7 downto 0);
    ep_read        : out std_logic;
    ep_blockstrobe : out std_logic;
    ep_datain      : in  std_logic_vector(31 downto 0);
    ep_ready       : in  std_logic
  );
  end component;

  component okWireOR
    generic (N : natural);
    port (
      okEH  : out std_logic_vector(64 downto 0);
      okEHx : in  std_logic_vector(N*65-1 downto 0)
    );
  end component;

  -- ── FrontPanel signals ─────────────────────────────────────────────────
  constant FP_EP_COUNT : natural := 6;  -- WireOut×4 + PipeIn + PipeOut

  signal fp_clk       : std_logic;
  signal okHE         : std_logic_vector(112 downto 0);
  signal okEH         : std_logic_vector(64 downto 0);
  signal okEHx        : std_logic_vector(FP_EP_COUNT*65-1 downto 0);

  -- WireIn 0x00: bits [15:0] = baud divisor, bit [16] = UART source select
  signal wi00_data    : std_logic_vector(31 downto 0);
  signal fp_baud_div  : std_logic_vector(15 downto 0);
  signal uart_src_sel_fp : std_logic;
  signal uart_src_sync1 : std_logic := '0';
  signal uart_src_sync2 : std_logic := '0';

  -- WireOut 0x20: RX FIFO entry count
  signal wo20_data    : std_logic_vector(31 downto 0);
  signal rx_count     : std_logic_vector(10 downto 0);

  -- WireOut 0x21: FFT/DMA diagnostic probes
  --   [0] = fft_dbg_mm2s_tvalid   (DMA M_AXIS_MM2S TVALID, 1 = DMA sending)
  --   [1] = fft_dbg_s_data_tready (xfft s_axis_data TREADY, 1 = xfft accepting)
  --   [2] = periph_rstn(0)        (active-high reset-released indicator)
  signal wo21_data              : std_logic_vector(31 downto 0);
  signal fft_dbg_mm2s_tvalid    : std_logic;
  signal fft_dbg_s_data_tready  : std_logic;

  -- WireOut 0x22: xfft m_axis_data beat counter (instrumentation for Q1)
  --   [15:0]  = pre_first_tlast_beats  (beats of FIRST frame after aresetn)
  --   [31:16] = beats_in_last_frame    (beats of most recent frame)
  -- tlast_count is exposed on WireOut 0x23.
  signal wo22_data              : std_logic_vector(31 downto 0);
  signal wo23_data              : std_logic_vector(31 downto 0);
  signal fft_dbg_m_data_tvalid  : std_logic;
  signal fft_dbg_m_data_tready  : std_logic;
  signal fft_dbg_m_data_tlast   : std_logic;
  signal fft_pre_first_beats    : std_logic_vector(15 downto 0);
  signal fft_last_frame_beats   : std_logic_vector(15 downto 0);
  signal fft_tlast_count        : std_logic_vector(7 downto 0);

  -- BTPipeIn 0x80: host → NEORV32 UART data (block-throttled)
  signal pi80_data    : std_logic_vector(31 downto 0);
  signal pi80_write   : std_logic;
  signal pi80_ready   : std_logic;

  -- BTPipeOut 0xA0: NEORV32 UART data → host (block-throttled)
  signal poA0_data    : std_logic_vector(31 downto 0);
  signal poA0_read    : std_logic;
  signal poA0_ready   : std_logic;

  -- UART bridge outputs (system clock domain)
  signal bridge_uart_rx : std_logic;
  signal neorv32_uart_rxd : std_logic;

  -- ── AXI4-Lite bus (bridge master ↔ BD slave, all std_logic) ──────────────
  signal axi_awaddr  : std_logic_vector(31 downto 0);
  signal axi_awprot  : std_logic_vector(2 downto 0);
  signal axi_awvalid : std_logic;
  signal axi_awready : std_logic;
  signal axi_wdata   : std_logic_vector(31 downto 0);
  signal axi_wstrb   : std_logic_vector(3 downto 0);
  signal axi_wvalid  : std_logic;
  signal axi_wready  : std_logic;
  signal axi_bresp   : std_logic_vector(1 downto 0);
  signal axi_bvalid  : std_logic;
  signal axi_bready  : std_logic;
  signal axi_araddr  : std_logic_vector(31 downto 0);
  signal axi_arprot  : std_logic_vector(2 downto 0);
  signal axi_arvalid : std_logic;
  signal axi_arready : std_logic;
  signal axi_rdata   : std_logic_vector(31 downto 0);
  signal axi_rresp   : std_logic_vector(1 downto 0);
  signal axi_rvalid  : std_logic;
  signal axi_rready  : std_logic;

begin

  -- ── LVDS differential-to-single-ended clock buffer ──────────────────────
  -- External termination is provided on the XEM7310 PCB; DIFF_TERM=FALSE
  -- is set in the XDC constraints.
  clk_ibufds : IBUFDS
    port map (
      I  => sys_clk_p,
      IB => sys_clk_n,
      O  => sys_clk_se
    );

  -- ── Board outputs from NEORV32 std_ulogic ────────────────────────────────
  uart_txd_out <= std_logic(uart0_txd_u);  -- MC1 pin (dual-path with bridge)
  spi_clk_o    <= std_logic(spi_clk_u);
  spi_dat_o    <= std_logic(spi_mosi_u);
  jtag_tdo_o   <= std_logic(jtag_tdo_u);
  led          <= not std_logic_vector(gpio_out_u(7 downto 0));
  spi_csn_o    <= std_logic(spi_csn_u(0));

  -- ── UART RX mux: FrontPanel bridge (default) or MC1 pin ────────────────
  -- WireIn 0x00, bit 16: '0' = bridge (default), '1' = MC1 external adapter
  fp_baud_div      <= wi00_data(15 downto 0);
  uart_src_sel_fp  <= wi00_data(16);

  -- Double-register uart_src_sel from fp_clk into sys_clk (quasi-static CDC)
  process (clk)
  begin
    if rising_edge(clk) then
      uart_src_sync1 <= uart_src_sel_fp;
      uart_src_sync2 <= uart_src_sync1;
    end if;
  end process;

  neorv32_uart_rxd <= bridge_uart_rx when uart_src_sync2 = '0'
                      else uart_rxd_in;

  -- ── I2C / TWI open-drain pads ─────────────────────────────────────────────
  IOBUF_SDA : IOBUF
    port map (IO => twi_sda, I => '0', T => std_logic(twi_sda_out_u), O => twi_sda_in_l);

  IOBUF_SCL : IOBUF
    port map (IO => twi_scl, I => '0', T => std_logic(twi_scl_out_u), O => twi_scl_in_l);

  -- ── Block design (Xilinx IP subsystem) ───────────────────────────────────
  bd_i : entity work.ostomachion_bd_wrapper
    port map (
      sys_clk              => sys_clk_se,
      ck_rst               => ext_rstn,
      clk_o                => clk,
      periph_resetn_o      => periph_rstn,
      mext_irq_o           => mext_irq,
      s_axi_cpu_awaddr     => axi_awaddr,
      s_axi_cpu_awprot     => axi_awprot,
      s_axi_cpu_awvalid    => axi_awvalid,
      s_axi_cpu_awready    => axi_awready,
      s_axi_cpu_wdata      => axi_wdata,
      s_axi_cpu_wstrb      => axi_wstrb,
      s_axi_cpu_wvalid     => axi_wvalid,
      s_axi_cpu_wready     => axi_wready,
      s_axi_cpu_bresp      => axi_bresp,
      s_axi_cpu_bvalid     => axi_bvalid,
      s_axi_cpu_bready     => axi_bready,
      s_axi_cpu_araddr     => axi_araddr,
      s_axi_cpu_arprot     => axi_arprot,
      s_axi_cpu_arvalid    => axi_arvalid,
      s_axi_cpu_arready    => axi_arready,
      s_axi_cpu_rdata      => axi_rdata,
      s_axi_cpu_rresp      => axi_rresp,
      s_axi_cpu_rvalid         => axi_rvalid,
      s_axi_cpu_rready         => axi_rready,
      fft_dbg_mm2s_tvalid      => fft_dbg_mm2s_tvalid,
      fft_dbg_s_data_tready    => fft_dbg_s_data_tready,
      fft_dbg_m_data_tvalid    => fft_dbg_m_data_tvalid,
      fft_dbg_m_data_tready    => fft_dbg_m_data_tready,
      fft_dbg_m_data_tlast     => fft_dbg_m_data_tlast
    );

  -- ── FFT m_axis_data beat counter ─────────────────────────────────────────
  -- Passive observer that counts xfft output beats (tvalid && tready) and
  -- latches per-frame counts at tlast.  Exposes the first-frame-after-reset
  -- beat count via WireOut 0x22 — the empirical answer to whether xfft
  -- produces N or N+1 output beats for our 4096-pt natural-order
  -- pipelined-streaming configuration.  See ACCEL_DEBUG.md "Q1".
  beat_counter_i : entity work.fft_beat_counter
    port map (
      aclk                  => clk,
      aresetn               => periph_rstn(0),
      m_tvalid              => fft_dbg_m_data_tvalid,
      m_tready              => fft_dbg_m_data_tready,
      m_tlast               => fft_dbg_m_data_tlast,
      pre_first_tlast_beats => fft_pre_first_beats,
      beats_in_last_frame   => fft_last_frame_beats,
      tlast_count           => fft_tlast_count
    );

  -- ── XBUS → AXI4 bridge (upstream NEORV32, BURST_EN=false for AXI4-Lite BD)
  bridge_i : entity work.xbus2axi4_bridge
    generic map (
      BURST_EN  => false,
      BURST_LEN => 4
    )
    port map (
      clk           => clk,
      resetn        => periph_rstn(0),
      xbus_adr_i    => xbus_adr_u,
      xbus_dat_i    => xbus_wdat_u,
      xbus_cti_i    => xbus_cti_u,
      xbus_tag_i    => xbus_tag_u,
      xbus_we_i     => xbus_we_u,
      xbus_sel_i    => xbus_sel_u,
      xbus_stb_i    => xbus_stb_u,
      xbus_dat_o    => xbus_rdat_u,
      xbus_ack_o    => xbus_ack_u,
      xbus_err_o    => xbus_err_u,
      m_axi_awaddr  => axi_awaddr,
      m_axi_awlen   => open,
      m_axi_awsize  => open,
      m_axi_awburst => open,
      m_axi_awcache => open,
      m_axi_awprot  => axi_awprot,
      m_axi_awvalid => axi_awvalid,
      m_axi_awready => axi_awready,
      m_axi_wdata   => axi_wdata,
      m_axi_wstrb   => axi_wstrb,
      m_axi_wlast   => open,
      m_axi_wvalid  => axi_wvalid,
      m_axi_wready  => axi_wready,
      m_axi_araddr  => axi_araddr,
      m_axi_arlen   => open,
      m_axi_arsize  => open,
      m_axi_arburst => open,
      m_axi_arcache => open,
      m_axi_arprot  => axi_arprot,
      m_axi_arvalid => axi_arvalid,
      m_axi_arready => axi_arready,
      m_axi_rdata   => axi_rdata,
      m_axi_rresp   => axi_rresp,
      m_axi_rlast   => '1',
      m_axi_rvalid  => axi_rvalid,
      m_axi_rready  => axi_rready,
      m_axi_bresp   => axi_bresp,
      m_axi_bvalid  => axi_bvalid,
      m_axi_bready  => axi_bready
    );

  -- ── NEORV32 RISC-V SoC ───────────────────────────────────────────────────
  neorv32_i : entity neorv32.neorv32_top
    generic map (
      CLOCK_FREQUENCY   => 100_000_000,
      BOOT_MODE_SELECT  => 0,
      IMEM_EN           => true,
      IMEM_SIZE         => 128 * 1024,
      DMEM_EN           => true,
      DMEM_SIZE         => 64 * 1024,
      XBUS_EN           => true,
      XBUS_REGSTAGE_EN  => true,
      RISCV_ISA_C       => true,
      RISCV_ISA_M       => true,
      RISCV_ISA_Zicntr  => true,
      OCD_EN            => true,
      IO_CLINT_EN       => true,
      IO_UART0_EN       => true,
      IO_UART0_TX_FIFO  => 32,
      IO_SPI_EN         => true,
      IO_SPI_FIFO       => 32,
      IO_TWI_EN         => true,
      IO_TWI_FIFO       => 32,
      IO_GPIO_NUM       => 8,
      IO_WDT_EN         => true
    )
    port map (
      clk_i       => std_ulogic(clk),
      rstn_i      => std_ulogic(periph_rstn(0)),
      jtag_tck_i  => std_ulogic(jtag_tck_i),
      jtag_tdi_i  => std_ulogic(jtag_tdi_i),
      jtag_tdo_o  => jtag_tdo_u,
      jtag_tms_i  => std_ulogic(jtag_tms_i),
      xbus_adr_o  => xbus_adr_u,
      xbus_dat_o  => xbus_wdat_u,
      xbus_cti_o  => xbus_cti_u,
      xbus_tag_o  => xbus_tag_u,
      xbus_dat_i  => xbus_rdat_u,
      xbus_we_o   => xbus_we_u,
      xbus_sel_o  => xbus_sel_u,
      xbus_stb_o  => xbus_stb_u,
      xbus_cyc_o  => open,
      xbus_ack_i  => xbus_ack_u,
      xbus_err_i  => xbus_err_u,
      mext_irq_i  => std_ulogic(mext_irq),
      uart0_txd_o => uart0_txd_u,
      uart0_rxd_i => std_ulogic(neorv32_uart_rxd),
      uart0_rtsn_o => open,
      gpio_o      => gpio_out_u,
      spi_clk_o   => spi_clk_u,
      spi_dat_o   => spi_mosi_u,
      spi_dat_i   => std_ulogic(spi_dat_i),
      spi_csn_o   => spi_csn_u,
      twi_sda_o   => twi_sda_out_u,
      twi_sda_i   => std_ulogic(twi_sda_in_l),
      twi_scl_o   => twi_scl_out_u,
      twi_scl_i   => std_ulogic(twi_scl_in_l)
    );

  -- ── FrontPanel Host Interface ─────────────────────────────────────────────
  fp_host_i : okHost
    port map (
      okUH  => okUH,
      okHU  => okHU,
      okUHU => okUHU,
      okAA  => okAA,
      okClk => fp_clk,
      okHE  => okHE,
      okEH  => okEH
    );

  -- WireIn 0x00: [15:0] baud divisor, [16] UART source select
  wi00_i : okWireIn
    port map (
      okHE       => okHE,
      ep_addr    => x"00",
      ep_dataout => wi00_data
    );

  -- WireOut 0x20: [10:0] RX FIFO byte count
  wo20_data <= (31 downto 11 => '0') & rx_count;

  wo20_i : okWireOut
    port map (
      okHE      => okHE,
      okEH      => okEHx(0*65+64 downto 0*65),
      ep_addr   => x"20",
      ep_datain => wo20_data
    );

  -- WireOut 0x21: FFT/DMA diagnostic probes (sampled in FrontPanel clock domain)
  --   [0] = M_AXIS_MM2S TVALID  (1 = DMA is sending data to xfft)
  --   [1] = s_axis_data TREADY  (1 = xfft is accepting input data)
  --   [2] = periph_rstn(0)      (1 = peripherals out of reset)
  wo21_data <= (31 downto 3 => '0') & periph_rstn(0)
                                    & fft_dbg_s_data_tready
                                    & fft_dbg_mm2s_tvalid;

  wo21_i : okWireOut
    port map (
      okHE      => okHE,
      okEH      => okEHx(3*65+64 downto 3*65),
      ep_addr   => x"21",
      ep_datain => wo21_data
    );

  -- WireOut 0x22: xfft m_axis_data beat counts (instrumentation for Q1)
  --   [15:0]  = pre_first_tlast_beats   (first frame after aresetn)
  --   [31:16] = beats_in_last_frame     (most recent frame)
  wo22_data <= fft_last_frame_beats & fft_pre_first_beats;

  wo22_i : okWireOut
    port map (
      okHE      => okHE,
      okEH      => okEHx(4*65+64 downto 4*65),
      ep_addr   => x"22",
      ep_datain => wo22_data
    );

  -- WireOut 0x23: TLAST event count (wraps at 256)
  --   [7:0] = tlast_count
  wo23_data <= (31 downto 8 => '0') & fft_tlast_count;

  wo23_i : okWireOut
    port map (
      okHE      => okHE,
      okEH      => okEHx(5*65+64 downto 5*65),
      ep_addr   => x"23",
      ep_datain => wo23_data
    );

  -- BTPipeIn 0x80: host → NEORV32 UART data (block-throttled, hardware flow control)
  pi80_i : okBTPipeIn
    port map (
      okHE           => okHE,
      okEH           => okEHx(1*65+64 downto 1*65),
      ep_addr        => x"80",
      ep_write       => pi80_write,
      ep_blockstrobe => open,
      ep_dataout     => pi80_data,
      ep_ready       => pi80_ready
    );

  -- BTPipeOut 0xA0: NEORV32 UART data → host (block-throttled, hardware flow control)
  poA0_i : okBTPipeOut
    port map (
      okHE           => okHE,
      okEH           => okEHx(2*65+64 downto 2*65),
      ep_addr        => x"A0",
      ep_read        => poA0_read,
      ep_blockstrobe => open,
      ep_datain      => poA0_data,
      ep_ready       => poA0_ready
    );

  -- OR all endpoint-to-host buses
  wireor_i : okWireOR
    generic map (N => FP_EP_COUNT)
    port map (
      okEH  => okEH,
      okEHx => okEHx
    );

  -- ── FrontPanel UART Bridge ──────────────────────────────────────────────
  uart_bridge_i : entity work.fp_uart_bridge
    port map (
      sys_clk   => clk,
      sys_rstn  => periph_rstn(0),
      uart_tx_i => std_logic(uart0_txd_u),
      uart_rx_o => bridge_uart_rx,
      fp_clk    => fp_clk,
      po_data   => poA0_data,
      po_rd     => poA0_read,
      pi_data   => pi80_data,
      pi_wr     => pi80_write,
      rx_count  => rx_count,
      tx_ready  => pi80_ready,
      rx_ready  => poA0_ready,
      baud_div  => fp_baud_div
    );

end architecture rtl;
