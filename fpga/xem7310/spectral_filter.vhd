-- spectral_filter.vhd — per-bin complex Q1.15 frequency-domain filter stage
-- Copyright (c) 2026 A P Nicholson , intothemist@gmail.com
-- SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
--
-- Sits between the forward and inverse xfft on the FFT → filter → IFFT
-- datapath.  For each frequency bin k it computes Y[k] = H[k] · X[k] (complex
-- Q1.15 multiply) and forwards Y[k] to the inverse xfft:
--
--   xfft_0 m_axis_data (X[k]) ─► spectral_filter ─► xfft_1 s_axis_data (Y[k])
--                                      ▲
--                          coeff BRAM Port B (H[k])
--
-- H[k] is the runtime-programmable mask in the coefficient BRAM (CPU writes via
-- fft_accel_load_coeffs).  Because xfft_0 is output_ordering=natural_order, the
-- output beat index IS the bin index k, so the coefficient address is just a
-- free-running beat counter (no digit-reversal).
--
-- ── Streaming model ─────────────────────────────────────────────────────────
-- A RIGID fixed-latency pipeline (latency = L, exposed as the LATENCY generic),
-- NOT a back-pressuring FIFO.  This matches how the existing single-xfft
-- pipeline already operates: in nonrealtime throttle mode with S2MM armed
-- before MM2S, the output sink holds TREADY high for the whole frame, so no
-- mid-frame back-pressure occurs and a rigid pipe never has to stall.  The
-- caller (xem7310_top.vhd) qualifies s_tvalid with the actual xfft_0 transfer
-- handshake (tvalid AND tready), so this stage advances exactly once per real
-- input beat and TVALID/TLAST are re-emitted delayed by exactly L — preserving
-- the "exactly N beats per N-point frame, TLAST on beat N-1" invariant
-- (ACCEL_ARCH.md §4.4) at the inverse-xfft boundary.
--
-- ── Latency (L) ─────────────────────────────────────────────────────────────
--   stage 1 : register X[k]; present coeff address = k; Port-B 1-cycle read
--             returns H[k] aligned with the registered X[k]
--   stage 2 : register the four 16×16 products (DSP48E1 multiply + MREG)
--   stage 3 : register the 33-bit sum/difference (DSP48E1 post-adder / CARRY4)
--   + cmpy_normalizer (NORM_LATENCY, default 1) reduces Q2.30 → Q1.15
-- Total L = 3 + NORM_LATENCY (default 4).  TVALID/TLAST are pipelined through
-- the SAME stages so they stay bit-aligned with the data they qualify.  The
-- multiply is split (products then sum) so no single combinational path runs
-- BRAM→DSP→adder→normalizer; a one-stage version failed timing at −4.376 ns.
--
-- The coefficient read address is presented combinationally from the bin
-- counter; coeff BRAM Port B has READ_LATENCY 1 (Register_PortB_Output=false),
-- so coeff_dout is valid one cycle after the address — exactly when X is at the
-- stage-1 register.  This keeps the BRAM read latency-compensated rather than
-- stalled (the §4.1 contract).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spectral_filter is
  generic (
    NBINS        : natural := 4096;  -- transform length (bin counter wrap)
    NORM_LATENCY : natural := 1      -- cmpy_normalizer pipeline depth
  );
  port (
    aclk        : in  std_logic;
    aresetn     : in  std_logic;    -- shared xfft aresetn (flushes this stage too)

    -- AXIS slave: forward-FFT output X[k], packed { im[31:16], re[15:0] } Q1.15.
    -- s_tvalid MUST be the qualified xfft_0 transfer (tvalid AND tready) so the
    -- bin counter advances exactly once per real beat.  This stage is always
    -- ready (rigid pipe), so it exposes no s_tready.
    s_tvalid    : in  std_logic;
    s_tlast     : in  std_logic;
    s_tdata     : in  std_logic_vector(31 downto 0);

    -- Coefficient BRAM Port B (read-only): drive the bin address, sample H[k].
    coeff_addr  : out std_logic_vector(11 downto 0);  -- 4096 bins → 12 bits
    coeff_dout  : in  std_logic_vector(31 downto 0);   -- H[k] { im, re } Q1.15

    -- AXIS master: filtered bin Y[k] = H[k]·X[k] for the inverse xfft.
    m_tvalid    : out std_logic;
    m_tlast     : out std_logic;
    m_tdata     : out std_logic_vector(31 downto 0);

    -- Saturation strobe (one beat per clamped output) — aggregated into the
    -- overflow readback so a coefficient pushing a bin past full scale is seen.
    m_sat       : out std_logic
  );
end entity spectral_filter;

