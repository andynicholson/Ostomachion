## Ostomachion — Arty A7 pin constraints
## Target: xc7a35tcsg324-1 (Digilent Arty A7-35T)
## All I/O: LVCMOS33 unless noted

## ==========================================================================
## Clock
## ==========================================================================
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

## ==========================================================================
## Reset (active-low pushbutton BTN RESET)
## ==========================================================================
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports ck_rst]

## ==========================================================================
## USB-UART (FTDI FT2232HQ channel B — micro-USB connector)
## ==========================================================================
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_txd_out]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33} [get_ports uart_rxd_in]

## ==========================================================================
## LEDs LD0..LD3 (green)
## ==========================================================================
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

## ==========================================================================
## SPI master — Pmod JA (2×6 header, top row pins 1–4)
##   JA-1 (G13) = SCK
##   JA-2 (B11) = MOSI
##   JA-3 (A11) = MISO
##   JA-4 (D12) = CS0
## ==========================================================================
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports spi_clk_o]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports spi_dat_o]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports spi_dat_i]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports spi_csn_o]

## ==========================================================================
## I2C / TWI (open-drain) — Pmod JB (2×6 header, top row pins 1–2)
##   JB-1 (E15) = SDA
##   JB-2 (E16) = SCL
## NOTE: External 4.7 kΩ pull-ups to 3V3 are required on the Pmod connector.
## ==========================================================================
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS33} [get_ports twi_sda]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports twi_scl]

## ==========================================================================
## JTAG on-chip debugger — Pmod JC (2×6 header, top row pins 1–4)
##   JC-1 (K17) = TCK
##   JC-2 (M18) = TDI
##   JC-3 (N17) = TDO
##   JC-4 (P18) = TMS
## ==========================================================================
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports jtag_tck_i]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports jtag_tdi_i]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports jtag_tdo_o]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports jtag_tms_i]

## ==========================================================================
## Bitstream / configuration
## ==========================================================================
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
