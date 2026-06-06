-- cmpy_normalizer.vhd — Q2.30 → Q1.15 round/saturate for the spectral filter
-- Copyright (c) 2026 A P Nicholson , intothemist@gmail.com
-- SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
--
-- Reduces the Xilinx Complex Multiplier (cmpy) product back to the Q1.15
-- format the inverse xfft expects, on the FFT → filter → IFFT datapath:
--
--   xfft_0 m_axis_data (X[k], Q1.15)  ─┐
--   coeff BRAM Port B  (H[k], Q1.15)  ─┴─► cmpy ──► (re,im ≈ Q2.30) ──► THIS ──► xfft_1
--
-- Multiplying two Q1.15 values yields a Q2.30 result (the cmpy carries it in a
-- wider field, typically 33 bits per component with full-precision output).
-- We arithmetic-shift right by 15 with round-half-up (+2^14 before the shift)
-- and saturate to signed 16-bit so the result is Q1.15 again.
--
-- The reduction policy is IDENTICAL, bit-for-bit, to the firmware reference
-- ostomachion::filter::sat_round_q15() in filter_mask.hpp, so the on-CPU
-- mask-composition math predicts the on-FPGA result.
--
-- AXI-Stream contract:
--   * Pure pass-through of TVALID/TLAST with a fixed, registered latency of
--     NORM_LATENCY cycles (default 1).  TLAST/TVALID MUST be carried through a
--     matching delay in the top-level glue so the beat that the inverse xfft
--     sees as "last" still aligns with bin N-1 (the exactly-N-beats invariant,
--     ACCEL_ARCH.md §4.4).
--   * No internal back-pressure: this stage is always ready and its TVALID
--     simply follows the (delayed) input TVALID.  The cmpy is configured with
--     FlowControl=Blocking so S2MM TREADY back-pressures the whole chain
--     upstream of the multiplier; this combinational+register reducer never
--     stalls, so it does not need a TREADY of its own on the data it forwards.
--
-- Generic A_WIDTH/B_WIDTH document the source Q1.15 width (15 fractional bits);
-- PROD_WIDTH is the per-component width of the cmpy product field.  The shift
-- amount is the number of fractional bits to drop = 15 (FRAC_BITS).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cmpy_normalizer is
  generic (
    PROD_WIDTH   : natural := 33;  -- per-component width of the cmpy product
    FRAC_BITS    : natural := 15;  -- Q1.15 fractional bits to drop on reduction
    NORM_LATENCY : natural := 1    -- registered pipeline depth (>=1)
  );
  port (
    aclk      : in  std_logic;
    aresetn   : in  std_logic;
    -- Input: cmpy product stream (re/im in the low PROD_WIDTH bits, Q2.30).
    s_tvalid  : in  std_logic;
    s_tlast   : in  std_logic;
    s_tdata_re : in std_logic_vector(PROD_WIDTH-1 downto 0);
    s_tdata_im : in std_logic_vector(PROD_WIDTH-1 downto 0);
    -- Output: packed Q1.15 complex word { im[31:16], re[15:0] } for xfft_1.
    m_tvalid  : out std_logic;
    m_tlast   : out std_logic;
    m_tdata   : out std_logic_vector(31 downto 0);
    -- Saturation strobe: high for one m_tvalid beat whose re or im clamped to
    -- the Q1.15 rail (the product exceeded ±1.0).  Aggregated into the overflow
    -- readback so a coefficient that pushes a bin past full scale is observable.
    m_sat     : out std_logic
  );
end entity cmpy_normalizer;

architecture rtl of cmpy_normalizer is

  -- Round-half-up then arithmetic >>FRAC_BITS, saturate to signed 16-bit.
  -- Mirrors filter_mask.hpp sat_round_q15(): r = (prod + (1<<14)) >> 15, clamp.
  function sat_round_q15 (prod : signed) return signed is
    constant BIAS : signed(prod'range) :=
      to_signed(2 ** (FRAC_BITS - 1), prod'length);
    variable shifted : signed(prod'range);
  begin
    shifted := shift_right(prod + BIAS, FRAC_BITS);
    if shifted > to_signed(32767, shifted'length) then
      return to_signed(32767, 16);
    elsif shifted < to_signed(-32768, shifted'length) then
      return to_signed(-32768, 16);
    else
      return resize(shifted, 16);
    end if;
  end function;

  -- True when sat_round_q15(prod) would clamp to a rail (re or im out of range).
  function would_saturate (prod : signed) return boolean is
    constant BIAS : signed(prod'range) :=
      to_signed(2 ** (FRAC_BITS - 1), prod'length);
    variable shifted : signed(prod'range);
  begin
    shifted := shift_right(prod + BIAS, FRAC_BITS);
    return (shifted > to_signed(32767, shifted'length)) or
           (shifted < to_signed(-32768, shifted'length));
  end function;

  type re_pipe_t is array (0 to NORM_LATENCY-1) of signed(15 downto 0);
  type im_pipe_t is array (0 to NORM_LATENCY-1) of signed(15 downto 0);
  signal re_pipe : re_pipe_t := (others => (others => '0'));
  signal im_pipe : im_pipe_t := (others => (others => '0'));

  signal valid_pipe : std_logic_vector(NORM_LATENCY-1 downto 0) := (others => '0');
  signal last_pipe  : std_logic_vector(NORM_LATENCY-1 downto 0) := (others => '0');
  signal sat_pipe   : std_logic_vector(NORM_LATENCY-1 downto 0) := (others => '0');

begin

  process (aclk)
    variable re_q15 : signed(15 downto 0);
    variable im_q15 : signed(15 downto 0);
    variable sat    : std_logic;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        re_pipe    <= (others => (others => '0'));
        im_pipe    <= (others => (others => '0'));
        valid_pipe <= (others => '0');
        last_pipe  <= (others => '0');
        sat_pipe   <= (others => '0');
      else
        -- Stage 0: reduce the current product and flag saturation.
        re_q15 := sat_round_q15(signed(s_tdata_re));
        im_q15 := sat_round_q15(signed(s_tdata_im));
        if would_saturate(signed(s_tdata_re)) or
           would_saturate(signed(s_tdata_im)) then
          sat := '1';
        else
          sat := '0';
        end if;
        re_pipe(0)    <= re_q15;
        im_pipe(0)    <= im_q15;
        valid_pipe(0) <= s_tvalid;
        last_pipe(0)  <= s_tlast;
        sat_pipe(0)   <= s_tvalid and sat;
        -- Stages 1..NORM_LATENCY-1: shift the pipeline (only when >1 deep).
        for i in 1 to NORM_LATENCY-1 loop
          re_pipe(i)    <= re_pipe(i-1);
          im_pipe(i)    <= im_pipe(i-1);
          valid_pipe(i) <= valid_pipe(i-1);
          last_pipe(i)  <= last_pipe(i-1);
          sat_pipe(i)   <= sat_pipe(i-1);
        end loop;
      end if;
    end if;
  end process;

  m_tdata  <= std_logic_vector(im_pipe(NORM_LATENCY-1)) &
              std_logic_vector(re_pipe(NORM_LATENCY-1));
  m_tvalid <= valid_pipe(NORM_LATENCY-1);
  m_tlast  <= last_pipe(NORM_LATENCY-1);
  m_sat    <= sat_pipe(NORM_LATENCY-1);

end architecture rtl;
