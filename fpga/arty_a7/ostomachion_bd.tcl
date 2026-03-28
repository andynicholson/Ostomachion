## ostomachion_bd.tcl
## Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
##
## Vivado IP Integrator block design creation script.
## Sourced from build.tcl after all RTL sources have been added to sources_1.
##
## Architecture: the BD contains ONLY Xilinx IP (clocking, reset, AXI fabric,
## DMA, BRAM, xfft, AXI INTC).  NEORV32 and the XBUS-to-AXI4-Lite bridge
## remain in RTL (arty_a7_top.vhd).  The BD exposes:
##   s_axi_cpu      — AXI4-Lite slave input (from xbus_axi4lite_bridge master)
##   clk_o          — 100 MHz MMCM output (for neorv32_top and bridge)
##   periph_resetn_o— peripheral_aresetn (for neorv32_top rstn_i and bridge)
##   mext_irq_o     — single IRQ from AXI INTC (for neorv32_top mext_irq_i)
##
## Interrupt topology (v1.1 — AXI INTC, scalable to multiple accelerators):
##   axi_intc channel 0 ← AXI DMA mm2s_introut  (MM2S completion / error)
##   axi_intc channel 1 ← AXI DMA s2mm_introut  (S2MM completion / error)
##   axi_intc channel 2 ← xfft_0 overflow        (m_axis_status_tvalid)
##   axi_intc IRQ output  → NEORV32 mext_irq_i   (single combined line)
##
## The AXI INTC (PG099) replaces the prior xlconcat OR-tree, enabling clean
## per-channel disambiguation in the ISR (read INTC ISR, ACK via INTC IAR)
## and straightforward expansion to additional accelerators without complex
## heuristic detection in the driver.
##
## AXI INTC address: 0x40010000 (128 B AXI aperture — Vivado 2025.1 minimum)
##
## This avoids the long "create_bd_cell -type module -reference neorv32_top"
## elaboration step that was stalling Vivado batch mode.
##
## FFT is provided by the Xilinx xfft IP (PG109) — pipelined streaming,
## 4096-point, 16-bit fixed-point.
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
## reset input is tied low — MMCM locks on power-up; proc_sys_reset gates
## system reset release using the locked output.

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict {
    CONFIG.PRIM_IN_FREQ               {100.000}
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000}
    CONFIG.CLKOUT1_DRIVES             {BUFG}
    CONFIG.USE_LOCKED                 {true}
    CONFIG.USE_RESET                  {false}
    CONFIG.CLKIN1_JITTER_PS           {100.0}
} [get_bd_cells clk_wiz_0]

## ── 2. Utility constants ────────────────────────────────────────────────────
## const_zero: 1-bit 0 — tie-off for unused inputs
## const_one:  1-bit 1 — tie valid/ready high on streams with no back-pressure
## const_fft_cfg: 16-bit xfft config — FWD=1, scale all 12 stages (0x1FFF)

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero
set_property -dict {CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}} \
    [get_bd_cells const_zero]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one
set_property -dict {CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}} \
    [get_bd_cells const_one]

## xfft config: 16-bit tdata = {padding[3], SCHED_B[11:0], FWD_INV}
## SCHED_B[11:0] = 12 scale bits (one per stage), all 1 = divide-by-2 at every stage.
## 0x1FFF = 0001_1111_1111_1111: bits[12:1]=all-scaled, bit[0]=FWD.
## 4096-pt (12 stages), forward FFT, scale all stages: value = 0x1FFF = 8191
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_fft_cfg
set_property -dict {CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {8191}} \
    [get_bd_cells const_fft_cfg]

## ── 3. Reset: Processor System Reset ───────────────────────────────────────
## C_EXT_RESET_ACTIVE_LOW was removed in proc_sys_reset v5.0 (Vivado 2024+).
## Active-low polarity is set on the ext_reset_in port declaration below.
## interconnect_aresetn → AXI SmartConnect (released first per Xilinx req.)
## peripheral_aresetn[0] → all AXI data-path blocks and RTL wrapper.

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0
set_property -dict {
    CONFIG.C_AUX_RESET_HIGH {0}
} [get_bd_cells proc_sys_reset_0]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
               [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] \
               [get_bd_pins proc_sys_reset_0/dcm_locked]

