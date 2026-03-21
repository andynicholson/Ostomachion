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

  signal spi_clk   : std_logic;
  signal spi_mosi  : std_logic;
  signal spi_miso  : std_logic;
  signal spi_csn   : std_logic_vector(7 downto 0);

  signal gpio_prev       : std_logic_vector(7 downto 0) := (others => '0');
  signal gpio_toggle_cnt : natural := 0;

  -- SPI monitor: shift MOSI on SPI clock rising edges while CS active
  signal spi_clk_d   : std_logic := '0';
  signal csn_prev    : std_logic_vector(7 downto 0) := (others => '1');
  signal spi_bit_cnt : natural range 0 to 8 := 0;
  signal spi_shift   : std_logic_vector(7 downto 0) := (others => '0');

begin

  -- MOSI -> MISO loopback (peripheral would drive MISO; here we echo MOSI)
  spi_miso <= spi_mosi;

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
    uart0_rxd_i => uart_rx,
    spi_clk_o   => spi_clk,
    spi_dat_o   => spi_mosi,
    spi_dat_i   => spi_miso,
    spi_csn_o   => spi_csn
  );

  -- UART RX monitor --------------------------------------------------------
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

  -- SPI bus monitor: sample MOSI on rising SPI clock while any CS low -------
  spi_monitor: process(clk)
    variable csn_v : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        spi_clk_d   <= '0';
        csn_prev    <= (others => '1');
        spi_bit_cnt <= 0;
        spi_shift   <= (others => '0');
      else
        spi_clk_d <= spi_clk;
        csn_v     := spi_csn;

        -- New CS assertion: clear shift register
        if csn_prev = x"FF" and csn_v /= x"FF" then
          spi_bit_cnt <= 0;
          spi_shift   <= (others => '0');
        end if;

        -- CS released: report one transferred byte
        if csn_prev /= x"FF" and csn_v = x"FF" and spi_bit_cnt = 8 then
          report "[TB] SPI byte (MOSI): 0x" & to_hstring(unsigned(spi_shift))
            severity note;
        end if;

        if (csn_v /= x"FF") and spi_clk = '1' and spi_clk_d = '0' then
          if spi_bit_cnt < 8 then
            spi_shift   <= spi_shift(6 downto 0) & spi_mosi;
            spi_bit_cnt <= spi_bit_cnt + 1;
          end if;
        end if;

        csn_prev <= csn_v;
      end if;
    end if;
  end process;

end architecture;
