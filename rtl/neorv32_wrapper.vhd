library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_wrapper is
  port (
    clk_i       : in  std_logic;
    rstn_i      : in  std_logic;
    gpio_o      : out std_logic_vector(7 downto 0);
    uart0_txd_o : out std_logic;
    uart0_rxd_i : in  std_logic := '1';
    spi_clk_o   : out std_logic;
    spi_dat_o   : out std_logic;
    spi_dat_i   : in  std_logic := '0';
    spi_csn_o   : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of neorv32_wrapper is
  signal gpio_full   : std_ulogic_vector(31 downto 0);
  signal uart_tx     : std_ulogic;
  signal spi_clk_int : std_ulogic;
  signal spi_dat_out : std_ulogic;
  signal spi_csn_int : std_ulogic_vector(7 downto 0);
begin
  gpio_o       <= std_logic_vector(gpio_full(7 downto 0));
  uart0_txd_o  <= std_logic(uart_tx);
  spi_clk_o    <= std_logic(spi_clk_int);
  spi_dat_o    <= std_logic(spi_dat_out);
  spi_csn_o    <= std_logic_vector(spi_csn_int);

  neorv32_inst: entity neorv32.neorv32_top
  generic map (
    CLOCK_FREQUENCY   => 100_000_000,
    BOOT_MODE_SELECT  => 2,
    RISCV_ISA_C       => true,
    RISCV_ISA_M       => true,
    RISCV_ISA_Zicntr  => true,
    IMEM_EN           => true,
    IMEM_SIZE         => 65536,
    DMEM_EN           => true,
    DMEM_SIZE         => 65536,
    IO_CLINT_EN       => true,
    IO_GPIO_NUM       => 8,
    IO_UART0_EN       => true,
    IO_SPI_EN         => true,
    IO_SPI_FIFO       => 4
  )
  port map (
    clk_i       => std_ulogic(clk_i),
    rstn_i      => std_ulogic(rstn_i),
    gpio_o      => gpio_full,
    uart0_txd_o => uart_tx,
    uart0_rxd_i => std_ulogic(uart0_rxd_i),
    spi_clk_o   => spi_clk_int,
    spi_dat_o   => spi_dat_out,
    spi_dat_i   => std_ulogic(spi_dat_i),
    spi_csn_o   => spi_csn_int
  );
end architecture;
