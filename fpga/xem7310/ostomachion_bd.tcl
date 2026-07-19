## ostomachion_bd.tcl  (XEM7310-A200 variant)
## Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
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
##   axi_intc channel 2 ← xfft_0 frame-done pulse (m_axis_status_tvalid)
##   axi_intc IRQ output  → NEORV32 mext_irq_i
##
## Overflow path (not via INTC): xfft m_axis_status_tdata[0] is sliced out,
## latched in xem7310_top.vhd (cleared by the per-transform xfft aresetn pulse),
## and read back by the CPU through the AXI GPIO input channel (GPIO2_DATA 0x08).
##
## AXI INTC address: 0x40010000
## AXI GPIO  address: 0x40020000  (xfft per-transform pipeline reset + overflow in)
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

## xfft config: 16-bit — FWD=1, all 6 radix-4 super-stages scaled ÷4 each.
## The pipelined streaming xfft (C_ARCH=3) for a 4096-point FFT uses 6 radix-4
## super-stages (not 12 radix-2).  C_S_AXIS_CONFIG_TDATA_WIDTH = 16:
##   1 bit FWD_INV + 2 bits/stage × 6 stages = 13 bits, rounded to 16.
## Each radix-4 butterfly multiplies by 4 per stage, so 6 stages give gain 4^6 = 4096.
## SCALE_SCH "10" per stage (÷4) cancels the butterfly gain: (÷4)^6 = ÷4096.
## Encoding: bit 0 = FWD_INV=1; bits[2N:2N-1] = SCALE_SCH[N] for stage N=1..6.
##   0b 0001 0101 0101 0101 = 0x1555 = 5461
##
## output_ordering=natural_order: Without this, the pipelined radix-4 pipeline
## outputs samples in base-4 digit-reversed order (N=4096=4^6 digit-reversal maps
## bin k → 4^5*d0 + 4^4*d1 + ... where d_i are base-4 digits of k).  Empirically:
## fft sine 8 gave peak at bin 512=digit_reverse(8) instead of bin 8.  Setting
## natural_order adds a hardware commutator to produce sequentially-ordered output.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_fft_cfg
set_property -dict {CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {5461}} \
    [get_bd_cells const_fft_cfg]

## Inverse-FFT config word for xfft_1 (the IFFT stage of FFT → filter → IFFT).
##   bit 0     = FWD_INV = 0  → INVERSE transform
##   bits[2N:2N-1] = SCALE_SCH[N] = "10" (÷4) per radix-4 super-stage, ×6 = ÷4096
## Word = 0b 0001 0101 0101 0100 = 0x1554 = 5460.
##
## Scaling rationale (the factor-of-N trap):  the forward stage (0x1555) already
## applies 1/N, computing X[k] = (1/N)·Σ x[n]·e^{-j2πnk/N}.  A true inverse DFT
## needs a TOTAL 1/N across the pair, and the forward has already spent it — so
## the inverse must run UNSCALED (0x0000, no per-stage ÷4) for a unity round trip
## y[n] = x[n] on an all-pass mask.  The previous ÷N-scaled inverse (0x1554) gave
## y[n] = (1/N)·x[n] — attenuated by 1/4096 (~72 dB), which made the filtered
## output ~0.0005 FS and pass/stop bands incomparable on the host demo's
## amplitude axes.  HIL confirmed the attenuation is the inverse xfft's own ÷N
## (downstream of the mask), so it must be removed HERE, not compensated earlier.
##
## Overflow note: an unscaled inverse lets internal IFFT magnitudes grow up to
## ~N, so a full-scale broadband spectrum can overflow.  For the filtered
## (band-limited) and modest-amplitude signals this datapath targets, the
## reconstructed magnitude stays bounded; any excursion saturates and is flagged
## on the aggregated overflow readback (GPIO2 bit1 / WireOut).  Reduce toward a
## partial-scaling word if loud broadband inputs are expected.
## Word = 0b 0000 0000 0000 0000 = 0x0000 = 0 (FWD_INV=0, all stages unscaled).
## See REVIEW.md and ACCEL_ARCH.md §3 / §7.1 for the full gain budget.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_ifft_cfg
set_property -dict {CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {0}} \
    [get_bd_cells const_ifft_cfg]

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
    CONFIG.NUM_MI {6}
} [get_bd_cells axi_smc]
## NUM_MI 5 → 6: M05 fans out to the new filter coefficient BRAM controller
## (CPU-only slave; excluded from both DMA address spaces below).

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
    CONFIG.c_sg_length_width         {23}
} [get_bd_cells axi_dma_0]

