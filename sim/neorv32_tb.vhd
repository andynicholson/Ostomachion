-- Ostomachion — NEORV32 GHDL testbench
-- Copyright (c) 2026 A P Nicholson , intothemist@gmail.com
-- SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0

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

  -- SPI signals
  signal spi_clk   : std_logic;
  signal spi_mosi  : std_logic;
  signal spi_miso  : std_logic;
  signal spi_csn   : std_logic_vector(7 downto 0);

  -- GPIO change monitor state
  signal gpio_prev       : std_logic_vector(7 downto 0) := (others => '0');
  signal gpio_toggle_cnt : natural := 0;

  -- SPI monitor state
  signal spi_clk_d   : std_logic := '0';
  signal csn_prev    : std_logic_vector(7 downto 0) := (others => '1');
  signal spi_bit_cnt : natural range 0 to 7 := 0;
  signal spi_shift   : std_logic_vector(7 downto 0) := (others => '0');

  -- TWI (I2C) open-drain bus
  -- Master drives: '0' = pull low, '1' = release (simulated pull-up -> '1')
  signal twi_sda_m : std_logic; -- master output (wrapper port)
  signal twi_scl_m : std_logic; -- master scl output
  signal twi_sda_s : std_logic := '1'; -- slave drives: '0' for ACK, '1' to release
  signal twi_sda   : std_logic; -- resolved bus ('0' wins; else '1' = pull-up high)
  signal twi_scl   : std_logic; -- SCL (only master drives)

  -- I2C slave model state machine
  -- Slave responds at 7-bit address 0x50
  -- Write: ACKs address + all data bytes, logs each
  -- Read:  ACKs address, returns I2C_RD_BYTE (0x5A) per byte;
  --        continues sending bytes as long as master sends ACK
  type i2c_sl_t is (SL_IDLE, SL_ADDR, SL_ACK_ADDR,
                    SL_WR_DATA, SL_ACK_WR,
                    SL_RD_DATA, SL_ACK_RD);
  signal i2c_sl_st  : i2c_sl_t := SL_IDLE;
  signal i2c_sl_bc  : natural range 0 to 8 := 0;  -- bit counter
  signal i2c_sl_sr  : std_logic_vector(7 downto 0) := (others => '0'); -- shift reg
  signal i2c_sl_rw  : std_logic := '0'; -- 0=write, 1=read
  signal i2c_sl_akf : natural range 0 to 1 := 0; -- ACK fall counter
  signal i2c_sl_rdc : natural range 0 to 7 := 0; -- read bit index (counts down)
  constant I2C_SLAVE_ADDR : std_logic_vector(6 downto 0) := "1010000"; -- 0x50
  constant I2C_RD_BYTE    : std_logic_vector(7 downto 0) := x"5A";

  -- Edge/condition detection registers (delayed bus values)
  signal scl_d : std_logic := '1';
  signal sda_d : std_logic := '1';