## ── 4. AXI SmartConnect ─────────────────────────────────────────────────────
## 3 masters: CPU AXI slave port (S00), DMA MM2S (S01), DMA S2MM (S02)
## 4 slaves:  AXI DMA ctrl (M00), TX BRAM ctrl (M01), RX BRAM ctrl (M02),
##            AXI INTC    (M03, 0x40010000)

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc
set_property -dict {
    CONFIG.NUM_SI {3}
    CONFIG.NUM_MI {4}
} [get_bd_cells axi_smc]

## ── 5. AXI DMA — simple/register-direct mode, no scatter-gather ────────────
## Data width 32-bit, burst size 16 beats = 64 bytes per burst.

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

## ── 6. Xilinx FFT IP (xfft) — pipelined streaming, 4096-pt, 16-bit Q1.15 ────
## Architecture 1 = Pipelined Streaming: accepts one sample per clock.
## AXI-Stream widths:
##   s_axis_data_tdata   [31:0] = {XN_IM[15:0], XN_RE[15:0]}
##   m_axis_data_tdata   [31:0] = {XK_IM[15:0], XK_RE[15:0]} (scaled output)
##   s_axis_config_tdata [15:0] = {padding[3], SCHED_B[11:0], FWD_INV}
## Config is hardwired via const_fft_cfg (forward, scale all 12 stages).
## Output remains 16-bit per component because all 12 stages are scaled (÷2 each).

## xfft 9.1 in Vivado 2024+ uses component-level parameter names (not the old C_*
## model-parameter names).  Key parameters and their valid values:
##   transform_length          — FFT size as integer (4096 for 12-stage)
##   implementation_options    — "pipelined_streaming_io" → C_ARCH=1
##   input_width               — "16" for Q1.15 fixed-point
##   phase_factor_width        — "16"
##   data_format               — "fixed_point"
##   scaling_options           — "scaled" → explicit per-stage scale schedule
##   rounding_modes            — "truncation"
##   throttle_scheme           — "nonrealtime" (C_THROTTLE_SCHEME=1)
##   aclken                    — false
##   ovflo                     — true: enables m_axis_status stream (bit 0 = overflow)
##                                m_axis_status_tvalid fires once per frame on overflow.
##                                It is routed to irq_concat/In2 so the driver ISR can
##                                detect overflow without any additional AXI peripheral.

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
    CONFIG.ovflo                  {true}
} [get_bd_cells xfft_0]

## ── 7. Dual-port BRAM controllers + Block Memory Generators ─────────────────
## TX BRAM: CPU writes (AXI4-Lite single), DMA reads (AXI4-Full burst)
## RX BRAM: DMA writes (AXI4-Full burst), CPU reads (AXI4-Lite single)
## 16 KB each → 4096 × 32-bit words.

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

## Wire BRAM generators to their controllers
connect_bd_intf_net [get_bd_intf_pins tx_bram_ctrl/BRAM_PORTA] \
                    [get_bd_intf_pins tx_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins tx_bram_ctrl/BRAM_PORTB] \
                    [get_bd_intf_pins tx_bram/BRAM_PORTB]
connect_bd_intf_net [get_bd_intf_pins rx_bram_ctrl/BRAM_PORTA] \
                    [get_bd_intf_pins rx_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins rx_bram_ctrl/BRAM_PORTB] \
                    [get_bd_intf_pins rx_bram/BRAM_PORTB]

## ── 8. AXI Interrupt Controller ───────────────────────────────────────────
## Replaces the prior xlconcat OR-tree with a Xilinx AXI INTC (PG099).
## This provides clean per-channel interrupt source identification via the
## INTC ISR register, enabling scalable addition of future accelerators.
##
## Channel mapping:
##   channel 0 ← AXI DMA mm2s_introut  (MM2S completion / error)
##   channel 1 ← AXI DMA s2mm_introut  (S2MM completion / error)
##   channel 2 ← xfft_0 m_axis_status_tvalid (overflow, one pulse per frame)
##
## IRQ output → mext_irq_o → NEORV32 mext_irq_i (single MEI line)
##
## INTC register map (PG099; low 32 B used, 128 B AXI decode for Vivado 2025+):
##   0x00 ISR  Interrupt Status Register   (bit N = channel N pending)
##   0x04 IPR  Interrupt Pending Register  (ISR & IER)
##   0x08 IER  Interrupt Enable Register
##   0x0C IAR  Interrupt Acknowledge Reg   (write 1 to clear ISR bit)
##   0x1C MER  Master Enable Register      (bit0=ME, bit1=HIE)
##
## Driver init: IER=0x07 (enable ch0..2), MER=0x03 (ME=1, HIE=1)
## Driver ISR:  read ISR, handle each bit, write IAR to acknowledge
##
## Vivado 2025.1+ axi_intc: C_NUM_INTR_INPUTS is read-only (inferred from the
## width of `intr`); per-bit slice connections intr(0:0) are not valid.  Use
## xlconcat to merge three 1-bit sources into intr[2:0] (same channel order).

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

