## ostomachion_bd.tcl  (XEM7310-A200 variant)
## Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
##
## Vivado IP Integrator block design creation script.
## Sourced from build.tcl after all RTL sources have been added to sources_1.
##
## Architecture: the BD contains ONLY Xilinx IP (clocking, reset, AXI fabric,
## DMA, BRAM, xfft, AXI INTC).  NEORV32 and the XBUS-to-AXI4-Lite bridge
## remain in RTL (xem7310_top.vhd).  The BD exposes:
##   s_axi_cpu      — AXI4-Lite slave input (from xbus_axi4lite_bridge master)
##   clk_o          — 100 MHz MMCM output (for neorv32_top and bridge)
##   periph_resetn_o— peripheral_aresetn (for neorv32_top rstn_i and bridge)
##   mext_irq_o     — single IRQ from AXI INTC (for neorv32_top mext_irq_i)
##
## Clock: The XEM7310-A200 200 MHz LVDS oscillator is converted to
## single-ended by an IBUFDS in xem7310_top.vhd.  This BD receives the
## unbuffered 200 MHz single-ended clock and uses the Clocking Wizard
## (PRIM_SOURCE=No_buffer) to generate the 100 MHz system clock.
##
## Interrupt topology:
##   axi_intc channel 0 ← AXI DMA mm2s_introut
##   axi_intc channel 1 ← AXI DMA s2mm_introut
##   axi_intc channel 2 ← xfft_0 overflow (m_axis_status_tvalid)
##   axi_intc IRQ output  → NEORV32 mext_irq_i
##
## AXI INTC address: 0x40010000
##
## Resulting block design name: ostomachion_bd
## BD wrapper: ostomachion_bd_wrapper (VHDL, auto-generated)

## ---------------------------------------------------------------------------
## Expect $build_dir to be set by the calling script (build.tcl)
## ---------------------------------------------------------------------------
if {![info exists build_dir]} {
    error "ostomachion_bd.tcl: build_dir not set — source from build.tcl"
}

create_bd_design "ostomachion_bd"

## ── 1. Clocking: Clocking Wizard (MMCM) ────────────────────────────────────
## Input: 200 MHz single-ended (IBUFDS output from xem7310_top.vhd).
## PRIM_SOURCE=No_buffer prevents the wizard from adding an internal BUFG,
## since the IBUFDS in the top-level already provides the clock buffer.
## Output: 100 MHz BUFG (system clock for NEORV32 and all AXI peripherals).

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict {
    CONFIG.PRIM_IN_FREQ               {200.000}
    CONFIG.PRIM_SOURCE                {No_buffer}
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000}
    CONFIG.CLKOUT1_DRIVES             {BUFG}
    CONFIG.USE_LOCKED                 {true}
    CONFIG.USE_RESET                  {false}
    CONFIG.CLKIN1_JITTER_PS           {50.0}
} [get_bd_cells clk_wiz_0]

## ── 2. Utility constants ────────────────────────────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero
set_property -dict {CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}} \
    [get_bd_cells const_zero]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one
set_property -dict {CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}} \
    [get_bd_cells const_one]

## xfft config: 16-bit — FWD=1, scale all 12 stages (0x1FFF = 8191)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_fft_cfg
set_property -dict {CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {8191}} \
    [get_bd_cells const_fft_cfg]

## ── 3. Reset: Processor System Reset ───────────────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0
set_property -dict {
    CONFIG.C_AUX_RESET_HIGH {0}
} [get_bd_cells proc_sys_reset_0]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
               [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] \
               [get_bd_pins proc_sys_reset_0/dcm_locked]

## ── 4. AXI SmartConnect ─────────────────────────────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc
set_property -dict {
    CONFIG.NUM_SI {3}
    CONFIG.NUM_MI {4}
} [get_bd_cells axi_smc]

## ── 5. AXI DMA ──────────────────────────────────────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict {
    CONFIG.c_include_sg              {0}
    CONFIG.c_sg_include_stscntrl_strm {0}
    CONFIG.c_m_axi_mm2s_data_width   {32}
    CONFIG.c_m_axi_s2mm_data_width   {32}
    CONFIG.c_mm2s_burst_size         {16}
    CONFIG.c_s2mm_burst_size         {16}
    CONFIG.c_include_mm2s            {1}
    CONFIG.c_include_s2mm            {1}
} [get_bd_cells axi_dma_0]