begin

  -- Open-drain bus: '0' wins; '1' = pull-up high when nobody is driving low
  twi_sda <= '0' when (twi_sda_m = '0' or twi_sda_s = '0') else '1';
  -- SCL driven only by master (no clock stretching)
  twi_scl <= twi_scl_m;

  -- SPI loopback: echo MOSI back as MISO
  spi_miso <= spi_mosi;

  -- Clock generator --------------------------------------------------------
  clk <= not clk after CLK_PERIOD / 2;

  -- Reset -----------------------------------------------------------------------
  reset_gen: process
  begin
    rstn <= '0';
    wait for 100 ns;
    rstn <= '1';
    report "[TB] Reset released." severity note;
    wait;
  end process;

  -- DUT instantiation ----------------------------------------------------------
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
    spi_csn_o   => spi_csn,
    twi_sda_o   => twi_sda_m,
    twi_sda_i   => twi_sda,
    twi_scl_o   => twi_scl_m,
    twi_scl_i   => twi_scl
  );

  -- UART RX monitor ------------------------------------------------------------
  uart_mon: entity work.sim_uart_rx
  generic map (
    NAME => "UART0",
    FCLK => 100.0e6,
    BAUD => 115200.0
  )
  port map (
    clk => std_ulogic(clk),
    rxd => std_ulogic(uart_tx)
  );

  -- GPIO change monitor --------------------------------------------------------
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

  -- SPI bus monitor ------------------------------------------------------------
  -- Samples MOSI on every rising SPI clock edge while any CS is active.
  -- Reports a complete byte immediately at each 8-bit boundary (not just on CS
  -- deassert), so multi-byte transfers under a single CS assertion are visible.
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

        -- CS assertion: reset byte accumulator for fresh transfer
        if csn_prev = x"FF" and csn_v /= x"FF" then
          spi_bit_cnt <= 0;
          spi_shift   <= (others => '0');
          report "[TB] SPI CS asserted" severity note;
        end if;

        -- CS deassert: warn if partial byte remains (misaligned transfer)
        if csn_prev /= x"FF" and csn_v = x"FF" then
          if spi_bit_cnt /= 0 then
            report "[TB] SPI CS deasserted with partial byte (" &
                   natural'image(spi_bit_cnt) & " bits)" severity warning;
          else
            report "[TB] SPI CS deasserted" severity note;
          end if;
        end if;

        -- Sample MOSI on rising SPI clock edge while CS is active
        if (csn_v /= x"FF") and spi_clk = '1' and spi_clk_d = '0' then
          if spi_bit_cnt < 7 then
            -- Accumulate bit, MSB-first
            spi_shift   <= spi_shift(6 downto 0) & spi_mosi;
            spi_bit_cnt <= spi_bit_cnt + 1;
          else
            -- 8th bit completes the byte: report immediately and reset
            report "[TB] SPI byte (MOSI): 0x" &
                   to_hstring(unsigned(spi_shift(6 downto 0) & spi_mosi))
              severity note;
            spi_shift   <= (others => '0');
            spi_bit_cnt <= 0;
          end if;
        end if;

        csn_prev <= csn_v;
      end if;
    end if;
  end process;

  -- I2C bus monitor + slave model at address 0x50 ------------------------------
  -- Detects START/STOP, ACKs the address, ACKs write data, returns I2C_RD_BYTE
  -- on reads.  Handles multi-byte writes and multi-byte reads: for reads, the
  -- slave continues sending I2C_RD_BYTE as long as the master sends ACK; it
  -- releases the bus when the master sends NACK (end of read).
  i2c_slave: process(clk)
    variable scl_rise  : boolean;
    variable scl_fall  : boolean;
    variable start_det : boolean;
    variable stop_det  : boolean;
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        twi_sda_s  <= '1';
        i2c_sl_st  <= SL_IDLE;
        i2c_sl_bc  <= 0;
        i2c_sl_sr  <= (others => '0');
        i2c_sl_rw  <= '0';
        i2c_sl_akf <= 0;
        i2c_sl_rdc <= 0;
        scl_d      <= '1';
        sda_d      <= '1';
      else
        -- Derive edge and condition flags from delayed values
        scl_rise  := (scl_d = '0' and twi_scl /= '0');
        scl_fall  := (scl_d /= '0' and twi_scl = '0');
        -- START: SDA falls while SCL high
        start_det := (sda_d /= '0' and twi_sda = '0' and twi_scl /= '0');
        -- STOP: SDA rises while SCL high
        stop_det  := (sda_d = '0' and twi_sda /= '0' and twi_scl /= '0');

        -- STOP has highest priority - resets slave from any state
        if stop_det then
          report "[TB] I2C STOP" severity note;
          twi_sda_s <= '1';
          i2c_sl_st <= SL_IDLE;

        -- START / REPEATED START
        elsif start_det then
          if i2c_sl_st = SL_IDLE then
            report "[TB] I2C START" severity note;
          else
            report "[TB] I2C RESTART" severity note;
            twi_sda_s <= '1';
          end if;
          i2c_sl_st <= SL_ADDR;
          i2c_sl_bc <= 0;
          i2c_sl_sr <= (others => '0');

        else
          case i2c_sl_st is

            -- ---------------------------------------------------------------
            when SL_IDLE => null;

            -- ---------------------------------------------------------------
            -- Collect 8 bits: 7-bit address + R/W on SCL rising edges
            when SL_ADDR =>
              if scl_rise then
                i2c_sl_sr <= i2c_sl_sr(6 downto 0) & twi_sda;
                if i2c_sl_bc = 7 then
                  i2c_sl_st  <= SL_ACK_ADDR;
                  i2c_sl_akf <= 0;
                else
                  i2c_sl_bc <= i2c_sl_bc + 1;
                end if;
              end if;

            -- ---------------------------------------------------------------
            -- ACK the address if it matches 0x50 (two-fall state machine):
            --   fall #0: drive '0' (ACK) or '1' (NACK)
            --   fall #1: release, transition to write or read phase
            when SL_ACK_ADDR =>
              if scl_fall then
                if i2c_sl_akf = 0 then
                  -- First fall: assert ACK or NACK
                  if i2c_sl_sr(7 downto 1) = I2C_SLAVE_ADDR then
                    twi_sda_s <= '0'; -- ACK
                    i2c_sl_rw <= i2c_sl_sr(0);
                    if i2c_sl_sr(0) = '0' then
                      report "[TB] I2C ACK addr 0x50 R/W=W" severity note;
                    else
                      report "[TB] I2C ACK addr 0x50 R/W=R" severity note;
                    end if;
                  else
                    twi_sda_s <= '1'; -- NACK (wrong address)
                    report "[TB] I2C NACK wrong addr 0x" &
                           to_hstring(unsigned(i2c_sl_sr(7 downto 1))) severity note;
                    i2c_sl_st <= SL_IDLE;
                  end if;
                  i2c_sl_akf <= 1;
                else
                  -- Second fall: release SDA, transition
                  i2c_sl_bc <= 0;
                  i2c_sl_sr <= (others => '0');
                  if i2c_sl_rw = '0' then
                    -- Write phase
                    twi_sda_s <= '1';
                    i2c_sl_st <= SL_WR_DATA;
                  else
                    -- Read phase: drive MSB immediately on this falling edge
                    twi_sda_s <= I2C_RD_BYTE(7);
                    i2c_sl_rdc <= 6; -- next bit to drive is index 6
                    i2c_sl_st  <= SL_RD_DATA;
                  end if;
                end if;
              end if;

            -- ---------------------------------------------------------------
            -- Receive 8 write-data bits on SCL rising edges, then ACK.
            -- Loops back to SL_WR_DATA after each byte so multi-byte writes
            -- are handled transparently; STOP from the master exits this loop.
            when SL_WR_DATA =>
              if scl_rise then
                i2c_sl_sr <= i2c_sl_sr(6 downto 0) & twi_sda;
                if i2c_sl_bc = 7 then
                  report "[TB] I2C WR data 0x" &
                         to_hstring(unsigned(i2c_sl_sr(6 downto 0) & twi_sda))
                    severity note;
                  i2c_sl_st  <= SL_ACK_WR;
                  i2c_sl_akf <= 0;
                else
                  i2c_sl_bc <= i2c_sl_bc + 1;
                end if;
              end if;

            -- ---------------------------------------------------------------
            -- ACK each written byte (two-fall):
            --   fall #0: drive '0'   fall #1: release, loop to SL_WR_DATA
            when SL_ACK_WR =>
              if scl_fall then
                if i2c_sl_akf = 0 then
                  twi_sda_s  <= '0'; -- ACK the write byte
                  i2c_sl_akf <= 1;
                else
                  twi_sda_s <= '1';
                  i2c_sl_bc <= 0;
                  i2c_sl_sr <= (others => '0');
                  i2c_sl_st <= SL_WR_DATA; -- expect more bytes (STOP overrides)
                end if;
              end if;

            -- ---------------------------------------------------------------
            -- Drive bits of I2C_RD_BYTE on SCL falling edges (MSB first).
            -- Bit 7 was placed on entry to this state (from SL_ACK_ADDR or
            -- after a master ACK in SL_ACK_RD); subsequent bits 6..0 here.
            when SL_RD_DATA =>
              if scl_fall then
                twi_sda_s <= I2C_RD_BYTE(i2c_sl_rdc);
                if i2c_sl_rdc = 0 then
                  i2c_sl_st  <= SL_ACK_RD;
                  i2c_sl_akf <= 0;
                else
                  i2c_sl_rdc <= i2c_sl_rdc - 1;
                end if;
              end if;

            -- ---------------------------------------------------------------
            -- Wait for master's ACK/NACK after each read byte:
            --   fall #0: release SDA so master can drive ACK or NACK
            --   rise #1: sample master ACK/NACK
            --     ACK  -> start driving the next byte (bit 7 on next fall)
            --     NACK -> go idle (master is done reading)
            when SL_ACK_RD =>
              if scl_fall and i2c_sl_akf = 0 then
                twi_sda_s  <= '1'; -- release for master to drive ACK/NACK
                i2c_sl_akf <= 1;
              elsif scl_rise and i2c_sl_akf = 1 then
                if twi_sda = '0' then
                  -- Master ACK: send another byte
                  report "[TB] I2C RD byte 0x" & to_hstring(unsigned(I2C_RD_BYTE)) &
                         " master=ACK (continuing)" severity note;
                  -- Drive bit 7 on the next SCL fall (SL_RD_DATA handles it)
                  i2c_sl_rdc <= 7;
                  i2c_sl_st  <= SL_RD_DATA;
                  twi_sda_s  <= '1'; -- SL_RD_DATA will drive on next fall
                else
                  -- Master NACK: read transaction complete
                  report "[TB] I2C RD byte 0x" & to_hstring(unsigned(I2C_RD_BYTE)) &
                         " master=NACK" severity note;
                  twi_sda_s <= '1';
                  i2c_sl_st <= SL_IDLE; -- STOP expected next
                end if;
              end if;

          end case;
        end if;

        -- Latch bus values for next-cycle edge detection
        scl_d <= twi_scl;
        sda_d <= twi_sda;
      end if;
    end if;
  end process;

  -- Simulation watchdog --------------------------------------------------------
  -- If GPIO pin 0 has not toggled at least once by 390 ms the firmware likely
  -- hung before reaching the LED blink loop.  Asserting failure here causes
  -- GHDL to exit with a non-zero status, which CI scripts can detect.
  watchdog: process
  begin
    wait for 390 ms;
    report "[TB] Watchdog: 390 ms elapsed; gpio_toggle_cnt=" &
           natural'image(gpio_toggle_cnt) severity note;
    if gpio_toggle_cnt < 1 then
      report "[TB] WATCHDOG: GPIO pin 0 never toggled - firmware may have hung!" severity failure;
    end if;
    wait;
  end process;

end architecture;