## ── 6. Xilinx FFT IP (xfft) — pipelined streaming, 4096-pt, 16-bit Q1.15 ──
## throttle_scheme=nonrealtime: xfft asserts s_axis_data_tready=1 immediately
## after reset when the pipeline is empty, breaking the realtime-mode deadlock
## where tready only toggles at the start of a data frame (after the DMA has
## already started) and DMA MM2S waits for tready before sending the first beat.
## In nonrealtime mode the output side (m_axis_data) has TREADY from DMA S2MM;
## starting S2MM before MM2S in firmware ensures the xfft output can always drain.
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
    CONFIG.output_ordering        {natural_order}
    CONFIG.aclken                 {false}
    CONFIG.aresetn                {true}
    CONFIG.ovflo                  {true}
} [get_bd_cells xfft_0]

## ── 6b. Inverse FFT (xfft_1) — IFFT stage of FFT → filter → IFFT ────────────
## Identical configuration to xfft_0 except the transform direction is set per
## frame by the inverse config word (const_ifft_cfg = 0x0000, FWD_INV=0, unscaled) driven
## on s_axis_config below.  natural_order output means xfft_1 emits y[n] in
## sequential time order so it lands in RX BRAM 1:1 (out[i] = BRAM[i]) exactly
## like the forward path does today — the driver read loop is unchanged.  Shares
## the same aresetn net as xfft_0 (built in the reset section), so one firmware
## GPIO reset pulse flushes BOTH transform pipelines and the filter between them.
create_bd_cell -type ip -vlnv xilinx.com:ip:xfft:9.1 xfft_1
set_property -dict {
    CONFIG.transform_length       {4096}
    CONFIG.implementation_options {pipelined_streaming_io}
    CONFIG.input_width            {16}
    CONFIG.phase_factor_width     {16}
    CONFIG.data_format            {fixed_point}
    CONFIG.scaling_options        {scaled}
    CONFIG.rounding_modes         {truncation}
    CONFIG.throttle_scheme        {nonrealtime}
    CONFIG.output_ordering        {natural_order}
    CONFIG.aclken                 {false}
    CONFIG.aresetn                {true}
    CONFIG.ovflo                  {true}
} [get_bd_cells xfft_1]

## ── 7. BRAM controllers + Block Memory Generators ───────────────────────────
## Single-port mode: AXI BRAM controller serialises all reads and writes
## through BRAM_PORTA only.  This prevents the SmartConnect from issuing a
## CPU read on Port B concurrently with a DMA write on Port A, which caused
## stale reads when the SmartConnect returned early BRESP to the DMA before
## the write had reached the BRAM fabric.
##
## Read-latency contract (PG078 §1.3 / §4.1):
##   The AXI BRAM Controller's READ_LATENCY parameter must EXACTLY match the
##   total clock-cycle latency from BRAM address-valid to data-valid.  When
##   READ_LATENCY is set to its default of 1, PG078 forbids enabling the
##   blk_mem_gen "Register Port A Output of Memory Primitives" (and Core)
##   options — those each add one extra latency cycle.  A mismatch causes the
##   controller to sample the BRAM data port one cycle too early, returning
##   the previously-addressed word on every CPU-side read (a 1-word off-by-
##   one shift) — the same symptom regardless of where it surfaces.
##   We keep the strict 1-cycle BRAM (no primitive/core output registers) so
##   the default READ_LATENCY=1 matches exactly; timing closes comfortably at
##   100 MHz on Artix-7 with WNS > 0.5 ns on the BRAM datapath.
##   Empirically confirmed via fft_beat_counter (WireOut 0x22) showing xfft
##   emits exactly N output beats per N-point frame and the resulting Y[i]
##   lands at BRAM[i] with no offset.
foreach name {tx_bram_ctrl rx_bram_ctrl} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 $name
    set_property -dict {
        CONFIG.SINGLE_PORT_BRAM {1}
        CONFIG.DATA_WIDTH       {32}
    } [get_bd_cells $name]
}

