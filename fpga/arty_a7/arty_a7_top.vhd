-- Ostomachion — Arty A7-100T board-level top
-- Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
--
-- Architecture:
--   arty_a7_top (this file)
--   ├── ostomachion_bd_wrapper  (Vivado-generated; only Xilinx IP inside)
--   ├── neorv32_top             (RISC-V SoC, library neorv32, std_ulogic ports)
--   ├── xbus2axi4_bridge        (upstream NEORV32 XBUS→AXI4, std_ulogic XBUS side)
--   └── IOBUF_SDA / IOBUF_SCL  (open-drain I2C pads, Xilinx primitive)
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

entity arty_a7_top is
  port (
    sys_clk      : in    std_logic;
    ck_rst       : in    std_logic;

    uart_txd_out : out   std_logic;
    uart_rxd_in  : in    std_logic;

    led          : out   std_logic_vector(3 downto 0);

    spi_clk_o    : out   std_logic;
    spi_dat_o    : out   std_logic;
    spi_dat_i    : in    std_logic;
    spi_csn_o    : out   std_logic;

    twi_sda      : inout std_logic;
    twi_scl      : inout std_logic;

    jtag_tck_i   : in    std_logic;
    jtag_tdi_i   : in    std_logic;
    jtag_tdo_o   : out   std_logic;
    jtag_tms_i   : in    std_logic
  );
end entity arty_a7_top;

architecture rtl of arty_a7_top is

  -- ── BD outputs ───────────────────────────────────────────────────────────
  -- clk_o is STD_LOGIC (scalar clock from MMCM)
  -- periph_resetn_o is STD_LOGIC_VECTOR(0 to 0) — proc_sys_reset bus output
  -- mext_irq_o is STD_LOGIC — single IRQ from AXI INTC (channel 0=MM2S, 1=S2MM, 2=xfft ovflo)
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

  -- ── Board outputs from NEORV32 std_ulogic ────────────────────────────────
  uart_txd_out <= std_logic(uart0_txd_u);
  spi_clk_o    <= std_logic(spi_clk_u);
  spi_dat_o    <= std_logic(spi_mosi_u);
  jtag_tdo_o   <= std_logic(jtag_tdo_u);
  led          <= std_logic_vector(gpio_out_u(3 downto 0));
  spi_csn_o    <= std_logic(spi_csn_u(0));

  -- ── I2C / TWI open-drain pads ─────────────────────────────────────────────
  IOBUF_SDA : IOBUF
    port map (IO => twi_sda, I => '0', T => std_logic(twi_sda_out_u), O => twi_sda_in_l);

  IOBUF_SCL : IOBUF
    port map (IO => twi_scl, I => '0', T => std_logic(twi_scl_out_u), O => twi_scl_in_l);

  -- ── Block design (Xilinx IP subsystem) ───────────────────────────────────
  bd_i : entity work.ostomachion_bd_wrapper
    port map (
      sys_clk              => sys_clk,
      ck_rst               => ck_rst,
      clk_o                => clk,
      periph_resetn_o      => periph_rstn,   -- STD_LOGIC_VECTOR(0 to 0)
      mext_irq_o           => mext_irq,     -- STD_LOGIC — AXI INTC combined IRQ
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
      s_axi_cpu_rvalid     => axi_rvalid,
      s_axi_cpu_rready     => axi_rready
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
      -- XBUS (native std_ulogic — no type casting needed)
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
      -- AXI4 write address channel (extra AXI4 signals left open; BD is AXI4-Lite)
      m_axi_awaddr  => axi_awaddr,
      m_axi_awlen   => open,
      m_axi_awsize  => open,
      m_axi_awburst => open,
      m_axi_awcache => open,
      m_axi_awprot  => axi_awprot,
      m_axi_awvalid => axi_awvalid,
      m_axi_awready => axi_awready,
      -- AXI4 write data channel
      m_axi_wdata   => axi_wdata,
      m_axi_wstrb   => axi_wstrb,
      m_axi_wlast   => open,
      m_axi_wvalid  => axi_wvalid,
      m_axi_wready  => axi_wready,
      -- AXI4 read address channel
      m_axi_araddr  => axi_araddr,
      m_axi_arlen   => open,
      m_axi_arsize  => open,
      m_axi_arburst => open,
      m_axi_arcache => open,
      m_axi_arprot  => axi_arprot,
      m_axi_arvalid => axi_arvalid,
      m_axi_arready => axi_arready,
      -- AXI4 read data channel
      m_axi_rdata   => axi_rdata,
      m_axi_rresp   => axi_rresp,
      m_axi_rlast   => '1',
      m_axi_rvalid  => axi_rvalid,
      m_axi_rready  => axi_rready,
      -- AXI4 write response channel
      m_axi_bresp   => axi_bresp,
      m_axi_bvalid  => axi_bvalid,
      m_axi_bready  => axi_bready
    );

  -- ── NEORV32 RISC-V SoC ───────────────────────────────────────────────────
  neorv32_i : entity neorv32.neorv32_top
    generic map (
      CLOCK_FREQUENCY   => 100_000_000,
      BOOT_MODE_SELECT  => 0,          -- BROM bootloader (firmware via UART; or pre-flash BOOT_MODE_SELECT=1)
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
      IO_WDT_EN         => true        -- watchdog: feed via Zephyr wdt_feed() / CONFIG_WDT_NEORV32
    )
    port map (
      clk_i       => std_ulogic(clk),
      rstn_i      => std_ulogic(periph_rstn(0)),  -- extract scalar from 1-bit vector
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
      mext_irq_i  => std_ulogic(mext_irq),  -- single IRQ from AXI INTC
      uart0_txd_o => uart0_txd_u,
      uart0_rxd_i => std_ulogic(uart_rxd_in),
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

end architecture rtl;
