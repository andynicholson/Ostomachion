-- FrontPanel UART Bridge
-- Copyright (c) 2026 A P Nicholson , intothemist@gmail.com
-- SPDX-License-Identifier: Apache-2.0
--
-- Bridges the NEORV32 UART0 serial interface to FrontPanel Pipe endpoints
-- so that the host PC can access the bootloader and firmware console over
-- the XEM7310's USB-C connection without needing the MC1 expansion header.
--
-- Data path:
--   NEORV32 uart0_txd_o → UART RX deserializer → async FIFO → PipeOut (host)
--   PipeIn (host) → async FIFO → UART TX serializer → NEORV32 uart0_rxd_i
--
-- Clock domains:
--   sys_clk  (~100 MHz) — UART serializers, NEORV32 side of FIFOs
--   fp_clk   (~100.8 MHz) — FrontPanel Pipe side of FIFOs
--
-- The baud divisor is provided from the FrontPanel clock domain (WireIn)
-- and double-registered into sys_clk.  Set it before starting communication.
-- Formula: baud_div = round(sys_clk_freq / baud_rate) - 1
--   19200 baud  → 5207  (0x1457)
--   115200 baud →  867  (0x0363)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity fp_uart_bridge is
  port (
    -- System clock domain (100 MHz)
    sys_clk    : in  std_logic;
    sys_rstn   : in  std_logic;

    -- UART serial interface (system clock domain)
    uart_tx_i  : in  std_logic;   -- from NEORV32 uart0_txd_o
    uart_rx_o  : out std_logic;   -- to NEORV32 uart0_rxd_i

    -- FrontPanel clock domain (~100.8 MHz from okHost)
    fp_clk     : in  std_logic;

    -- PipeOut read port (NEORV32 TX → host, fp_clk domain)
    -- Standard read latency = 1: data valid one cycle after po_rd
    po_data    : out std_logic_vector(31 downto 0);
    po_rd      : in  std_logic;

    -- PipeIn write port (host → NEORV32 RX, fp_clk domain)
    pi_data    : in  std_logic_vector(31 downto 0);
    pi_wr      : in  std_logic;

    -- RX FIFO entry count (fp_clk domain, for WireOut)
    rx_count   : out std_logic_vector(10 downto 0);

    -- BTPipe flow-control (fp_clk domain)
    tx_ready   : out std_logic;   -- TX FIFO can accept data (not full)
    rx_ready   : out std_logic;   -- RX FIFO has data available (not empty)

    -- Baud rate divisor (fp_clk domain, from WireIn)
    baud_div   : in  std_logic_vector(15 downto 0)
  );
end entity fp_uart_bridge;

architecture rtl of fp_uart_bridge is

  -- Default divisor: 19200 baud @ 100 MHz = 5207
  constant BAUD_DIV_DEFAULT : std_logic_vector(15 downto 0) := x"1457";

  -- Baud divisor CDC (fp_clk → sys_clk, double-register)
  signal baud_sync1  : std_logic_vector(15 downto 0) := BAUD_DIV_DEFAULT;
  signal baud_sync2  : std_logic_vector(15 downto 0) := BAUD_DIV_DEFAULT;
  signal baud_active : unsigned(15 downto 0);

  ---------------------------------------------------------------------------
  -- UART RX — captures serial data from NEORV32 uart0_txd_o
  ---------------------------------------------------------------------------
  signal rx_sync     : std_logic_vector(1 downto 0) := "11";
  signal rx_busy     : std_logic := '0';
  signal rx_baud_cnt : unsigned(15 downto 0) := (others => '0');
  signal rx_bit_idx  : natural range 0 to 9 := 0;
  signal rx_shift    : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_byte     : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_valid    : std_logic := '0';

  -- RX FIFO (sys_clk write → fp_clk read)
  signal rxf_wr_en    : std_logic;
  signal rxf_full     : std_logic;
  signal rxf_rd_en    : std_logic;
  signal rxf_dout     : std_logic_vector(7 downto 0);
  signal rxf_empty    : std_logic;
  signal rxf_rdcnt    : std_logic_vector(10 downto 0);
  signal rxf_valid_r  : std_logic := '0';  -- registered valid flag, aligned with rxf_dout

  ---------------------------------------------------------------------------
  -- UART TX — serializes bytes toward NEORV32 uart0_rxd_i
  ---------------------------------------------------------------------------
  signal tx_busy     : std_logic := '0';
  signal tx_baud_cnt : unsigned(15 downto 0) := (others => '0');
  signal tx_bit_idx  : natural range 0 to 9 := 0;
  signal tx_shift    : std_logic_vector(8 downto 0) := (others => '1');

  -- TX FIFO (fp_clk write → sys_clk read, FWFT so data is ready immediately)
  signal txf_wr_en    : std_logic;
  signal txf_full     : std_logic;
  signal txf_prog_full : std_logic;
  signal txf_rd_en    : std_logic;
  signal txf_dout     : std_logic_vector(7 downto 0);
  signal txf_empty    : std_logic;