architecture rtl of spectral_filter is

  -- ── Bin counter (coefficient address) ──────────────────────────────────────
  signal bin_cnt : unsigned(11 downto 0) := (others => '0');

  -- ── Stage-0 → stage-1 registers (align X with the 1-cycle coeff read) ──────
  signal x_re_s1   : signed(15 downto 0) := (others => '0');
  signal x_im_s1   : signed(15 downto 0) := (others => '0');
  signal valid_s1  : std_logic := '0';

  -- ── Pipelined complex multiply (timing fix — see header) ───────────────────
  -- Stage 2: four registered 16×16 = 32-bit products (map to DSP48E1 MREG).
  signal pp_rr, pp_ii, pp_ri, pp_ir : signed(31 downto 0) := (others => '0');
  signal valid_s2 : std_logic := '0';
  signal tlast_s2 : std_logic := '0';

  -- Stage 3: registered 33-bit sum/difference (the cmpy outputs, Q2.30).
  signal prod_re : std_logic_vector(32 downto 0) := (others => '0');
  signal prod_im : std_logic_vector(32 downto 0) := (others => '0');
  signal valid_s3 : std_logic := '0';
  signal tlast_s3 : std_logic := '0';

  component cmpy_normalizer is
    generic (
      PROD_WIDTH   : natural;
      FRAC_BITS    : natural;
      NORM_LATENCY : natural
    );
    port (
      aclk       : in  std_logic;
      aresetn    : in  std_logic;
      s_tvalid   : in  std_logic;
      s_tlast    : in  std_logic;
      s_tdata_re : in  std_logic_vector(32 downto 0);
      s_tdata_im : in  std_logic_vector(32 downto 0);
      m_tvalid   : out std_logic;
      m_tlast    : out std_logic;
      m_tdata    : out std_logic_vector(31 downto 0);
      m_sat      : out std_logic
    );
  end component;

  -- TLAST/TVALID travel with the SAME latency as the data through every
  -- pipeline stage (s1 multiply-input, s2 products, s3 sum, then the
  -- normalizer), so the beat the inverse xfft sees as "last" still marks bin
  -- N-1 — the exactly-N-beats invariant (ACCEL_ARCH §4.4).
  signal tlast_s1 : std_logic := '0';

begin

  -- ── Coefficient address: present the CURRENT input bin combinationally so
  -- the 1-cycle Port-B read returns H[k] when X[k] reaches the stage-1 reg. ──
  coeff_addr <= std_logic_vector(bin_cnt);

  process (aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        bin_cnt  <= (others => '0');
        valid_s1 <= '0';
        tlast_s1 <= '0';
        x_re_s1  <= (others => '0');
        x_im_s1  <= (others => '0');
      else
        -- Stage 0: latch the input beat and advance the bin counter on each
        -- real transfer.  Wrap on TLAST (defensive) or at NBINS-1.
        valid_s1 <= s_tvalid;
        tlast_s1 <= s_tvalid and s_tlast;
        if s_tvalid = '1' then
          x_re_s1 <= signed(s_tdata(15 downto 0));
          x_im_s1 <= signed(s_tdata(31 downto 16));
          if s_tlast = '1' or bin_cnt = to_unsigned(NBINS - 1, bin_cnt'length) then
            bin_cnt <= (others => '0');
          else
            bin_cnt <= bin_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ── Pipelined complex multiply  Y = H · X  (Q1.15 × Q1.15 → Q2.30) ─────────
  -- Split across two registered stages so the BRAM→DSP→adder→normalizer chain
  -- does not form one long combinational path (a single-stage version failed
  -- timing at −4.376 ns: 13 logic levels, 2 DSP + 8 CARRY4 in one cycle).
  --   Stage 2 (regs pp_*): four 16×16 products  Xr·Hr, Xi·Hi, Xr·Hi, Xi·Hr
  --                        — these map onto the DSP48E1 multiplier+MREG.
  --   Stage 3 (regs prod_*): the 33-bit combine  re = pp_rr − pp_ii,
  --                          im = pp_ri + pp_ir  (DSP48E1 post-adder / CARRY4).
  -- coeff_dout is H[k], aligned with the stage-1 X registers (1-cycle BRAM read).
  process (aclk)
    variable hr, hi : signed(15 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        pp_rr <= (others => '0'); pp_ii <= (others => '0');
        pp_ri <= (others => '0'); pp_ir <= (others => '0');
        valid_s2 <= '0'; tlast_s2 <= '0';
        prod_re <= (others => '0'); prod_im <= (others => '0');
        valid_s3 <= '0'; tlast_s3 <= '0';
      else
        -- Stage 2: register the four products.
        hr := signed(coeff_dout(15 downto 0));
        hi := signed(coeff_dout(31 downto 16));
        pp_rr <= x_re_s1 * hr;
        pp_ii <= x_im_s1 * hi;
        pp_ri <= x_re_s1 * hi;
        pp_ir <= x_im_s1 * hr;
        valid_s2 <= valid_s1;
        tlast_s2 <= tlast_s1;
        -- Stage 3: register the 33-bit sum/difference.
        prod_re <= std_logic_vector(resize(pp_rr, 33) - resize(pp_ii, 33));
        prod_im <= std_logic_vector(resize(pp_ri, 33) + resize(pp_ir, 33));
        valid_s3 <= valid_s2;
        tlast_s3 <= tlast_s2;
      end if;
    end if;
  end process;

  -- ── Q2.30 → Q1.15 round/saturate reduction (verified component) ────────────
  norm_i : cmpy_normalizer
    generic map (
      PROD_WIDTH   => 33,
      FRAC_BITS    => 15,
      NORM_LATENCY => NORM_LATENCY
    )
    port map (
      aclk       => aclk,
      aresetn    => aresetn,
      s_tvalid   => valid_s3,
      s_tlast    => tlast_s3,
      s_tdata_re => prod_re,
      s_tdata_im => prod_im,
      m_tvalid   => m_tvalid,
      m_tlast    => m_tlast,
      m_tdata    => m_tdata,
      m_sat      => m_sat
    );

end architecture rtl;
