library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity neorv32_tb is
end entity;

architecture sim of neorv32_tb is

  constant CLK_PERIOD : time := 10 ns; -- 100 MHz

  signal clk      : std_logic := '0';
  signal rstn     : std_logic := '0';
  signal gpio     : std_logic_vector(7 downto 0);
  signal uart_tx  : std_logic;
  signal uart_rx  : std_logic := '1';

  signal gpio_prev       : std_logic_vector(7 downto 0) := (others => '0');
  signal gpio_toggle_cnt : natural := 0;

begin

  -- Clock generator --------------------------------------------------------
  clk <= not clk after CLK_PERIOD / 2;

  -- Reset control (simulation duration governed by --stop-time) -------------
  reset_gen: process
  begin
    rstn <= '0';
    wait for 100 ns;
    rstn <= '1';
    report "[TB] Reset released." severity note;
    wait;
  end process;

  -- DUT instantiation ------------------------------------------------------
  dut: entity work.neorv32_wrapper
  port map (
    clk_i       => clk,
    rstn_i      => rstn,
    gpio_o      => gpio,
    uart0_txd_o => uart_tx,
    uart0_rxd_i => uart_rx
  );

  -- UART RX monitor --------------------------------------------------------
  -- Captures serial TX from the DUT on the physical line.
  -- Active when firmware uses real baud-rate mode (e.g. Zephyr).
  -- In sim-mode the UART core prints directly to the console,
  -- so this monitor will be quiet — that is expected.
  uart_mon: entity work.sim_uart_rx
  generic map (
    NAME => "UART0",
    FCLK => 100.0e6,
    BAUD => 19200.0
  )
  port map (
    clk => std_ulogic(clk),
    rxd => std_ulogic(uart_tx)
  );

  -- GPIO change monitor ----------------------------------------------------
  gpio_monitor: process(clk)
  begin
    if rising_edge(clk) then
      if rstn = '1' then
        if gpio /= gpio_prev then
          report "[TB] GPIO changed: 0x" &
                 to_hstring(unsigned(gpio)) &
                 " at " & time'image(now) severity note;
          if gpio(0) /= gpio_prev(0) then
            gpio_toggle_cnt <= gpio_toggle_cnt + 1;
          end if;
        end if;
        gpio_prev <= gpio;
      end if;
    end if;
  end process;

end architecture;