## TX BRAM: 8192 words (32 KB) — CPU writes N=4096 samples, DMA MM2S reads them.
## RX BRAM: 8192 words (32 KB) — DMA S2MM writes N=4096 output samples.
## Both BRAMs use depth 8192 (power-of-2, 32 KB) so address ranges are
## identical and the AXI SmartConnect alignment constraint (range must equal
## depth×4) is met.  Words N..8191 are unused padding.
##
## Register_PortA_Output_of_Memory_Primitives = false: 1-cycle BRAM read
## latency, matching the AXI BRAM Controller default READ_LATENCY=1 above.
## See the latency contract note on the controller above for the full
## rationale.
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 tx_bram
set_property -dict {
    CONFIG.Memory_Type        {Single_Port_RAM}
    CONFIG.Write_Width_A      {32}
    CONFIG.Write_Depth_A      {8192}
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false}
} [get_bd_cells tx_bram]

create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 rx_bram
set_property -dict {
    CONFIG.Memory_Type        {Single_Port_RAM}
    CONFIG.Write_Width_A      {32}
    CONFIG.Write_Depth_A      {8192}
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false}
} [get_bd_cells rx_bram]

connect_bd_intf_net [get_bd_intf_pins tx_bram_ctrl/BRAM_PORTA] \
                    [get_bd_intf_pins tx_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins rx_bram_ctrl/BRAM_PORTA] \
                    [get_bd_intf_pins rx_bram/BRAM_PORTA]

## ── 7b. Filter coefficient BRAM (per-bin complex Q1.15) ─────────────────────
## Holds the 4096-entry filter mask H[k] = {im[31:16], re[15:0]} the spectral
## filter applies to each FFT bin before the inverse transform.  Port A is the
## CPU write/read-back path (fft_accel_load_coeffs); Port B is the fabric read
## the spectral_filter uses during a transform.
##
## TRUE dual-port — the SANCTIONED exception to the single-port rule (§4.2).
## tx/rx BRAM are single-port to avoid the concurrent DMA-write / CPU-read
## stale-read hazard.  The coeff BRAM is dual-port because the two ports never
## touch the same address concurrently: the CPU writes coefficients on Port A
## ONLY under the driver mutex while no transform runs, and the spectral_filter
## reads on Port B ONLY during a transform.  Both ports keep
## Register_Port?_Output_of_Memory_Primitives=false so the AXI BRAM Controller's
## default READ_LATENCY=1 matches on Port A and the Port-B fabric read has the
## strict 1-cycle latency spectral_filter.vhd is built around (§4.1).
##
## Depth 4096 × 32 b = 16 KB = 0x4000 (power-of-two), so the AXI SmartConnect
## alignment constraint (range == depth × 4) is met with no padding — unlike the
## tx/rx BRAMs, which pad to 8192 for a 32 KB window.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 coeff_bram_ctrl
set_property -dict {
    CONFIG.SINGLE_PORT_BRAM {1}
    CONFIG.DATA_WIDTH       {32}
} [get_bd_cells coeff_bram_ctrl]

create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 coeff_bram
set_property -dict {
    CONFIG.Memory_Type        {True_Dual_Port_RAM}
    CONFIG.Write_Width_A      {32}
    CONFIG.Write_Depth_A      {4096}
    CONFIG.Write_Width_B      {32}
    CONFIG.Enable_B           {Always_Enabled}
    CONFIG.Use_RSTB_Pin       {false}
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false}
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false}
} [get_bd_cells coeff_bram]

## Port A: AXI BRAM controller (CPU coefficient writes / read-back).
connect_bd_intf_net [get_bd_intf_pins coeff_bram_ctrl/BRAM_PORTA] \
                    [get_bd_intf_pins coeff_bram/BRAM_PORTA]

