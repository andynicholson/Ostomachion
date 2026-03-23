-- xbus_axi4lite_bridge.vhd
-- Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
--
-- Bridges NEORV32 XBUS (registered Wishbone-compatible) to AXI4-Lite.
--
-- Protocol mapping:
--   STB+CYC assertion with WE=1  → AXI4-Lite write  (AW + W channels, then B)
--   STB+CYC assertion with WE=0  → AXI4-Lite read   (AR channel, then R)
--   BVALID / RVALID               → ACK back to XBUS
--   One outstanding transaction at a time: new STB is ignored while busy.
--
-- Reset: aresetn active-low, driven by proc_sys_reset_0/peripheral_aresetn.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xbus_axi4lite_bridge is
  port (
    -- Clock / reset (AXI domain)
    aclk     : in  std_logic;
    aresetn  : in  std_logic;

    -- XBUS (Wishbone-classic registered-feedback subset)
    xbus_adr_i : in  std_logic_vector(31 downto 0);
    xbus_dat_i : in  std_logic_vector(31 downto 0);  -- write data from CPU
    xbus_dat_o : out std_logic_vector(31 downto 0);  -- read data to CPU
    xbus_we_i  : in  std_logic;
    xbus_sel_i : in  std_logic_vector(3 downto 0);
    xbus_stb_i : in  std_logic;
    xbus_cyc_i : in  std_logic;
    xbus_ack_o : out std_logic;
    xbus_err_o : out std_logic;

    -- AXI4-Lite master
    -- Write address channel
    m_axi_awaddr  : out std_logic_vector(31 downto 0);
    m_axi_awprot  : out std_logic_vector(2 downto 0);
    m_axi_awvalid : out std_logic;
    m_axi_awready : in  std_logic;
    -- Write data channel
    m_axi_wdata   : out std_logic_vector(31 downto 0);
    m_axi_wstrb   : out std_logic_vector(3 downto 0);
    m_axi_wvalid  : out std_logic;
    m_axi_wready  : in  std_logic;
    -- Write response channel
    m_axi_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_bvalid  : in  std_logic;
    m_axi_bready  : out std_logic;
    -- Read address channel
    m_axi_araddr  : out std_logic_vector(31 downto 0);
    m_axi_arprot  : out std_logic_vector(2 downto 0);
    m_axi_arvalid : out std_logic;
    m_axi_arready : in  std_logic;
    -- Read data channel
    m_axi_rdata   : in  std_logic_vector(31 downto 0);
    m_axi_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_rvalid  : in  std_logic;
    m_axi_rready  : out std_logic
  );
end entity xbus_axi4lite_bridge;

architecture rtl of xbus_axi4lite_bridge is

  type state_t is (IDLE, WR_ADDR_DATA, WR_RESP, RD_ADDR, RD_DATA);
  signal state : state_t := IDLE;

  -- Registered capture of XBUS request
  signal adr_r  : std_logic_vector(31 downto 0) := (others => '0');
  signal dat_r  : std_logic_vector(31 downto 0) := (others => '0');
  signal sel_r  : std_logic_vector(3 downto 0)  := (others => '0');

  -- Internal valid/ready registers
  signal awvalid_r : std_logic := '0';
  signal wvalid_r  : std_logic := '0';
  signal arvalid_r : std_logic := '0';
  signal bready_r  : std_logic := '0';
  signal rready_r  : std_logic := '0';

  signal ack_r     : std_logic := '0';
  signal err_r     : std_logic := '0';
  signal rdata_r   : std_logic_vector(31 downto 0) := (others => '0');

  -- AXI response watchdog: 256-cycle counter; if a slave does not respond
  -- within 256 cycles we abort with an XBUS error to avoid a CPU lockup.
  signal timeout_cnt : unsigned(8 downto 0) := (others => '0');
  constant TIMEOUT_LIMIT : unsigned(8 downto 0) := to_unsigned(256, 9);

