-- FrontPanel FFT Pipe Bridge
-- Copyright (c) 2026 A P Nicholson , intothemist@gmail.com
-- SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
--
-- Bulk-sample transport between the host PC (via FrontPanel BTPipe endpoints)
-- and the NEORV32 SoC.  The CPU remains in the loop and still invokes the
-- existing FFT accelerator driver (fft_accel_transform) to drive the AXI DMA
-- and xfft pipeline; this bridge only replaces UART as the bulk-sample carrier.
--
-- Data path (one frame = 4096 × 32-bit Q1.15 complex samples):
--   host  →  BTPipeIn  0x81  →  fifo_in  (async, 32 b × 8192 deep)  →  XBUS
--   XBUS  →  fifo_out (async, 32 b × 8192 deep)  →  BTPipeOut 0xA1  →  host
--
-- XBUS slave window (mapped at 0x9000_0000 in xem7310_top.vhd):
--   0x0 (R): pop one 32-bit sample from fifo_in
--   0x4 (W): push one 32-bit sample to fifo_out
--   0x8 (R): status word = { fifo_out_wr_count[15:0], fifo_in_rd_count[15:0] }
--   0xC (W): cycles latch — stores wdat in cycles_sys and bumps frame_count_sys
--
-- WireOut surface (driven from this entity in the fp_clk domain):
--   0x24 : { fifo_out_rd_count[15:0], fifo_in_wr_count[15:0] }
--   0x25 : hw_cycles_o      (last published cycle count, sys→fp CDC)
--   0x26 : frame_count_o    (free-running frame counter, sys→fp CDC)
--
-- The host uses fifo_out_rd_count >= 4096 as the "frame ready" indication and
-- reads hw_cycles_o for the speedup statistic.  The CPU publishes cycles
-- BEFORE pushing the output frame to fifo_out so the value is valid by the
-- time the host sees the count.
--
-- Clock domains:
--   sys_clk  (~100 MHz)    — XBUS slave, sys-side of both async FIFOs
--   fp_clk   (~100.8 MHz)  — FrontPanel pipe endpoints, fp-side of both FIFOs

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity fp_fft_pipe_bridge is
  port (
    -- System clock domain (NEORV32 side)
    sys_clk          : in  std_logic;
    sys_rstn         : in  std_logic;

    -- XBUS slave interface from NEORV32 (4-byte address: REG select).
    -- The parent module decodes the upper address bits (region 0x9000_0000)
    -- and only forwards xbus_stb when the access targets this region.
    xbus_addr        : in  std_ulogic_vector(3 downto 0);
    xbus_stb         : in  std_ulogic;
    xbus_we          : in  std_ulogic;
    xbus_wdat        : in  std_ulogic_vector(31 downto 0);
    xbus_rdat        : out std_ulogic_vector(31 downto 0);
    xbus_ack         : out std_ulogic;

    -- FrontPanel clock domain (~100.8 MHz from okHost)
    fp_clk           : in  std_logic;

    -- BTPipeIn 0x81 (host → fifo_in)
    pi_data          : in  std_logic_vector(31 downto 0);
    pi_wr            : in  std_logic;
    pi_ready         : out std_logic;

    -- BTPipeOut 0xA1 (fifo_out → host)
    po_data          : out std_logic_vector(31 downto 0);
    po_rd            : in  std_logic;
    po_ready         : out std_logic;

    -- WireOut status (fp_clk domain)
    fifo_in_count_o  : out std_logic_vector(15 downto 0);
    fifo_out_count_o : out std_logic_vector(15 downto 0);
    hw_cycles_o      : out std_logic_vector(31 downto 0);
    frame_count_o    : out std_logic_vector(31 downto 0)
  );
end entity fp_fft_pipe_bridge;