## Port B: expose the native BRAM Port B as an external BD interface port so the
## bin counter + read address live in top-level RTL (architecture rule: the BD
## holds only Xilinx IP; the spectral_filter glue is in xem7310_top.vhd).  Port
## B's clock is tied to aclk in the clock-distribution section below.
make_bd_intf_pins_external [get_bd_intf_pins coeff_bram/BRAM_PORTB]
set_property name coeff_bram_portb [get_bd_intf_ports BRAM_PORTB_0]

## ── 8. AXI Interrupt Controller ─────────────────────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 irq_concat_intc
set_property -dict {CONFIG.NUM_PORTS {3}} [get_bd_cells irq_concat_intc]

connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] \
               [get_bd_pins irq_concat_intc/In0]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] \
               [get_bd_pins irq_concat_intc/In1]

## Tap each xfft's status stream out of the BD so xem7310_top.vhd can latch the
## overflow bits (m_axis_status_tdata[0], qualified by tvalid).
##
## INTC Ch2 (frame-done) source MOVES to xfft_1: "frame done" now means the
## INVERSE transform finished, i.e. the whole FFT→filter→IFFT result is ready.
## The driver still waits on S2MM IOC (Ch1) and treats Ch2 as a no-op edge, so
## this source change needs NO driver/IER/C_KIND_OF_INTR change — Ch0/1/2 keep
## their meaning (ACCEL_ARCH invariant) and the channel COUNT is unchanged.
##
## Two overflow taps go to RTL: xfft_0 (forward) keeps its existing sticky-latch
## path to GPIO2 bit0; xfft_1 (inverse) feeds the aggregated-overflow bit1.
create_bd_port -dir O fft_status_tvalid     ;# xfft_0 frame-done/status strobe
create_bd_port -dir O fft_status_overflow   ;# xfft_0 overflow bit
create_bd_port -dir O fft1_status_tvalid    ;# xfft_1 frame-done/status strobe
create_bd_port -dir O fft1_status_overflow  ;# xfft_1 overflow bit

## xfft_0 status strobe → RTL only (no longer drives INTC In2).
connect_bd_net [get_bd_pins xfft_0/m_axis_status_tvalid] \
               [get_bd_ports fft_status_tvalid]

## xfft_1 status strobe → INTC In2 (frame-done = IFFT done) AND out to RTL.
connect_bd_net [get_bd_pins xfft_1/m_axis_status_tvalid] \
               [get_bd_pins irq_concat_intc/In2]          \
               [get_bd_ports fft1_status_tvalid]

## Slice bit 0 (OVFLO) out of each status bus, width-querying the pin (a
## DIN_WIDTH mismatch is a synthesis error).  Helper keeps both taps identical.
proc connect_status_overflow {cell port slice_name} {
    set pin [get_bd_pins $cell/m_axis_status_tdata]
    set w [expr {[get_property LEFT $pin] - [get_property RIGHT $pin] + 1}]
    if {$w <= 1} {
        connect_bd_net $pin [get_bd_ports $port]
    } else {
        create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 $slice_name
        set_property -dict {
            CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {1}
        } [get_bd_cells $slice_name]
        set_property CONFIG.DIN_WIDTH $w [get_bd_cells $slice_name]
        connect_bd_net $pin [get_bd_pins $slice_name/Din]
        connect_bd_net [get_bd_pins $slice_name/Dout] [get_bd_ports $port]
    }
}
connect_status_overflow xfft_0 fft_status_overflow  fft_ovflo_slice
connect_status_overflow xfft_1 fft1_status_overflow fft1_ovflo_slice

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_0
set_property -dict {
    CONFIG.C_HAS_FAST     {0}
    CONFIG.C_KIND_OF_INTR {0x00000004}
} [get_bd_cells axi_intc_0]
## C_KIND_OF_INTR bitmask (0=level, 1=edge per channel):
##   bit 0 (Ch0, DMA MM2S)  = 0: level-sensitive — mm2s_introut stays high until DMASR W1C ✓
##   bit 1 (Ch1, DMA S2MM)  = 0: level-sensitive — s2mm_introut stays high until DMASR W1C ✓
##   bit 2 (Ch2, xfft ovfl) = 1: edge-sensitive  — m_axis_status_tvalid is a 1-cycle pulse;
##     a level-sensitive channel de-asserts before the ISR can read it → overflow events lost

