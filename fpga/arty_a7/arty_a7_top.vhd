-- Ostomachion — Arty A7 board-level top
-- Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
--
-- Instantiates neorv32_top directly with FPGA-appropriate generics.
-- The simulation wrapper (rtl/neorv32_wrapper.vhd) is NOT used here;
-- both files share the same NEORV32 RTL core but carry different generics
-- and physical I/O primitives.
--
-- Physical pinout (all Arty A7-35T):
--   sys_clk      E3   – 100 MHz LVCMOS33 oscillator
--   ck_rst       C2   – active-low pushbutton (BTN RESET)
--   uart_txd_out D10  – USB-UART TX (FTDI FT2232HQ)
--   uart_rxd_in  A9   – USB-UART RX
--   led[0]       H5   – LD0 (green)
--   led[1]       J5   – LD1 (green)
--   led[2]       T9   – LD2 (green, shared with RGB)
--   led[3]       T10  – LD3 (green, shared with RGB)
--   spi_clk_o    G13  – Pmod JA pin 1 (SCK)
--   spi_dat_o    B11  – Pmod JA pin 2 (MOSI)
--   spi_dat_i    A11  – Pmod JA pin 3 (MISO)
--   spi_csn_o    D12  – Pmod JA pin 4 (CS0)
--   twi_sda      E15  – Pmod JB pin 1 (SDA, open-drain via IOBUF)
--   twi_scl      E16  – Pmod JB pin 2 (SCL, open-drain via IOBUF)
--   jtag_tck_i   K17  – Pmod JC pin 1
--   jtag_tdi_i   M18  – Pmod JC pin 2
--   jtag_tdo_o   N17  – Pmod JC pin 3
--   jtag_tms_i   P18  – Pmod JC pin 4

library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.neorv32_package.all;

-- Xilinx unisim library for BUFG and IOBUF primitives
library unisim;
use unisim.vcomponents.all;

entity arty_a7_top is
  port (
    -- System clock and reset
    sys_clk      : in    std_logic;
    ck_rst       : in    std_logic;                     -- active-low pushbutton

    -- USB-UART (via onboard FTDI FT2232HQ)
    uart_txd_out : out   std_logic;
    uart_rxd_in  : in    std_logic;

    -- GPIO → on-board LEDs LD0..LD3
    led          : out   std_logic_vector(3 downto 0);

    -- SPI master (Pmod JA)
    spi_clk_o    : out   std_logic;
    spi_dat_o    : out   std_logic;
    spi_dat_i    : in    std_logic;
    spi_csn_o    : out   std_logic;                     -- CS0 only exposed

    -- I2C / TWI (Pmod JB) – bidirectional open-drain
    twi_sda      : inout std_logic;
    twi_scl      : inout std_logic;

    -- JTAG on-chip debugger (Pmod JC)
    jtag_tck_i   : in    std_logic;
    jtag_tdi_i   : in    std_logic;
    jtag_tdo_o   : out   std_logic;
    jtag_tms_i   : in    std_logic
  );
end entity arty_a7_top;

architecture rtl of arty_a7_top is

  -- Buffered clock
  signal clk_buf      : std_ulogic;

  -- Two-stage reset synchroniser: synchronises the async button to the clock
  -- and generates an active-low synchronous reset.
  signal rst_meta     : std_ulogic := '0';
  signal rstn_sync    : std_ulogic := '0';

  -- Watchdog reset output (unused on this board — tie off)
  signal rstn_wdt     : std_ulogic;

  -- Internal std_ulogic signals for neorv32_top ports
  signal gpio_out     : std_ulogic_vector(31 downto 0);
  signal uart_tx      : std_ulogic;

  signal spi_clk_int  : std_ulogic;
  signal spi_dat_out  : std_ulogic;
  signal spi_csn_int  : std_ulogic_vector(7 downto 0);

  -- TWI open-drain signals
  -- neorv32_top drives twi_xxx_o: '0' = assert low, '1' = release (tristate)
  signal twi_sda_out  : std_ulogic;   -- from core: '0' = drive low
  signal twi_sda_in   : std_ulogic;   -- to core: current SDA value
  signal twi_scl_out  : std_ulogic;
  signal twi_scl_in   : std_ulogic;

  signal jtag_tdo_int : std_ulogic;