## Always-ready: consume the xfft status stream tdata immediately.
## The INTC sees the tvalid pulse; no need to inspect tdata.
connect_bd_net [get_bd_pins const_one/dout] \
               [get_bd_pins xfft_0/m_axis_status_tready]

## ── 9. AXI interconnect wiring ──────────────────────────────────────────────

## Masters → SmartConnect
## S00: external CPU AXI slave port (connected below after port creation)
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S]  \
                    [get_bd_intf_pins axi_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM]  \
                    [get_bd_intf_pins axi_smc/S02_AXI]

## SmartConnect → Slaves
## M00 → AXI DMA control (0x40000000, 64 B)
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] \
                    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
## M01 → TX BRAM controller (0x41000000, 16 KB)
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] \
                    [get_bd_intf_pins tx_bram_ctrl/S_AXI]
## M02 → RX BRAM controller (0x41004000, 16 KB)
connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] \
                    [get_bd_intf_pins rx_bram_ctrl/S_AXI]
## M03 → AXI INTC (0x40010000, 128 B)
connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] \
                    [get_bd_intf_pins axi_intc_0/s_axi]

## ── 10. AXI-Stream: DMA ↔ xfft ──────────────────────────────────────────────
## DMA MM2S output → xfft input data stream
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                    [get_bd_intf_pins xfft_0/s_axis_data]
## xfft output data stream → DMA S2MM input
connect_bd_intf_net [get_bd_intf_pins xfft_0/m_axis_data] \
                    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

## xfft config stream: hardwired forward FFT, scale all 12 stages
connect_bd_net [get_bd_pins const_fft_cfg/dout] \
               [get_bd_pins xfft_0/s_axis_config_tdata]
connect_bd_net [get_bd_pins const_one/dout] \
               [get_bd_pins xfft_0/s_axis_config_tvalid]

## xfft status stream: tready is tied high (see section 8 above).
## tvalid is routed to irq_concat_intc/In2 → axi_intc intr[2] (see section 8).

## ── 11. Clock distribution ───────────────────────────────────────────────────
set aclk [get_bd_pins clk_wiz_0/clk_out1]

## AXI DMA stream clocks (m_axis_mm2s_aclk, s_axis_s2mm_aclk) were removed
## in AXI DMA 7.1 for Vivado 2024+; they are now unified with the AXI master
## clocks and do not need to be connected separately.
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