connect_bd_net [get_bd_pins irq_concat_intc/dout] [get_bd_pins axi_intc_0/intr]

## m_axis_status_tready only exists as a flat pin in nonrealtime throttle mode.
## In realtime mode the xfft IP ties tready HIGH internally; skip this connection.
## Tie both xfft instances' status-tready high so the status stream never stalls.
foreach cell {xfft_0 xfft_1} {
    set st [get_bd_pins -quiet $cell/m_axis_status_tready]
    if {$st ne ""} {
        connect_bd_net [get_bd_pins const_one/dout] $st
    }
}

## ── 8b. AXI GPIO for per-transform xfft pipeline reset ──────────────────────
## gpio_io_o[0] = xfft reset control: 1=run (aresetn=1), 0=reset (aresetn=0).
## C_DOUT_DEFAULT=1: gpio_io_o[0] is high on AXI slave reset release, so the
## AND gate below passes peripheral_aresetn unchanged during system reset.
## Firmware writes 0→1 before each transform to flush the pipelined-streaming
## latency (xfft C_ARCH=3 keeps m_axis_data_tvalid=1 across frames; resetting
## the pipeline forces tvalid=0 so DMA S2MM waits for the first real output).
##
## Output channel (ch1) is now 2 bits:
##   bit0 = xfft reset gate (1=run, 0=reset) — drives xfft_rst_and via the
##          gpio_rst_slice (see reset section); C_DOUT_DEFAULT bit0=1 so xfft
##          starts un-reset on power-up.
##   bit1 = filter bypass select (1=forward FFT bins to S2MM, 0=filter+IFFT).
##          Default 0 is harmless because the DRIVER defaults bypass=true and
##          writes the bit explicitly every transform; the bitstream powers up
##          forward-FFT-capable regardless.
## Input channel (ch2) is now 2 bits at GPIO2_DATA (0x08):
##   bit0 = latched xfft_0 (forward) overflow — existing path, ACCEL_ARCH §2.3.
##   bit1 = aggregated overflow (xfft_0 OR xfft_1 OR normalizer saturation),
##          latched in xem7310_top.vhd and fed back via gpio2_io_i.
##
## AXI address: 0x40020000  range 0x80  (covers GPIO_DATA 0x00 and GPIO2_DATA 0x08)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0
set_property -dict {
    CONFIG.C_GPIO_WIDTH    {2}
    CONFIG.C_ALL_INPUTS    {0}
    CONFIG.C_ALL_OUTPUTS   {1}
    CONFIG.C_DOUT_DEFAULT  {0x00000001}
    CONFIG.C_IS_DUAL       {1}
    CONFIG.C_GPIO2_WIDTH   {2}
    CONFIG.C_ALL_INPUTS_2  {1}
    CONFIG.C_ALL_OUTPUTS_2 {0}
} [get_bd_cells axi_gpio_0]

## Expose GPIO ch1 bit1 (filter bypass) to RTL for the 2:1 bypass mux.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 gpio_bypass_slice
set_property -dict {
    CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {1} CONFIG.DIN_TO {1} CONFIG.DOUT_WIDTH {1}
} [get_bd_cells gpio_bypass_slice]
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins gpio_bypass_slice/Din]
create_bd_port -dir O filter_bypass_o
connect_bd_net [get_bd_pins gpio_bypass_slice/Dout] [get_bd_ports filter_bypass_o]

## 1-bit AND gate: xfft_aresetn = gpio_io_o[0] AND peripheral_aresetn.
## Allows firmware reset (via GPIO) AND system reset (via proc_sys_reset).
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 xfft_rst_and
set_property -dict {
    CONFIG.C_SIZE      {1}
    CONFIG.C_OPERATION {and}
} [get_bd_cells xfft_rst_and]

## gpio2_io_i (input channel, 2 bits) carries the latched overflow flags from
## xem7310_top.vhd back to the CPU at GPIO2_DATA (offset 0x08):
##   bit0 = xfft_0 (forward) overflow   bit1 = aggregated overflow.
create_bd_port -dir I -from 1 -to 0 fft_overflow_latched
connect_bd_net [get_bd_ports fft_overflow_latched] \
               [get_bd_pins axi_gpio_0/gpio2_io_i]

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
connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] \
                    [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M05_AXI] \
                    [get_bd_intf_pins coeff_bram_ctrl/S_AXI]

