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
-- XBUS slave window (mapped at 0x9000_0000 in xem7310_top.vhd — a 32-byte,
-- six-register window; the parent decodes adr[27:5]=0 so only 0x9000_00{00..1F}
-- reach this slave and any wider stray access raises xbus_err):
--   0x00 (R): pop one 32-bit sample from fifo_in
--   0x04 (W): push one 32-bit sample to fifo_out
--   0x08 (R): status word = { fifo_out_wr_count[15:0], fifo_in_rd_count[15:0] }
--   0x0C (W): cycles latch — stores wdat in cycles_sys and bumps frame_count_sys
--   0x10 (R): filter_cfg — host filter control word (WireIn 0x01, fp→sys CDC)
--   0x14 (W): applied_status — firmware filter status echo (sys→fp CDC → WireOut 0x28)
--
-- WireOut surface (driven from this entity in the fp_clk domain):
--   0x24 : { fifo_out_rd_count[15:0], fifo_in_wr_count[15:0] }
--   0x25 : hw_cycles_o      (last published cycle count, sys→fp CDC)
--   0x26 : frame_count_o    (free-running frame counter, sys→fp CDC)
--   0x28 : applied_status_o (filter status echo, sys→fp CDC)
--
-- The host uses fifo_out_rd_count >= 4096 as the "frame ready" indication and
-- reads hw_cycles_o for the speedup statistic.  The CPU publishes cycles
-- BEFORE pushing the output frame to fifo_out so the value is valid by the
-- time the host sees the count.
--
-- Filter control path (host → fabric → CPU): the host writes a filter-config
-- word to WireIn 0x01 (fp_clk).  filter_cfg_i is CDC'd into sys_clk with the
-- same per-bit xpm_cdc_array_single pattern used for cycles/frame below and
-- exposed to the CPU as the read-only 0x10 register.  The firmware
-- change-detects this word (with a double-read debounce — the host
-- UpdateWireIns can momentarily tear the multi-field word) and reprograms the
-- coeff BRAM.  The firmware then writes a status echo to 0x14, CDC'd back to
-- fp_clk on WireOut 0x28 so the host knows the applied mode / overflow /
-- filter-availability.  Both crossings are quasi-static — do NOT replace the
-- array_single with xpm_cdc_handshake (see the CDC note further down).
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

    -- XBUS slave interface from NEORV32 (5-bit register select within a
    -- 32-byte window).  The parent module decodes the upper address bits
    -- (region 0x9000_0000, adr[27:5]=0) and only forwards xbus_stb when the
    -- access targets this region.
    xbus_addr        : in  std_ulogic_vector(4 downto 0);
    xbus_stb         : in  std_ulogic;
    xbus_we          : in  std_ulogic;
    xbus_wdat        : in  std_ulogic_vector(31 downto 0);
    xbus_rdat        : out std_ulogic_vector(31 downto 0);
    xbus_ack         : out std_ulogic;

    -- FrontPanel clock domain (~100.8 MHz from okHost)
    fp_clk           : in  std_logic;

    -- Filter control (fp_clk): host WireIn 0x01 → CDC → XBUS read register 0x10
    filter_cfg_i     : in  std_logic_vector(31 downto 0);
    -- Filter status echo (fp_clk): XBUS write register 0x14 → CDC → WireOut 0x28
    applied_status_o : out std_logic_vector(31 downto 0);

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

  -- ── XBUS register offsets (within the 5-bit / 32-byte window) ──────────
  constant REG_FIFO_POP   : std_ulogic_vector(4 downto 0) := "0" & x"0";  -- 0x00
  constant REG_FIFO_PUSH  : std_ulogic_vector(4 downto 0) := "0" & x"4";  -- 0x04
  constant REG_STATUS     : std_ulogic_vector(4 downto 0) := "0" & x"8";  -- 0x08
  constant REG_PUBLISH    : std_ulogic_vector(4 downto 0) := "0" & x"C";  -- 0x0C
  constant REG_FILTER_CFG : std_ulogic_vector(4 downto 0) := "1" & x"0";  -- 0x10 (R)
  constant REG_APPLIED    : std_ulogic_vector(4 downto 0) := "1" & x"4";  -- 0x14 (W)

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
  -- Per-bit xpm_cdc_array_single is correct here:
  --   * frame_count_sys is a monotonically-incrementing counter, so any
  --     bit-tearing the host could see is constrained to (old) → (new); it
  --     never produces an out-of-sequence value for a counter that increments
  --     by 1 per frame.
  --   * cycles_sys and frame_count_sys are written on the SAME sys_clk edge
  --     (the REG_PUBLISH access below) and then held constant.  Each value goes
  --     through its own identical 2-FF synchroniser, so by the time the host
  --     observes frame_count_fp advance, cycles_fp (clocked into fp_clk from a
  --     value that stopped changing on the same source edge) has resolved to
  --     the matching frame.  The host reading cycles right after the counter
  --     bump therefore cannot latch a stale value — correctness does NOT depend
  --     on the host deferring the cycles read until fifo_out_count >= FFT_N.
  -- An earlier rewrite to xpm_cdc_handshake ("M3") silently dropped publishes
  -- when the fp-side handshake hadn't completed yet (cdc_busy=1), causing
  -- frame_count_fp to fall behind frame_count_sys and the host's
  -- wait_frame_done to time out at random frames.  Reverted — do NOT
  -- reintroduce a handshake here (synthesis success masked the on-board defect).
  signal cycles_fp      : std_logic_vector(31 downto 0);
  signal frame_count_fp : std_logic_vector(31 downto 0);

  -- ── Filter control / status CDC (same quasi-static array_single pattern) ──
  -- filter_cfg_i  (fp_clk, host WireIn 0x01) → filter_cfg_sys (sys_clk, CPU reads 0x10)
  -- applied_status_sys (sys_clk, CPU writes 0x14) → applied_status_o (fp_clk, WireOut 0x28)
  -- Both words are quasi-static control/status (they change at most once per
  -- frame and are then held constant), so per-bit array_single is correct here
  -- for exactly the reasons spelled out above for cycles/frame — and the same
  -- "do NOT use xpm_cdc_handshake" warning applies.  Word coherence of
  -- filter_cfg across a host UpdateWireIns is handled by a firmware double-read
  -- debounce, NOT by an RTL handshake.
  signal filter_cfg_sys     : std_logic_vector(31 downto 0);
  signal applied_status_sys : std_logic_vector(31 downto 0) := (others => '0');

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
        ack_q              <= '0';
        rdat_q             <= (others => '0');
        cycles_sys         <= (others => '0');
        frame_count_sys    <= (others => '0');
        applied_status_sys <= (others => '0');
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
            when REG_FILTER_CFG =>
              -- Read-only: the host filter control word, CDC'd from WireIn 0x01.
              rdat_q <= std_ulogic_vector(filter_cfg_sys);
            when REG_APPLIED =>
              -- Write-only: firmware filter status echo, CDC'd out to WireOut 0x28.
              if xbus_we = '1' then
                applied_status_sys <= std_logic_vector(xbus_wdat);
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
  -- cycles + frame_counter CDC, sys_clk → fp_clk.
  --
  -- Both values are quasi-static (they change once per frame) and are written
  -- on the same sys_clk edge (REG_PUBLISH), so cycles_fp is valid by the time
  -- the host observes frame_count_fp advance.  Per-bit array_single is correct
  -- here; the earlier xpm_cdc_handshake rewrite was a regression (it dropped
  -- publishes under USB load).  See the signal-decl comment above for the full
  -- rationale and the "do NOT reintroduce a handshake" note.
  ---------------------------------------------------------------------------
  cdc_cycles_i : xpm_cdc_array_single
    generic map (
      DEST_SYNC_FF   => 2,
      INIT_SYNC_FF   => 0,
      SIM_ASSERT_CHK => 0,
      SRC_INPUT_REG  => 1,
      WIDTH          => 32
    )
    port map (
      src_clk  => sys_clk,
      src_in   => cycles_sys,
      dest_clk => fp_clk,
      dest_out => cycles_fp
    );

  cdc_frame_i : xpm_cdc_array_single
    generic map (
      DEST_SYNC_FF   => 2,
      INIT_SYNC_FF   => 0,
      SIM_ASSERT_CHK => 0,
      SRC_INPUT_REG  => 1,
      WIDTH          => 32
    )
    port map (
      src_clk  => sys_clk,
      src_in   => std_logic_vector(frame_count_sys),
      dest_clk => fp_clk,
      dest_out => frame_count_fp
    );

  hw_cycles_o   <= cycles_fp;
  frame_count_o <= frame_count_fp;

  ---------------------------------------------------------------------------
  -- Filter control / status CDC (same quasi-static array_single pattern).
  --
  -- filter_cfg_i is the host filter control word on WireIn 0x01 (fp_clk).
  -- It is quasi-static: the host writes it (UpdateWireIns) at most a few
  -- times per second and then holds it.  Per-bit array_single resolves
  -- metastability; word coherence across a host UpdateWireIns is closed by
  -- the firmware double-read debounce (NOT an RTL handshake — see the note
  -- above; xpm_cdc_handshake was a regression for the cycles path and the
  -- same hazard applies here).
  --
  -- applied_status_sys is the firmware's filter status echo, written on a
  -- single sys_clk edge (REG_APPLIED) and then held — identical timing
  -- profile to cycles_sys, so the same crossing is correct.
  ---------------------------------------------------------------------------
  cdc_filter_cfg_i : xpm_cdc_array_single
    generic map (
      DEST_SYNC_FF   => 2,
      INIT_SYNC_FF   => 0,
      SIM_ASSERT_CHK => 0,
      SRC_INPUT_REG  => 1,
      WIDTH          => 32
    )
    port map (
      src_clk  => fp_clk,
      src_in   => filter_cfg_i,
      dest_clk => sys_clk,
      dest_out => filter_cfg_sys
    );

  cdc_applied_i : xpm_cdc_array_single
    generic map (
      DEST_SYNC_FF   => 2,
      INIT_SYNC_FF   => 0,
      SIM_ASSERT_CHK => 0,
      SRC_INPUT_REG  => 1,
      WIDTH          => 32
    )
    port map (
      src_clk  => sys_clk,
      src_in   => applied_status_sys,
      dest_clk => fp_clk,
      dest_out => applied_status_o
    );

end architecture rtl;