## ── 6. Xilinx FFT IP (xfft) — pipelined streaming, 4096-pt, 16-bit Q1.15 ──
create_bd_cell -type ip -vlnv xilinx.com:ip:xfft:9.1 xfft_0
set_property -dict {
    CONFIG.transform_length       {4096}
    CONFIG.implementation_options {pipelined_streaming_io}
    CONFIG.input_width            {16}
    CONFIG.phase_factor_width     {16}
    CONFIG.data_format            {fixed_point}
    CONFIG.scaling_options        {scaled}
    CONFIG.rounding_modes         {truncation}
    CONFIG.throttle_scheme        {nonrealtime}
    CONFIG.aclken                 {false}
    CONFIG.aresetn                {true}
    CONFIG.ovflo                  {true}
} [get_bd_cells xfft_0]

## ── 7. BRAM controllers + Block Memory Generators ───────────────────────────
foreach name {tx_bram_ctrl rx_bram_ctrl} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 $name
    set_property -dict {
        CONFIG.SINGLE_PORT_BRAM {0}
        CONFIG.DATA_WIDTH       {32}
    } [get_bd_cells $name]
}

foreach name {tx_bram rx_bram} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 $name
    set_property -dict {
        CONFIG.Memory_Type        {True_Dual_Port_RAM}
        CONFIG.Write_Width_A      {32}
        CONFIG.Write_Depth_A      {4096}
        CONFIG.Write_Width_B      {32}
        CONFIG.Enable_B           {Use_ENB_Pin}
        CONFIG.Register_PortA_Output_of_Memory_Primitives {true}
        CONFIG.Register_PortB_Output_of_Memory_Primitives {true}
    } [get_bd_cells $name]
}

connect_bd_intf_net [get_bd_intf_pins tx_bram_ctrl/BRAM_PORTA] \
                    [get_bd_intf_pins tx_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins tx_bram_ctrl/BRAM_PORTB] \
                    [get_bd_intf_pins tx_bram/BRAM_PORTB]
connect_bd_intf_net [get_bd_intf_pins rx_bram_ctrl/BRAM_PORTA] \
                    [get_bd_intf_pins rx_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins rx_bram_ctrl/BRAM_PORTB] \
                    [get_bd_intf_pins rx_bram/BRAM_PORTB]

## ── 8. AXI Interrupt Controller ─────────────────────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 irq_concat_intc
set_property -dict {CONFIG.NUM_PORTS {3}} [get_bd_cells irq_concat_intc]

connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] \
               [get_bd_pins irq_concat_intc/In0]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] \
               [get_bd_pins irq_concat_intc/In1]
connect_bd_net [get_bd_pins xfft_0/m_axis_status_tvalid] \
               [get_bd_pins irq_concat_intc/In2]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_0
set_property -dict {
    CONFIG.C_HAS_FAST     {0}
    CONFIG.C_KIND_OF_INTR {0x00000000}
} [get_bd_cells axi_intc_0]

connect_bd_net [get_bd_pins irq_concat_intc/dout] [get_bd_pins axi_intc_0/intr]

connect_bd_net [get_bd_pins const_one/dout] \
               [get_bd_pins xfft_0/m_axis_status_tready]

## ── 9. AXI interconnect wiring ──────────────────────────────────────────────
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S]  \
                    [get_bd_intf_pins axi_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM]  \
                    [get_bd_intf_pins axi_smc/S02_AXI]

connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] \
                    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] \
                    [get_bd_intf_pins tx_bram_ctrl/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] \
                    [get_bd_intf_pins rx_bram_ctrl/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] \
                    [get_bd_intf_pins axi_intc_0/s_axi]

## ── 10. AXI-Stream: DMA ↔ xfft ─────────────────────────────────────────────
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                    [get_bd_intf_pins xfft_0/s_axis_data]
connect_bd_intf_net [get_bd_intf_pins xfft_0/m_axis_data] \
                    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

connect_bd_net [get_bd_pins const_fft_cfg/dout] \
               [get_bd_pins xfft_0/s_axis_config_tdata]
connect_bd_net [get_bd_pins const_one/dout] \
               [get_bd_pins xfft_0/s_axis_config_tvalid]

## ── 11. Clock distribution ──────────────────────────────────────────────────
set aclk [get_bd_pins clk_wiz_0/clk_out1]