## ── 10. AXI-Stream: DMA ↔ xfft ─────────────────────────────────────────────
## MM2S → xfft: use explicit per-signal connects (not connect_bd_intf_net) so
## that TVALID and TREADY can be tapped as additional sinks on the same net.
## get_bd_nets -of_objects returns empty for interface-connected pins, so
## explicit connect_bd_net is the only way to add probe sinks here.
## M_AXIS_MM2S_TKEEP is intentionally left unconnected: xfft has no TKEEP
## input (it assumes all byte enables are valid), and leaving a BD output
## unconnected produces only a warning, not an error.

create_bd_port -dir O fft_dbg_mm2s_tvalid
create_bd_port -dir O fft_dbg_s_data_tready

connect_bd_net [get_bd_pins axi_dma_0/M_AXIS_MM2S_TVALID] \
               [get_bd_pins xfft_0/s_axis_data_tvalid]     \
               [get_bd_ports fft_dbg_mm2s_tvalid]
connect_bd_net [get_bd_pins xfft_0/s_axis_data_tready]     \
               [get_bd_pins axi_dma_0/M_AXIS_MM2S_TREADY]  \
               [get_bd_ports fft_dbg_s_data_tready]
connect_bd_net [get_bd_pins axi_dma_0/M_AXIS_MM2S_TDATA]  \
               [get_bd_pins xfft_0/s_axis_data_tdata]
connect_bd_net [get_bd_pins axi_dma_0/M_AXIS_MM2S_TLAST]  \
               [get_bd_pins xfft_0/s_axis_data_tlast]

## ── xfft_0 output → [RTL filter / bypass] → xfft_1 input → S2MM ────────────
## The forward-FFT output no longer goes straight to S2MM.  It is brought OUT to
## xem7310_top.vhd, where a 2:1 bypass mux either passes it straight through or
## routes it through the spectral_filter (per-bin complex multiply by H[k] +
## Q2.30→Q1.15 normalize).  The selected stream comes back IN as the inverse
## FFT input.  xfft_1's output then drives S2MM.  All in the single aclk domain.
##
## The fft_dbg_m_data_* taps stay on xfft_0/m_axis_data so WireOut 0x22
## (fft_beat_counter on the FORWARD output) is unchanged — the standing
## observability surface for the forward stage's N-beat PG109 contract.  A
## second beat counter on xfft_1's output (WireOut 0x27) proves the N-beat
## invariant survives the filter chain through to S2MM (added in xem7310_top).

## ── All AXIS endpoints between the two xffts and S2MM cross to RTL ─────────
## The bypass mux MUST select the S2MM SOURCE between xfft_0's output (forward
## bins — what fft_accel_transform() reads) and xfft_1's output (filtered IFFT
## — what fft_accel_transform_filtered() reads).  So S2MM is no longer wired to
## a fixed xfft inside the BD: instead xfft_0 out, xfft_1 in, xfft_1 out, and
## the S2MM slave port are ALL exposed to xem7310_top.vhd, which contains the
## spectral_filter and the 2:1 source mux.  This keeps the forward-FFT-only
## result bit-identical to today when bypass=1.

## xfft_0 m_axis_data (forward FFT output X[k]) → RTL.
## fft_dbg_m_data_tvalid/tlast still feed the FORWARD beat counter (WireOut
## 0x22) — unchanged observability of xfft_0.
create_bd_port -dir O fft_dbg_m_data_tvalid
create_bd_port -dir O fft_dbg_m_data_tlast
create_bd_port -dir O fft0_m_tdata -from 31 -to 0
create_bd_port -dir I fft0_m_tready
connect_bd_net [get_bd_pins xfft_0/m_axis_data_tvalid] [get_bd_ports fft_dbg_m_data_tvalid]
connect_bd_net [get_bd_pins xfft_0/m_axis_data_tlast]  [get_bd_ports fft_dbg_m_data_tlast]
connect_bd_net [get_bd_pins xfft_0/m_axis_data_tdata]  [get_bd_ports fft0_m_tdata]
connect_bd_net [get_bd_ports fft0_m_tready]            [get_bd_pins xfft_0/m_axis_data_tready]