architecture rtl of fp_fft_pipe_bridge is

  -- ── XBUS register offsets (within the 4-bit window) ────────────────────
  constant REG_FIFO_POP  : std_ulogic_vector(3 downto 0) := x"0";
  constant REG_FIFO_PUSH : std_ulogic_vector(3 downto 0) := x"4";
  constant REG_STATUS    : std_ulogic_vector(3 downto 0) := x"8";
  constant REG_PUBLISH   : std_ulogic_vector(3 downto 0) := x"C";

  -- ── XBUS slave state ──────────────────────────────────────────────────
  signal ack_q  : std_ulogic := '0';
  signal rdat_q : std_ulogic_vector(31 downto 0) := (others => '0');

  -- One-cycle access strobe (active in the cycle the master first asserts
  -- stb; gated low once ack_q is high so FIFO rd_en / wr_en pulse exactly
  -- once per XBUS transaction).
  signal access_pulse : std_ulogic;

  -- ── CPU-side cycles + frame counter latches ───────────────────────────
  signal cycles_sys      : std_logic_vector(31 downto 0) := (others => '0');
  signal frame_count_sys : unsigned(31 downto 0)         := (others => '0');

  -- ── FIFO IN (host → CPU): fp_clk write, sys_clk read, FWFT ────────────
  signal fifo_in_wr_en       : std_logic;
  signal fifo_in_full        : std_logic;
  signal fifo_in_prog_full   : std_logic;
  signal fifo_in_dout        : std_logic_vector(31 downto 0);
  signal fifo_in_rd_en       : std_logic;
  signal fifo_in_empty       : std_logic;
  signal fifo_in_rd_cnt      : std_logic_vector(13 downto 0);
  signal fifo_in_wr_cnt      : std_logic_vector(13 downto 0);
  signal fifo_in_wr_rst_busy : std_logic;  -- fp_clk  domain: gates wr_en
  signal fifo_in_rd_rst_busy : std_logic;  -- sys_clk domain: gates rd_en

  -- ── FIFO OUT (CPU → host): sys_clk write, fp_clk read, std (latency 1)
  signal fifo_out_wr_en       : std_logic;
  signal fifo_out_full        : std_logic;
  signal fifo_out_dout        : std_logic_vector(31 downto 0);
  signal fifo_out_rd_en       : std_logic;
  signal fifo_out_empty       : std_logic;
  signal fifo_out_rd_cnt      : std_logic_vector(13 downto 0);
  signal fifo_out_wr_cnt      : std_logic_vector(13 downto 0);
  signal fifo_out_wr_rst_busy : std_logic;  -- sys_clk domain: gates wr_en
  signal fifo_out_rd_rst_busy : std_logic;  -- fp_clk  domain: gates rd_en

  -- ── CDC of cycles + frame_counter from sys_clk → fp_clk ───────────────
  -- cycles crosses atomically via xpm_cdc_handshake (M3): cycles_sys can change
  -- in all 32 bits at once, so per-bit xpm_cdc_array_single could land different
  -- bits on different fp_clk edges (a torn value).  frame_count on the fp side
  -- is derived from the handshake completion (dest_req) so it only advances once
  -- the matching cycles value has landed coherently — preserving the host
  -- contract "new frame_count ⇒ cycles is fresh and valid".
  signal cycles_fp      : std_logic_vector(31 downto 0);
  signal frame_count_fp : std_logic_vector(31 downto 0) := (others => '0');

  -- Handshake control (sys side): one src_send pulse per REG_PUBLISH write,
  -- guarded by cdc_busy so a new transfer is not launched until the previous
  -- one is acknowledged (src_rcv).  REG_PUBLISH happens once per frame, far
  -- slower than the handshake latency, so this never actually stalls a publish.
  signal cdc_src_send : std_logic := '0';
  signal cdc_src_rcv  : std_logic;
  signal cdc_busy     : std_logic := '0';
  signal publish_pulse : std_logic;

  -- fp side: handshake completion strobe; increments frame_count_fp.
  signal cdc_dest_req : std_logic;

