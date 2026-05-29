-- Copyright (c) 2026 A P Nicholson , intothemist@gmail.com
-- SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
--
-- Line-buffered simulation UART receiver.
-- Accumulates characters and prints complete lines to the console.
-- Based on NEORV32 sim_uart_rx (BSD-3-Clause, Stephan Nolting).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity sim_uart_rx is
  generic (
    NAME : string;
    FCLK : real;
    BAUD : real
  );
  port (
    clk : in std_ulogic;
    rxd : in std_ulogic
  );
end entity sim_uart_rx;

architecture sim_uart_rx_rtl of sim_uart_rx is

  signal sync    : std_ulogic_vector(4 downto 0) := (others => '1');
  signal busy    : std_ulogic := '0';
  signal sreg    : std_ulogic_vector(8 downto 0) := (others => '0');
  signal baudcnt : real;
  signal bitcnt  : natural;

  constant baud_val_c : real := FCLK / BAUD;
  file file_out : text open write_mode is "neorv32_tb." & NAME & "_rx.out";

begin

  sim_receiver: process(clk)
    variable c       : integer;
    variable l       : line;
    variable console : line;
  begin
    if rising_edge(clk) then
      sync <= sync(3 downto 0) & rxd;

      if (busy = '0') then
        busy    <= '0';
        baudcnt <= round(0.5 * baud_val_c);
        bitcnt  <= 9;
        if (sync(4 downto 1) = "1100") then
          busy <= '1';
        end if;
      else
        if (baudcnt <= 0.0) then
          if (bitcnt = 1) then
            baudcnt <= round(0.5 * baud_val_c);
          else
            baudcnt <= round(baud_val_c);
          end if;

          if (bitcnt = 0) then
            busy <= '0';
            -- sreg(0) is the stop-bit sample; it must be '1' for a valid frame.
            if (sync(4) /= '1') then
              report NAME & ": framing error (stop bit sampled as 0 - baud-rate mismatch?)"
                severity warning;
            end if;
            c := to_integer(unsigned(sreg(8 downto 1)));

            if (c = 10) then
              if console /= null and console.all'length > 0 then
                report NAME & ": " & console.all severity note;
                deallocate(console);
              end if;
              writeline(file_out, l);
            elsif (c = 13) then
              null;
            else
              write(console, character'val(c));
              write(l, character'val(c));
            end if;

          else
            sreg   <= sync(4) & sreg(8 downto 1);
            bitcnt <= bitcnt - 1;
          end if;
        else
          baudcnt <= baudcnt - 1.0;
        end if;
      end if;
    end if;
  end process sim_receiver;

end architecture sim_uart_rx_rtl;