begin

  -- Global clock buffer
  BUFG_inst : BUFG
    port map (I => sys_clk, O => clk_buf);

  -- Two-stage synchroniser for asynchronous active-low reset button.
  -- After de-assertion of the button, rstn_sync goes high after two
  -- rising clock edges, preventing metastability from propagating.
  reset_sync : process(clk_buf, ck_rst)
  begin
    if ck_rst = '0' then
      rst_meta  <= '0';
      rstn_sync <= '0';
    elsif rising_edge(clk_buf) then
      rst_meta  <= '1';
      rstn_sync <= rst_meta;
    end if;
  end process;

  -- IOBUF for SDA (open-drain):
  --   I  = '0'        (always drive the pad to 0 when enabled)
  --   T  = twi_sda_out ('0' = drive low, '1' = tristate / release)
  --   O  = twi_sda_in  (current pad voltage, read by the core)
  IOBUF_SDA : IOBUF
    port map (
      IO => twi_sda,
      I  => '0',
      T  => std_logic(twi_sda_out),
      O  => twi_sda_in
    );

  -- IOBUF for SCL (open-drain, same convention)
  IOBUF_SCL : IOBUF
    port map (
      IO => twi_scl,
      I  => '0',
      T  => std_logic(twi_scl_out),
      O  => twi_scl_in
    );

  -- Drive board outputs
  uart_txd_out  <= std_logic(uart_tx);
  led           <= std_logic_vector(gpio_out(3 downto 0));
  spi_clk_o     <= std_logic(spi_clk_int);
  spi_dat_o     <= std_logic(spi_dat_out);
  spi_csn_o     <= std_logic(spi_csn_int(0));
  jtag_tdo_o    <= std_logic(jtag_tdo_int);

  -- NEORV32 processor core
  --
  -- Key differences from simulation wrapper (rtl/neorv32_wrapper.vhd):
  --   BOOT_MODE_SELECT = 0  : BROM bootloader — firmware uploaded over UART
  --   OCD_EN           = true: JTAG on-chip debugger exposed on Pmod JC
  --   IO_SPI_FIFO      = 32 : larger FIFO reduces interrupt frequency
  --   IO_TWI_FIFO      = 32 : same
  --   IO_UART0_TX_FIFO = 32 : prevents TX stalls at 115200 baud
  --   IO_WDT_EN        = true: hardware watchdog for production use
  neorv32_inst : entity neorv32.neorv32_top
    generic map (
      CLOCK_FREQUENCY   => 100_000_000,
      BOOT_MODE_SELECT  => 0,           -- internal bootloader (UART upload)
      RISCV_ISA_C       => true,
      RISCV_ISA_M       => true,
      RISCV_ISA_Zicntr  => true,
      -- On-chip debugger
      OCD_EN            => true,
      -- Memory
      IMEM_EN           => true,
      IMEM_SIZE         => 65536,
      DMEM_EN           => true,
      DMEM_SIZE         => 65536,
      -- Peripherals
      IO_CLINT_EN       => true,
      IO_GPIO_NUM       => 4,
      IO_UART0_EN       => true,
      IO_UART0_RX_FIFO  => 32,
      IO_UART0_TX_FIFO  => 32,
      IO_SPI_EN         => true,
      IO_SPI_FIFO       => 32,
      IO_TWI_EN         => true,
      IO_TWI_FIFO       => 32,
      IO_WDT_EN         => true
    )
    port map (
      clk_i        => std_ulogic(clk_buf),
      rstn_i       => rstn_sync,
      rstn_wdt_o   => rstn_wdt,

      -- GPIO (lower 4 bits → LEDs)
      gpio_o       => gpio_out,

      -- UART
      uart0_txd_o  => uart_tx,
      uart0_rxd_i  => std_ulogic(uart_rxd_in),

      -- SPI
      spi_clk_o    => spi_clk_int,
      spi_dat_o    => spi_dat_out,
      spi_dat_i    => std_ulogic(spi_dat_i),
      spi_csn_o    => spi_csn_int,

      -- TWI
      twi_sda_o    => twi_sda_out,
      twi_sda_i    => std_ulogic(twi_sda_in),
      twi_scl_o    => twi_scl_out,
      twi_scl_i    => std_ulogic(twi_scl_in),

      -- JTAG (OCD)
      jtag_tck_i   => std_ulogic(jtag_tck_i),
      jtag_tdi_i   => std_ulogic(jtag_tdi_i),
      jtag_tdo_o   => jtag_tdo_int,
      jtag_tms_i   => std_ulogic(jtag_tms_i)
    );

end architecture rtl;