begin

  ---------------------------------------------------------------------------
  -- XBUS slave state machine
  --
  -- Wishbone-classic semantics: master holds xbus_stb high until ack=1, then
  -- drops stb on the following cycle.  We register a single-cycle ack_q so
  -- the master sees exactly one ack per access, and we use ack_q as an
  -- inhibit on the FIFO read/write enables so each transaction pops/pushes
  -- exactly one FIFO word.
  --
  --   Cycle N   : stb=1, ack_q=0 → access_pulse=1 → fifo_*_en pulse high
  --                                                  rdat_q latched from
  --                                                  fifo_in_dout / status
  --                                                  cycles_sys / frame_count
  --                                                  updated on writes.
  --   Cycle N+1 : ack_q=1, master sees ack and samples rdat_q.  fifo_*_en
  --               held low by ack_q gating.
  --   Cycle N+2 : master drops stb, ack_q goes back to 0.
  ---------------------------------------------------------------------------
  access_pulse <= xbus_stb and not ack_q;

  process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      if sys_rstn = '0' then
        ack_q           <= '0';
        rdat_q          <= (others => '0');
        cycles_sys      <= (others => '0');
        frame_count_sys <= (others => '0');
      else
        ack_q <= access_pulse;

        if access_pulse = '1' then
          case xbus_addr is
            when REG_FIFO_POP =>
              rdat_q <= std_ulogic_vector(fifo_in_dout);
            when REG_STATUS =>
              rdat_q <= (31 downto 30 => '0')
                      & std_ulogic_vector(fifo_out_wr_cnt)
                      & (15 downto 14 => '0')
                      & std_ulogic_vector(fifo_in_rd_cnt);
            when REG_PUBLISH =>
              if xbus_we = '1' then
                cycles_sys      <= std_logic_vector(xbus_wdat);
                frame_count_sys <= frame_count_sys + 1;
              end if;
              rdat_q <= (others => '0');
            when others =>
              rdat_q <= (others => '0');
          end case;
        end if;
      end if;
    end if;
  end process;

  xbus_rdat <= rdat_q;
  xbus_ack  <= ack_q;

  -- ── Handshake source control (sys_clk) ────────────────────────────────
  -- publish_pulse: 1-cycle strobe when the CPU writes REG_PUBLISH (the same
  -- event that latches cycles_sys and bumps frame_count_sys above).
  publish_pulse <= '1' when (access_pulse = '1' and xbus_we = '1'
                             and xbus_addr = REG_PUBLISH) else '0';

  process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      if sys_rstn = '0' then
        cdc_src_send <= '0';
        cdc_busy     <= '0';
      else
        cdc_src_send <= '0';                 -- default: single-cycle pulse
        if cdc_busy = '0' then
          if publish_pulse = '1' then
            -- cycles_sys updates on this same edge; launch the transfer.
            cdc_src_send <= '1';
            cdc_busy     <= '1';
          end if;
        elsif cdc_src_rcv = '1' then
          cdc_busy <= '0';                   -- transfer acknowledged; ready again
        end if;
      end if;
    end if;
  end process;

  -- FIFO_IN read pulse: pop one word when REG_FIFO_POP is read.
  -- Inhibited while rd_rst_busy is asserted — XPM drops reads issued during
  -- reset recovery, which would silently desync the sample stream.
  fifo_in_rd_en <= '1' when (access_pulse = '1'
                             and xbus_we = '0'
                             and xbus_addr = REG_FIFO_POP
                             and fifo_in_empty = '0'
                             and fifo_in_rd_rst_busy = '0')
                       else '0';

  -- FIFO_OUT write pulse: push wdat when REG_FIFO_PUSH is written.
  -- Inhibited while wr_rst_busy is asserted — XPM drops writes issued during
  -- reset recovery, which would silently drop an output sample.
  fifo_out_wr_en <= '1' when (access_pulse = '1'
                              and xbus_we = '1'
                              and xbus_addr = REG_FIFO_PUSH
                              and fifo_out_full = '0'
                              and fifo_out_wr_rst_busy = '0')
                        else '0';

  ---------------------------------------------------------------------------
  -- FIFO IN: host → CPU
  -- 32-bit data, depth 8192 (= 2 frames of headroom for a 4096-point FFT).
  -- FWFT read mode so the dout port always shows the next pending sample
  -- and a single rd_en pulse advances the head on the next sys_clk edge.
  -- prog_full threshold leaves one BTPipe block (1024 bytes = 256 words)
  -- free, matching the safety margin used by fp_uart_bridge.vhd.
  ---------------------------------------------------------------------------
  fifo_in_wr_en <= pi_wr and not fifo_in_full and not fifo_in_wr_rst_busy;

  fifo_in_i : xpm_fifo_async
    generic map (
      CDC_SYNC_STAGES     => 2,
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "auto",
      FIFO_READ_LATENCY   => 0,
      FIFO_WRITE_DEPTH    => 8192,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => 7936,
      RD_DATA_COUNT_WIDTH => 14,
      READ_DATA_WIDTH     => 32,
      READ_MODE           => "fwft",
      RELATED_CLOCKS      => 0,
      SIM_ASSERT_CHK      => 0,
      -- USE_ADV_FEATURES bit map (Vivado xpm_fifo_async):
      --   [1] PROG_FULL  [2] WR_DATA_COUNT  [10] RD_DATA_COUNT
      USE_ADV_FEATURES    => "0406",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => 32,
      WR_DATA_COUNT_WIDTH => 14
    )
    port map (
      wr_clk        => fp_clk,
      rst           => not sys_rstn,
      wr_en         => fifo_in_wr_en,
      din           => pi_data,
      full          => fifo_in_full,
      rd_clk        => sys_clk,
      rd_en         => fifo_in_rd_en,
      dout          => fifo_in_dout,
      empty         => fifo_in_empty,
      rd_data_count => fifo_in_rd_cnt,
      wr_data_count => fifo_in_wr_cnt,
      wr_rst_busy   => fifo_in_wr_rst_busy,
      rd_rst_busy   => fifo_in_rd_rst_busy,
      overflow      => open,
      underflow     => open,
      prog_full     => fifo_in_prog_full,
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

  -- Hold off the host BTPipeIn while the write side is in reset recovery.
  pi_ready <= not fifo_in_prog_full and not fifo_in_wr_rst_busy;

  ---------------------------------------------------------------------------
  -- FIFO OUT: CPU → host
  -- 32-bit data, depth 8192.  Standard read mode (FIFO_READ_LATENCY = 1) so
  -- dout is valid one fp_clk after rd_en, which matches the okBTPipeOut
  -- handshake exactly (the BTPipeOut module pulses ep_read on cycle N and
  -- captures ep_datain on cycle N+1).
  --
  -- po_ready = not empty so the BTPipe transfer only proceeds while data
  -- is available.  The host application waits for fifo_out_count >= 4096
  -- (via WireOut 0x24) before initiating a block read, so the FIFO will
  -- not drain mid-transfer in practice.
  ---------------------------------------------------------------------------
  fifo_out_i : xpm_fifo_async
    generic map (
      CDC_SYNC_STAGES     => 2,
      DOUT_RESET_VALUE    => "0",
      ECC_MODE            => "no_ecc",
      FIFO_MEMORY_TYPE    => "auto",
      FIFO_READ_LATENCY   => 1,
      FIFO_WRITE_DEPTH    => 8192,
      FULL_RESET_VALUE    => 0,
      PROG_EMPTY_THRESH   => 10,
      PROG_FULL_THRESH    => 10,
      RD_DATA_COUNT_WIDTH => 14,
      READ_DATA_WIDTH     => 32,
      READ_MODE           => "std",
      RELATED_CLOCKS      => 0,
      SIM_ASSERT_CHK      => 0,
      -- USE_ADV_FEATURES bit map (Vivado xpm_fifo_async):
      --   [2] WR_DATA_COUNT  [10] RD_DATA_COUNT
      USE_ADV_FEATURES    => "0404",
      WAKEUP_TIME         => 0,
      WRITE_DATA_WIDTH    => 32,
      WR_DATA_COUNT_WIDTH => 14
    )
    port map (
      wr_clk        => sys_clk,
      rst           => not sys_rstn,
      wr_en         => fifo_out_wr_en,
      din           => std_logic_vector(xbus_wdat),
      full          => fifo_out_full,
      rd_clk        => fp_clk,
      rd_en         => fifo_out_rd_en,
      dout          => fifo_out_dout,
      empty         => fifo_out_empty,
      rd_data_count => fifo_out_rd_cnt,
      wr_data_count => fifo_out_wr_cnt,
      wr_rst_busy   => fifo_out_wr_rst_busy,
      rd_rst_busy   => fifo_out_rd_rst_busy,
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

  -- Gate the read side with rd_rst_busy: XPM drops reads during reset
  -- recovery, and po_ready must stay low so the host BTPipeOut does not
  -- advance against a FIFO that is not yet serving data.
  fifo_out_rd_en <= po_rd and not fifo_out_empty and not fifo_out_rd_rst_busy;
  po_data        <= fifo_out_dout;
  po_ready       <= not fifo_out_empty and not fifo_out_rd_rst_busy;

  ---------------------------------------------------------------------------
  -- WireOut status (fp_clk domain)
  --
  --   fifo_in_count_o  : write-side count of fifo_in  (fp domain)
  --   fifo_out_count_o : read-side count of fifo_out (fp domain)
  --
  -- The 14-bit FIFO counts are zero-extended to 16 bits for the WireOut.
  -- The host watches fifo_out_count_o >= 4096 to detect frame completion.
  ---------------------------------------------------------------------------
  fifo_in_count_o  <= "00" & fifo_in_wr_cnt;
  fifo_out_count_o <= "00" & fifo_out_rd_cnt;

  ---------------------------------------------------------------------------
  -- cycles CDC, sys_clk → fp_clk, via xpm_cdc_handshake (M3).
  --
  -- cycles_sys is an arbitrary 32-bit value that can change in every bit on a
  -- single REG_PUBLISH write.  A per-bit synchroniser (xpm_cdc_array_single)
  -- can therefore present a torn value on fp_clk when bits resolve on different
  -- edges.  The handshake macro transfers the whole bus atomically: dest_out is
  -- only updated (and dest_req pulsed) once the full word has crossed coherently.
  --
  -- DEST_EXT_HSK=0 → internal auto-acknowledge, so dest_ack is tied low and the
  -- fp side just observes dest_req.  src_send is single-cycle and re-armed only
  -- after src_rcv (see the cdc_busy guard in the sys process above).
  ---------------------------------------------------------------------------
  cdc_cycles_i : xpm_cdc_handshake
    generic map (
      DEST_EXT_HSK   => 0,
      DEST_SYNC_FF   => 2,
      INIT_SYNC_FF   => 0,
      SIM_ASSERT_CHK => 0,
      SRC_SYNC_FF    => 2,
      WIDTH          => 32
    )
    port map (
      src_clk  => sys_clk,
      src_in   => cycles_sys,
      src_send => cdc_src_send,
      src_rcv  => cdc_src_rcv,
      dest_clk => fp_clk,
      dest_req => cdc_dest_req,
      dest_ack => '0',
      dest_out => cycles_fp
    );

  ---------------------------------------------------------------------------
  -- frame_count (fp_clk): derived from handshake completion, NOT separately
  -- synchronised.  Incrementing on each dest_req pulse guarantees the count the
  -- host sees only advances after the matching cycles value has landed in
  -- cycles_fp — so the hosts rule "new frame_count ⇒ cycles is fresh and
  -- coherent" holds by construction.  frame_count_sys remains the sys-side
  -- bookkeeping counter (e.g. for the CPU), but is no longer raw-CDCd.
  ---------------------------------------------------------------------------
  process (fp_clk)
  begin
    if rising_edge(fp_clk) then
      if cdc_dest_req = '1' then
        frame_count_fp <= std_logic_vector(unsigned(frame_count_fp) + 1);
      end if;
    end if;
  end process;

  hw_cycles_o   <= cycles_fp;
  frame_count_o <= frame_count_fp;

end architecture rtl;