## ── 12. Reset distribution ───────────────────────────────────────────────────
set interconnect_rstn [get_bd_pins proc_sys_reset_0/interconnect_aresetn]
set peripheral_rstn   [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

## Interconnect reset → SmartConnect only
connect_bd_net $interconnect_rstn [get_bd_pins axi_smc/aresetn]

## Peripheral reset → all AXI data-path blocks (including xfft)
foreach pin {
    axi_dma_0/axi_resetn
    tx_bram_ctrl/s_axi_aresetn
    rx_bram_ctrl/s_axi_aresetn
    xfft_0/aresetn
    axi_intc_0/s_axi_aresetn
} {
    connect_bd_net $peripheral_rstn [get_bd_pins $pin]
}

## ── 13. External ports (BD boundary to arty_a7_top RTL) ─────────────────────

## Clock / reset inputs from board
create_bd_port -dir I -type clk sys_clk
create_bd_port -dir I -type rst ck_rst
set_property CONFIG.ASSOCIATED_RESET {ck_rst}    [get_bd_ports sys_clk]
set_property CONFIG.POLARITY         {ACTIVE_LOW} [get_bd_ports ck_rst]

connect_bd_net [get_bd_ports sys_clk] [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_ports ck_rst]  [get_bd_pins proc_sys_reset_0/ext_reset_in]

## Clock output to RTL (neorv32_top + xbus_bridge)
## Associate with s_axi_cpu so IPI knows the AXI slave is clocked by clk_o.
create_bd_port -dir O -type clk clk_o
connect_bd_net [get_bd_ports clk_o] $aclk
set_property CONFIG.ASSOCIATED_BUSIF {s_axi_cpu} [get_bd_ports clk_o]

## Peripheral reset output to RTL (neorv32_top rstn_i + xbus_bridge aresetn)
create_bd_port -dir O periph_resetn_o
connect_bd_net [get_bd_ports periph_resetn_o] $peripheral_rstn

## Single combined IRQ from AXI INTC to RTL (neorv32_top mext_irq_i)
## The INTC irq output is a 1-bit signal; any pending channel asserts it.
create_bd_port -dir O mext_irq_o
connect_bd_net [get_bd_ports mext_irq_o] [get_bd_pins axi_intc_0/irq]

## AXI4-Lite slave input from RTL (xbus_axi4lite_bridge master output)
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi_cpu
set_property -dict {
    CONFIG.PROTOCOL  {AXI4LITE}
    CONFIG.ADDR_WIDTH {32}
    CONFIG.DATA_WIDTH {32}
} [get_bd_intf_ports s_axi_cpu]

connect_bd_intf_net [get_bd_intf_ports s_axi_cpu] [get_bd_intf_pins axi_smc/S00_AXI]

## ── 14. Address map ───────────────────────────────────────────────────────────
## Vivado 2024+ requires assign_bd_address with -target_address_space and
## explicit -offset / -range instead of post-assign set_property.
##
## CPU view (s_axi_cpu address space):
##   0x40000000  AXI DMA control   64 B
##   0x41000000  TX BRAM           16 KB
##   0x41004000  RX BRAM           16 KB
##
## DMA engine address spaces (must match the addresses programmed into the
## DMA source/destination registers by the Zephyr driver):
##   MM2S reads TX BRAM at 0x41000000
##   S2MM writes RX BRAM at 0x41004000

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

## AXI INTC: 0x40010000, 128 B (Vivado 2025+ enforces min range; regs use low 32 B)
assign_bd_address \
    -offset 0x40010000 -range 0x00000080 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs axi_intc_0/S_AXI/Reg] -force

assign_bd_address \
    -offset 0x41000000 -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs tx_bram_ctrl/S_AXI/Mem0] -force

## Exclude segments not reachable by MM2S (DMA control reg and RX BRAM)
exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg]
exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs rx_bram_ctrl/S_AXI/Mem0]

assign_bd_address \
    -offset 0x41004000 -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs rx_bram_ctrl/S_AXI/Mem0] -force

## Exclude segments not reachable by S2MM (DMA control reg and TX BRAM)
exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg]
exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs tx_bram_ctrl/S_AXI/Mem0]

## ── 15. Validate and generate wrapper ───────────────────────────────────────
validate_bd_design
save_bd_design

make_wrapper -files [get_files ostomachion_bd.bd] -top

## In Vivado 2024+, generated BD output goes to the .gen directory (not .srcs).
## Use the actual path returned by make_wrapper rather than a hardcoded glob.
set wrapper_file "$build_dir/vivado_project/ostomachion_arty_a7.gen/sources_1/bd/ostomachion_bd/hdl/ostomachion_bd_wrapper.vhd"

if {[file exists $wrapper_file]} {
    add_files -norecurse $wrapper_file
    ## TOP remains arty_a7_top (set in build.tcl).
    puts "INFO: BD wrapper added: $wrapper_file"
} else {
    ## Fallback: search both .gen and .srcs for the wrapper
    set wrapper_file [lindex [glob -nocomplain \
        "$build_dir/vivado_project/ostomachion_arty_a7.*/sources_1/bd/ostomachion_bd/hdl/ostomachion_bd_wrapper.vhd"] 0]
    if {$wrapper_file ne ""} {
        add_files -norecurse $wrapper_file
        puts "INFO: BD wrapper added (fallback path): $wrapper_file"
    } else {
        error "ostomachion_bd.tcl: BD wrapper not found — make_wrapper may have failed"
    }
}
