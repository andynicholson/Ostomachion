-------------------------------------------------------------------------------
-- fft_beat_counter
--
-- Passive observer on the xfft m_axis_data AXIS interface.  Counts every
-- (tvalid AND tready) handshake and exposes:
--
--   pre_first_tlast_beats  Latched beat count at the FIRST tlast assertion
--                          after each aresetn rising edge.  This is the
--                          definitive answer to "how many output beats does
--                          xfft emit for the very first frame after reset?"
--                          PG109 says N; the off-by-one workaround assumed
--                          N+1.  This counter settles it.
--
--   beats_in_last_frame    Beat count between the previous tlast and the
--                          current tlast.  Reflects steady-state behaviour
--                          for the most recent frame (the first frame is
--                          captured by pre_first_tlast_beats above).
--
--   tlast_count            Number of tlast assertions since reset.
--                          Wraps at 2^8.  Useful to confirm that the
--                          observed counts came from a fresh frame.
--
-- All outputs are registered and hold their last value until aresetn pulses
-- low again.  No clock-domain crossing is performed here; the FrontPanel
-- WireOut path samples these in its own okClk domain after they have
-- stabilised (they only change on aclk-side events tlast / aresetn).
--
-- Resource cost: ~50 flops + one 13-bit adder.  Synthesizable on any 7-series
-- target with no special primitives.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fft_beat_counter is
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    -- Tap of xfft m_axis_data (passive)
    m_tvalid : in std_logic;
    m_tready : in std_logic;
    m_tlast  : in std_logic;

    -- Latched diagnostic outputs (stable between reset events)
    pre_first_tlast_beats : out std_logic_vector(15 downto 0);
    beats_in_last_frame   : out std_logic_vector(15 downto 0);
    tlast_count           : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of fft_beat_counter is
  signal beat_ctr        : unsigned(15 downto 0) := (others => '0');
  signal first_seen      : std_logic := '0';
  signal first_latch     : unsigned(15 downto 0) := (others => '0');
  signal last_latch      : unsigned(15 downto 0) := (others => '0');
  signal tlast_ctr       : unsigned(7 downto 0)  := (others => '0');
begin

  process (aclk)
    variable beat_fired : boolean;
    variable tlast_fired : boolean;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        beat_ctr    <= (others => '0');
        first_seen  <= '0';
        first_latch <= (others => '0');
        last_latch  <= (others => '0');
        tlast_ctr   <= (others => '0');
      else
        beat_fired  := (m_tvalid = '1' and m_tready = '1');
        tlast_fired := beat_fired and (m_tlast = '1');

        if beat_fired then
          beat_ctr <= beat_ctr + 1;
        end if;

        if tlast_fired then
          tlast_ctr <= tlast_ctr + 1;

          -- Capture per-frame count (including this final beat)
          last_latch <= beat_ctr + 1;

          -- Capture first-frame count only once per aresetn cycle
          if first_seen = '0' then
            first_latch <= beat_ctr + 1;
            first_seen  <= '1';
          end if;

          -- Reset beat counter for next frame
          beat_ctr <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  pre_first_tlast_beats <= std_logic_vector(first_latch);
  beats_in_last_frame   <= std_logic_vector(last_latch);
  tlast_count           <= std_logic_vector(tlast_ctr);

end architecture;