begin

  ---------------------------------------------------------------------------
  -- Baud divisor CDC: double-register from fp_clk into sys_clk.
  -- Safe because the host sets the divisor once before communication starts.
  ---------------------------------------------------------------------------
  process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      baud_sync1 <= baud_div;
      baud_sync2 <= baud_sync1;
    end if;
  end process;

  baud_active <= unsigned(baud_sync2) when unsigned(baud_sync2) /= 0
                 else unsigned(BAUD_DIV_DEFAULT);

  ---------------------------------------------------------------------------
  -- UART RX: deserialize NEORV32 uart0_txd_o into bytes
  --   State machine: IDLE → start-bit verify → 8 data bits → stop bit
  ---------------------------------------------------------------------------
  process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      -- 2-stage input synchronizer
      rx_sync <= rx_sync(0) & uart_tx_i;
      rx_valid <= '0';

      if sys_rstn = '0' then
        rx_busy <= '0';
      elsif rx_busy = '0' then
        -- Detect falling edge → start bit candidate
        if rx_sync = "10" then
          rx_busy     <= '1';
          -- Sample at mid-bit: half a bit-period from now
          rx_baud_cnt <= ('0' & baud_active(15 downto 1));  -- baud_active / 2
          rx_bit_idx  <= 0;
        end if;
      else
        if rx_baud_cnt = 0 then
          rx_baud_cnt <= baud_active;
          case rx_bit_idx is
            when 0 =>
              -- Verify start bit (should be '0')
              if rx_sync(1) /= '0' then
                rx_busy <= '0';  -- false start, abort
              end if;
              rx_bit_idx <= 1;
            when 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 =>
              -- Data bits (LSB first, shifted in from the left)
              rx_shift   <= rx_sync(1) & rx_shift(7 downto 1);
              rx_bit_idx <= rx_bit_idx + 1;
            when 9 =>
              -- Stop bit
              rx_busy <= '0';
              if rx_sync(1) = '1' then
                rx_valid <= '1';
                rx_byte  <= rx_shift;
              end if;
            when others =>
              rx_busy <= '0';
          end case;
        else
          rx_baud_cnt <= rx_baud_cnt - 1;
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- RX Async FIFO: sys_clk (write) → fp_clk (read)
  -- Standard read mode (latency = 1) matches okPipeOut timing: PipeOut
  -- asserts po_rd on cycle N and captures po_data on cycle N+1.
  -- The valid flag rxf_valid_r is registered on the same edge so it
  -- arrives at po_data(8) aligned with rxf_dout on po_data(7:0).
  ---------------------------------------------------------------------------
  rxf_wr_en <= rx_valid and not rxf_full;

  rx_fifo_i : xpm_fifo_async
    generic map (
      CDC_SYNC_STAGES     => 2,
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "auto",
      FIFO_READ_LATENCY   => 1,
      FIFO_WRITE_DEPTH    => 2048,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => 10,
      RD_DATA_COUNT_WIDTH => 11,
      READ_DATA_WIDTH     => 8,
      READ_MODE           => "std",
      RELATED_CLOCKS      => 0,
      SIM_ASSERT_CHK      => 0,
      USE_ADV_FEATURES    => "0404",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => 8,
      WR_DATA_COUNT_WIDTH => 11
    )
    port map (
      wr_clk        => sys_clk,
      rst           => not sys_rstn,
      wr_en         => rxf_wr_en,
      din           => rx_byte,
      full          => rxf_full,
      rd_clk        => fp_clk,
      rd_en         => rxf_rd_en,
      dout          => rxf_dout,
      empty         => rxf_empty,
      rd_data_count => rxf_rdcnt,
      wr_data_count => open,
      wr_rst_busy   => open,
      rd_rst_busy   => open,
      overflow      => open,
      underflow     => open,
      prog_full     => open,
      prog_empty    => open,
      almost_full   => open,
      almost_empty  => open,
      sleep         => '0',
      injectsbiterr => '0',
      injectdbiterr => '0',
      wr_ack        => open,
      data_valid    => open,
      sbiterr       => open,
      dbiterr       => open
    );

  -- PipeOut interface: one UART byte per 32-bit pipe word.
  -- Gate rd_en so empty-FIFO reads don't cause underflow.
  -- Register the "had data" flag so it arrives on the same cycle as
  -- rxf_dout (both one fp_clk after po_rd) — matching okPipeOut latency.
  rxf_rd_en <= po_rd and not rxf_empty;

  process (fp_clk)
  begin
    if rising_edge(fp_clk) then
      rxf_valid_r <= po_rd and not rxf_empty;
    end if;
  end process;

  po_data(31 downto 9)   <= (others => '0');
  po_data(8)             <= rxf_valid_r;
  po_data(7 downto 0)    <= rxf_dout;
  rx_count               <= rxf_rdcnt;

  tx_ready               <= not txf_prog_full;
  rx_ready               <= not rxf_empty;

  ---------------------------------------------------------------------------
  -- TX Async FIFO: fp_clk (write) → sys_clk (read)
  -- FWFT mode so dout is valid as soon as the FIFO is non-empty;
  -- the UART TX process reads when idle and data is available.
  -- prog_full threshold = 1792 leaves 256 entries free (one BTPipe block).
  -- This ensures ep_ready deasserts before the FIFO is truly full,
  -- giving the BTPipeIn controller time to halt without data loss.
  ---------------------------------------------------------------------------
  txf_wr_en <= pi_wr and not txf_full and pi_data(8);

  tx_fifo_i : xpm_fifo_async
    generic map (
      CDC_SYNC_STAGES     => 2,
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "auto",
      FIFO_READ_LATENCY   => 0,
      FIFO_WRITE_DEPTH    => 2048,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => 1792,
      RD_DATA_COUNT_WIDTH => 11,
      READ_DATA_WIDTH     => 8,
      READ_MODE           => "fwft",
      RELATED_CLOCKS      => 0,
      SIM_ASSERT_CHK      => 0,
      USE_ADV_FEATURES    => "0002",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => 8,
      WR_DATA_COUNT_WIDTH => 11
    )
    port map (
      wr_clk        => fp_clk,
      rst           => not sys_rstn,
      wr_en         => txf_wr_en,
      din           => pi_data(7 downto 0),
      full          => txf_full,
      rd_clk        => sys_clk,
      rd_en         => txf_rd_en,
      dout          => txf_dout,
      empty         => txf_empty,
      wr_data_count => open,
      rd_data_count => open,
      wr_rst_busy   => open,
      rd_rst_busy   => open,
      overflow      => open,
      underflow     => open,
      prog_full     => txf_prog_full,
      prog_empty    => open,
      almost_full   => open,
      almost_empty  => open,
      sleep         => '0',
      injectsbiterr => '0',
      injectdbiterr => '0',
      wr_ack        => open,
      data_valid    => open,
      sbiterr       => open,
      dbiterr       => open
    );

  ---------------------------------------------------------------------------
  -- UART TX: serialize bytes from the TX FIFO to NEORV32 uart0_rxd_i
  --   Reads from the FWFT FIFO when idle, shifts out start + 8 data + stop.
  ---------------------------------------------------------------------------
  process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      txf_rd_en <= '0';

      if sys_rstn = '0' then
        tx_busy  <= '0';
        uart_rx_o <= '1';
      elsif tx_busy = '0' then
        if txf_empty = '0' then
          -- Load start bit onto the line immediately; shift register holds
          -- data[7:0] and stop bit for subsequent tick periods.
          uart_rx_o  <= '0';                        -- start bit
          tx_shift   <= '1' & txf_dout;             -- stop & D7..D0
          txf_rd_en  <= '1';                        -- advance FIFO
          tx_busy    <= '1';
          tx_baud_cnt <= baud_active;
          tx_bit_idx  <= 0;
        else
          uart_rx_o <= '1';                         -- idle high
        end if;
      else
        if tx_baud_cnt = 0 then
          if tx_bit_idx = 9 then
            -- Stop bit period complete → idle
            tx_busy   <= '0';
            uart_rx_o <= '1';
          else
            tx_baud_cnt <= baud_active;
            if tx_bit_idx < 8 then
              -- Data bits: shift out LSB first
              uart_rx_o <= tx_shift(0);
              tx_shift  <= '1' & tx_shift(8 downto 1);
            else
              -- Stop bit
              uart_rx_o <= '1';
            end if;
            tx_bit_idx <= tx_bit_idx + 1;
          end if;
        else
          tx_baud_cnt <= tx_baud_cnt - 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