## xfft_1 s_axis_data (inverse FFT input — the filtered stream from RTL).
create_bd_port -dir I fft1_s_tvalid
create_bd_port -dir I fft1_s_tlast
create_bd_port -dir I fft1_s_tdata -from 31 -to 0
create_bd_port -dir O fft1_s_tready
connect_bd_net [get_bd_ports fft1_s_tvalid] [get_bd_pins xfft_1/s_axis_data_tvalid]
connect_bd_net [get_bd_ports fft1_s_tlast]  [get_bd_pins xfft_1/s_axis_data_tlast]
connect_bd_net [get_bd_ports fft1_s_tdata]  [get_bd_pins xfft_1/s_axis_data_tdata]
connect_bd_net [get_bd_pins xfft_1/s_axis_data_tready] [get_bd_ports fft1_s_tready]

## xfft_1 m_axis_data (inverse FFT output y[n]) → RTL (one mux input).
create_bd_port -dir O fft1_m_tvalid
create_bd_port -dir O fft1_m_tlast
create_bd_port -dir O fft1_m_tdata -from 31 -to 0
create_bd_port -dir I fft1_m_tready
connect_bd_net [get_bd_pins xfft_1/m_axis_data_tvalid] [get_bd_ports fft1_m_tvalid]
connect_bd_net [get_bd_pins xfft_1/m_axis_data_tlast]  [get_bd_ports fft1_m_tlast]
connect_bd_net [get_bd_pins xfft_1/m_axis_data_tdata]  [get_bd_ports fft1_m_tdata]
connect_bd_net [get_bd_ports fft1_m_tready]            [get_bd_pins xfft_1/m_axis_data_tready]

## DMA S2MM slave ← RTL (driven by the bypass mux: xfft_0 out OR xfft_1 out).
## These are the SINK side; RTL drives tvalid/tlast/tdata, BD returns tready.
create_bd_port -dir I s2mm_tvalid
create_bd_port -dir I s2mm_tlast
create_bd_port -dir I s2mm_tdata -from 31 -to 0
create_bd_port -dir O s2mm_tready
connect_bd_net [get_bd_ports s2mm_tvalid] [get_bd_pins axi_dma_0/S_AXIS_S2MM_TVALID]
connect_bd_net [get_bd_ports s2mm_tlast]  [get_bd_pins axi_dma_0/S_AXIS_S2MM_TLAST]
connect_bd_net [get_bd_ports s2mm_tdata]  [get_bd_pins axi_dma_0/S_AXIS_S2MM_TDATA]
connect_bd_net [get_bd_pins axi_dma_0/S_AXIS_S2MM_TREADY] [get_bd_ports s2mm_tready]

## xfft config words: forward (const_fft_cfg=0x1555, ÷N) on xfft_0, inverse
## (const_ifft_cfg=0x0000, unscaled) on xfft_1 — the forward already applied the
## total 1/N, so an unscaled inverse yields a unity round trip.  Same const_one
## tvalid/tlast handshake.
proc connect_fft_config {cell cfg_const} {
    set tdata  [get_bd_pins -quiet $cell/s_axis_config_tdata]
    set tvalid [get_bd_pins -quiet $cell/s_axis_config_tvalid]
    if {$tdata eq "" || $tvalid eq ""} {
        puts "WARNING: $cell/s_axis_config_{tdata,tvalid} not found as flat pins."
        puts "         Verify S_AXIS_CONFIG is connected in the generated schematic."
    } else {
        connect_bd_net [get_bd_pins $cfg_const/dout] $tdata
        connect_bd_net [get_bd_pins const_one/dout]  $tvalid
        set tlast [get_bd_pins -quiet $cell/s_axis_config_tlast]
        if {$tlast ne ""} {
            connect_bd_net [get_bd_pins const_one/dout] $tlast
        }
    }
}
connect_fft_config xfft_0 const_fft_cfg
connect_fft_config xfft_1 const_ifft_cfg

## ── 11. Clock distribution ──────────────────────────────────────────────────
set aclk [get_bd_pins clk_wiz_0/clk_out1]