begin

  -- Output assignments
  m_axi_awaddr  <= adr_r;
  m_axi_awprot  <= "000";   -- unprivileged, non-secure, data access
  m_axi_awvalid <= awvalid_r;
  m_axi_wdata   <= dat_r;
  m_axi_wstrb   <= sel_r;
  m_axi_wvalid  <= wvalid_r;
  m_axi_bready  <= bready_r;
  m_axi_araddr  <= adr_r;
  m_axi_arprot  <= "000";
  m_axi_arvalid <= arvalid_r;
  m_axi_rready  <= rready_r;
  xbus_ack_o    <= ack_r;
  xbus_err_o    <= err_r;
  xbus_dat_o    <= rdata_r;

  fsm : process(aclk)
  begin
    if rising_edge(aclk) then
      ack_r <= '0';
      err_r <= '0';

      if aresetn = '0' then
        state       <= IDLE;
        awvalid_r   <= '0';
        wvalid_r    <= '0';
        arvalid_r   <= '0';
        bready_r    <= '0';
        rready_r    <= '0';
        adr_r       <= (others => '0');
        dat_r       <= (others => '0');
        sel_r       <= (others => '0');
        timeout_cnt <= (others => '0');
      else
        case state is

          -- ── IDLE: wait for a new XBUS cycle ───────────────────────────────
          when IDLE =>
            timeout_cnt <= (others => '0');
            if xbus_stb_i = '1' and xbus_cyc_i = '1' then
              adr_r <= xbus_adr_i;
              dat_r <= xbus_dat_i;
              sel_r <= xbus_sel_i;
              if xbus_we_i = '1' then
                awvalid_r <= '1';
                wvalid_r  <= '1';
                state     <= WR_ADDR_DATA;
              else
                arvalid_r <= '1';
                state     <= RD_ADDR;
              end if;
            end if;

          -- ── WR_ADDR_DATA: issue AW and W simultaneously ───────────────────
          -- Both channels must be accepted before proceeding.
          when WR_ADDR_DATA =>
            if m_axi_awready = '1' then
              awvalid_r <= '0';
            end if;
            if m_axi_wready = '1' then
              wvalid_r <= '0';
            end if;
            -- Proceed once both have been accepted (or already clear)
            if (awvalid_r = '0' or m_axi_awready = '1') and
               (wvalid_r  = '0' or m_axi_wready  = '1') then
              awvalid_r   <= '0';
              wvalid_r    <= '0';
              bready_r    <= '1';
              timeout_cnt <= (others => '0');
              state       <= WR_RESP;
            end if;

          -- ── WR_RESP: wait for B channel ───────────────────────────────────
          -- Watchdog: abort after 256 cycles with no BVALID to prevent CPU hang.
          when WR_RESP =>
            if m_axi_bvalid = '1' then
              bready_r    <= '0';
              timeout_cnt <= (others => '0');
              ack_r       <= '1';
              -- Map SLVERR/DECERR to XBUS error
              if m_axi_bresp /= "00" then
                err_r <= '1';
              end if;
              state <= IDLE;
            elsif timeout_cnt = TIMEOUT_LIMIT then
              bready_r    <= '0';
              timeout_cnt <= (others => '0');
              err_r       <= '1';
              ack_r       <= '1';
              state       <= IDLE;
            else
              timeout_cnt <= timeout_cnt + 1;
            end if;

          -- ── RD_ADDR: issue AR ─────────────────────────────────────────────
          when RD_ADDR =>
            if m_axi_arready = '1' then
              arvalid_r   <= '0';
              rready_r    <= '1';
              timeout_cnt <= (others => '0');
              state       <= RD_DATA;
            end if;

          -- ── RD_DATA: wait for R channel ───────────────────────────────────
          -- Watchdog: abort after 256 cycles with no RVALID to prevent CPU hang.
          when RD_DATA =>
            if m_axi_rvalid = '1' then
              rready_r    <= '0';
              timeout_cnt <= (others => '0');
              rdata_r     <= m_axi_rdata;
              ack_r       <= '1';
              if m_axi_rresp /= "00" then
                err_r <= '1';
              end if;
              state <= IDLE;
            elsif timeout_cnt = TIMEOUT_LIMIT then
              rready_r    <= '0';
              timeout_cnt <= (others => '0');
              err_r       <= '1';
              ack_r       <= '1';
              state       <= IDLE;
            else
              timeout_cnt <= timeout_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