foreach pin {
    axi_smc/aclk
    axi_dma_0/m_axi_mm2s_aclk
    axi_dma_0/m_axi_s2mm_aclk
    axi_dma_0/s_axi_lite_aclk
    tx_bram_ctrl/s_axi_aclk
    rx_bram_ctrl/s_axi_aclk
    xfft_0/aclk
    axi_intc_0/s_axi_aclk
} {
    connect_bd_net $aclk [get_bd_pins $pin]
}

## ── 12. Reset distribution ──────────────────────────────────────────────────
set interconnect_rstn [get_bd_pins proc_sys_reset_0/interconnect_aresetn]
set peripheral_rstn   [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

connect_bd_net $interconnect_rstn [get_bd_pins axi_smc/aresetn]

foreach pin {
    axi_dma_0/axi_resetn
    tx_bram_ctrl/s_axi_aresetn
    rx_bram_ctrl/s_axi_aresetn
    xfft_0/aresetn
    axi_intc_0/s_axi_aresetn
} {
    connect_bd_net $peripheral_rstn [get_bd_pins $pin]
}

## ── 13. External ports (BD boundary to xem7310_top RTL) ─────────────────────
create_bd_port -dir I -type clk -freq_hz 200000000 sys_clk
create_bd_port -dir I -type rst ck_rst
set_property CONFIG.ASSOCIATED_RESET {ck_rst}    [get_bd_ports sys_clk]
set_property CONFIG.POLARITY         {ACTIVE_LOW} [get_bd_ports ck_rst]

connect_bd_net [get_bd_ports sys_clk] [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_ports ck_rst]  [get_bd_pins proc_sys_reset_0/ext_reset_in]

create_bd_port -dir O -type clk clk_o
connect_bd_net [get_bd_ports clk_o] $aclk

create_bd_port -dir O periph_resetn_o
connect_bd_net [get_bd_ports periph_resetn_o] $peripheral_rstn

create_bd_port -dir O mext_irq_o
connect_bd_net [get_bd_ports mext_irq_o] [get_bd_pins axi_intc_0/irq]

create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi_cpu
set_property -dict {
    CONFIG.PROTOCOL  {AXI4LITE}
    CONFIG.ADDR_WIDTH {32}
    CONFIG.DATA_WIDTH {32}
} [get_bd_intf_ports s_axi_cpu]

connect_bd_intf_net [get_bd_intf_ports s_axi_cpu] [get_bd_intf_pins axi_smc/S00_AXI]

set_property CONFIG.ASSOCIATED_BUSIF {s_axi_cpu} [get_bd_ports clk_o]

## ── 14. Address map ─────────────────────────────────────────────────────────
assign_bd_address \
    -offset 0x40000000 -range 0x00000080 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg] -force

assign_bd_address \
    -offset 0x41000000 -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs tx_bram_ctrl/S_AXI/Mem0] -force

assign_bd_address \
    -offset 0x41004000 -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs rx_bram_ctrl/S_AXI/Mem0] -force

assign_bd_address \
    -offset 0x40010000 -range 0x00000080 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs axi_intc_0/S_AXI/Reg] -force

assign_bd_address \
    -offset 0x41000000 -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs tx_bram_ctrl/S_AXI/Mem0] -force

exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg]
exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs rx_bram_ctrl/S_AXI/Mem0]
exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs axi_intc_0/S_AXI/Reg]

assign_bd_address \
    -offset 0x41004000 -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs rx_bram_ctrl/S_AXI/Mem0] -force

exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg]
exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs tx_bram_ctrl/S_AXI/Mem0]
exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs axi_intc_0/S_AXI/Reg]

## ── 15. Validate and generate wrapper ───────────────────────────────────────
validate_bd_design
save_bd_design

make_wrapper -files [get_files ostomachion_bd.bd] -top

set wrapper_file "$build_dir/vivado_project/ostomachion_xem7310.gen/sources_1/bd/ostomachion_bd/hdl/ostomachion_bd_wrapper.vhd"

if {[file exists $wrapper_file]} {
    add_files -norecurse $wrapper_file
    puts "INFO: BD wrapper added: $wrapper_file"
} else {
    set wrapper_file [lindex [glob -nocomplain \
        "$build_dir/vivado_project/ostomachion_xem7310.*/sources_1/bd/ostomachion_bd/hdl/ostomachion_bd_wrapper.vhd"] 0]
    if {$wrapper_file ne ""} {
        add_files -norecurse $wrapper_file
        puts "INFO: BD wrapper added (fallback path): $wrapper_file"
    } else {
        error "ostomachion_bd.tcl: BD wrapper not found — make_wrapper may have failed"
    }
}