foreach pin {
    axi_smc/aclk
    axi_dma_0/m_axi_mm2s_aclk
    axi_dma_0/m_axi_s2mm_aclk
    axi_dma_0/s_axi_lite_aclk
    tx_bram_ctrl/s_axi_aclk
    rx_bram_ctrl/s_axi_aclk
    coeff_bram_ctrl/s_axi_aclk
    xfft_0/aclk
    xfft_1/aclk
    axi_intc_0/s_axi_aclk
    axi_gpio_0/s_axi_aclk
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
    coeff_bram_ctrl/s_axi_aresetn
    axi_intc_0/s_axi_aresetn
    axi_gpio_0/s_axi_aresetn
} {
    connect_bd_net $peripheral_rstn [get_bd_pins $pin]
}

## xfft_0/aresetn is controlled by the AND gate (xfft_rst_and), NOT directly
## by peripheral_aresetn.  This lets firmware reset the xfft pipeline per-transform
## (via AXI GPIO) while still passing system reset through to the xfft.
##
## xfft_1 (inverse) shares the SAME gated reset net, and Op1 is driven from GPIO
## bit 0 ONLY (the aresetn gate) — slice it out since the GPIO is now 2 bits
## wide (bit1 = filter bypass, which must NOT gate the reset).  One firmware
## reset pulse therefore flushes BOTH transform pipelines and the spectral
## filter between them, so no stale tvalid/tlast can leak across a transform.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 gpio_rst_slice
set_property -dict {
    CONFIG.DIN_WIDTH {2}
    CONFIG.DIN_FROM  {0}
    CONFIG.DIN_TO    {0}
    CONFIG.DOUT_WIDTH {1}
} [get_bd_cells gpio_rst_slice]
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins gpio_rst_slice/Din]
connect_bd_net [get_bd_pins gpio_rst_slice/Dout]  [get_bd_pins xfft_rst_and/Op1]
connect_bd_net $peripheral_rstn                   [get_bd_pins xfft_rst_and/Op2]
connect_bd_net [get_bd_pins xfft_rst_and/Res]     [get_bd_pins xfft_0/aresetn]
connect_bd_net [get_bd_pins xfft_rst_and/Res]     [get_bd_pins xfft_1/aresetn]

## Expose the xfft aresetn so xem7310_top.vhd can clear the overflow latch on
## the per-transform reset pulse (firmware drives GPIO bit 0 low → aresetn low).
create_bd_port -dir O xfft_aresetn_o
connect_bd_net [get_bd_pins xfft_rst_and/Res] [get_bd_ports xfft_aresetn_o]

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
    -offset 0x41000000 -range 0x00008000 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs tx_bram_ctrl/S_AXI/Mem0] -force

assign_bd_address \
    -offset 0x41008000 -range 0x00008000 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs rx_bram_ctrl/S_AXI/Mem0] -force

assign_bd_address \
    -offset 0x40010000 -range 0x00000080 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs axi_intc_0/S_AXI/Reg] -force

assign_bd_address \
    -offset 0x41000000 -range 0x00008000 \
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
    -offset 0x41008000 -range 0x00008000 \
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

assign_bd_address \
    -offset 0x40020000 -range 0x00000080 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs axi_gpio_0/S_AXI/Reg]

exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs axi_gpio_0/S_AXI/Reg]

## Filter coefficient BRAM: CPU-only slave at 0x42000000, 16 KB (4096 × 32 b).
## Distinct from the 0x4100_xxxx FFT BRAM window so there is no aliasing.
## Reachable only from s_axi_cpu (S00_AXI); explicitly excluded from BOTH DMA
## address spaces so neither MM2S nor S2MM can ever reach the coefficient table
## (same isolation discipline as the tx/rx/intc/gpio excludes above).
assign_bd_address \
    -offset 0x42000000 -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces s_axi_cpu] \
    [get_bd_addr_segs coeff_bram_ctrl/S_AXI/Mem0] -force

exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_MM2S] \
    [get_bd_addr_segs coeff_bram_ctrl/S_AXI/Mem0]

exclude_bd_addr_seg \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs coeff_bram_ctrl/S_AXI/Mem0]

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
