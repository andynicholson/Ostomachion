# FFT Accelerator Architecture

This document is the architectural contract for the Ostomachion FFT
accelerator pipeline.  It complements the [Architecture diagram in
`README.md`](README.md#architecture) and the driver/HAL docstrings under
[`zephyr_app/`](zephyr_app/) by specifying, in one place, the configuration
and ordering invariants that make the pipeline work.

Every rule below is presented in active voice: this is what the design does,
and this is the failure mode when the rule is violated.  Use it as the
reference when changing the block design, the FFT driver, or the device-tree
overlay.

---

## 1. Purpose and scope

The accelerator turns a 4096-point complex Q1.15 input frame into a
4096-point natural-order complex Q1.15 output frame, with no host
intervention between the start of a transform and the IOC interrupt that
signals the result is committed to RX BRAM.  The hardware is:

- **Xilinx xfft v9.1** — pipelined streaming, 4096-point, 16-bit Q1.15,
  natural-order output, scaling enabled, truncation rounding, nonrealtime
  throttle mode, overflow output enabled.
- **AXI DMA (Xilinx PG021)** — two independent channels, MM2S and S2MM,
  register-direct (no scatter-gather), 32-bit data width.
- **TX / RX BRAM** — `blk_mem_gen` single-port RAM, 8192×32 b each, fronted
  by an AXI BRAM Controller (Xilinx PG078) in single-port mode.
- **AXI INTC (Xilinx PG099)** — three channels aggregated onto the single
  NEORV32 `mext_irq_i` line.
- **AXI GPIO (Xilinx PG144)** — one output bit gating xfft `aresetn`.

Application code reaches the accelerator through the Zephyr driver
[`fft_accel.c`](zephyr_app/drivers/accel/fft_accel.c) and its C++20 HAL
wrapper [`ostomachion::FftAccel`](zephyr_app/include/ostomachion/hal/fft_accel.hpp).

---

## 2. System block diagram and AXI memory map

```text
NEORV32 RISC-V
   │
   └─ XBUS ── xbus2axi4_bridge ── AXI SmartConnect (3M × 5S)
                                       │
                  ┌────────────────────┼────────────────────┐
                  │                    │                    │
             AXI DMA              AXI INTC             AXI GPIO
            0x4000_0000          0x4001_0000          0x4002_0000
            MM2S│ S2MM         IRQ → mext_irq_i      bit0 → xfft_aresetn
                │    │
           TX BRAM   RX BRAM
          0x4100_0000 0x4100_8000
            32 KB     32 KB
                │    │
           AXI-Stream (TDATA 32 b Q1.15, TVALID/TREADY/TLAST)
                │    │
              Xilinx xfft v9.1
        (N=4096, pipelined-streaming,
         natural order, scaled, nonrealtime throttle)
```

### 2.1. Address map (XBUS region `0x4000_0000`–`0x4FFF_FFFF`)

| Base | Size | Peripheral | DTS `reg-names` entry |
|------|------|------------|------------------------|
| `0x4000_0000` | 64 B  | AXI DMA AXI4-Lite control | `dma` |
| `0x4001_0000` | 128 B | AXI INTC AXI4-Lite | `intc` |
| `0x4002_0000` | 128 B | AXI GPIO (xfft reset gate + overflow readback) | `gpio` |
| `0x4100_0000` | 32 KB | TX BRAM (CPU writes input samples) | `tx_bram` |
| `0x4100_8000` | 32 KB | RX BRAM (CPU reads output samples) | `rx_bram` |

The AXI SmartConnect crossbar aggregates three masters (NEORV32 via the
XBUS-to-AXI4-Lite bridge, plus the DMA's MM2S and S2MM ports) onto five
slaves; the address ranges above are aligned to power-of-two BRAM depths so
the SmartConnect alignment constraint (`range == depth × 4`) is satisfied.

### 2.2. AXI INTC channel wiring

The AXI INTC aggregates three sources into the single NEORV32 MEI line
(`mext_irq_i`, INTC IRQ 11):

| Channel | Source | Sensitivity | Driver action |
|---------|--------|-------------|----------------|
| Ch0 | `axi_dma_0/mm2s_introut` | Level | Log error; release semaphore on error |
| Ch1 | `axi_dma_0/s2mm_introut` | Level | Release semaphore on IOC or error |
| Ch2 | `xfft_0/m_axis_status_tvalid` | Edge  | None (frame-complete pulse; not overflow-only) |

The `C_KIND_OF_INTR` register reflects this: bits 0 and 1 are 0
(level-sensitive), bit 2 is 1 (edge-sensitive).

Channel 2 is **not** a clean overflow indicator — it is just the frame-done
pulse.  The actual overflow bit lives in `m_axis_status_tdata[0]`, which is
captured separately (see §2.3); the driver treats Ch2 as a frame-done
notification only and does not act on it in the ISR.

### 2.3. Overflow capture and readback

The xfft fixed-point overflow flag (`m_axis_status_tdata[0]`, qualified by
`m_axis_status_tvalid`) is not delivered through the interrupt path.  Instead:

1. The block design slices bit 0 out of `m_axis_status_tdata` and routes it,
   with its `tvalid` strobe, to BD output ports.
2. `xem7310_top.vhd` holds a **sticky latch** in the `aclk` domain: it sets on
   `tvalid && overflow` and clears on the xfft `aresetn` (also exposed as a BD
   port).  Because firmware pulses `aresetn` low at the start of every
   transform (§3 step 3), the latch always reflects exactly the frame just
   computed.
3. The latch feeds the AXI GPIO **input channel** (`gpio2_io_i`), so the CPU
   reads it at `GPIO_DATA2` (offset `0x08`), bit 0.

`fft_accel_transform()` samples this after S2MM IOC and exposes it through
`fft_accel_get_last_overflow(dev)`.  Reading it in the transform (not the ISR)
avoids any race between the Ch2 edge and the latch update.

---

## 3. Transform sequence

`fft_accel_transform(dev, in, out, 4096)` performs the following sequence
under an internal `k_mutex` that serialises concurrent callers:

1. **Acquire `xfer_lock`** and clear `last_error` / `last_overflow`.
2. **Write 4096 complex samples to TX BRAM** as packed 32-bit words
   (`{im[15:0], re[15:0]}`) via `sys_write32()`, then issue a data-memory
   fence so the fill is globally visible before any DMA register write
   (the BRAM and DMA are different AXI slaves with no implicit ordering).
3. **Pulse the xfft pipeline reset and quiesce the DMA.**  Assert `aresetn=0`
   (GPIO=0), hold ≥ 2 `aclk` cycles via `k_busy_wait(1)`, software-reset both
   DMA channels, then release `aresetn=1` (GPIO=1).  **`k_sem_reset()` is then
   called here** — once both channels are halted but before either is armed —
   so a late `k_sem_give()` from a previously timed-out transfer cannot survive
   into this one.  (Resetting the semaphore before the DMA reset would leave
   the ~4096-write fill window open for a stale give to slip through.)
4. **Arm S2MM first, then MM2S.**  S2MM is configured with IOC + ERR IRQs
   enabled, MM2S with ERR IRQ only.  Writing each channel's `LENGTH`
   register triggers the transfer.
5. **Block on `irq_sem`** until the ISR fires for an S2MM IOC or any DMA
   error, with a `CONFIG_FFT_ACCEL_TIMEOUT_MS` timeout.  On success, issue a
   data-memory fence before reading RX BRAM so the DMA's posted writes are
   observed.
6. **Sample the overflow latch** (`GPIO_DATA2` bit 0, §2.3) and **validate
   S2MM IDLE** in the post-IOC `DMASR` snapshot.
7. **Read 4096 output samples** from RX BRAM with `sys_read32()` and
   release `xfer_lock`.

The driver exposes the result via `out[i]` (Q1.15 complex words) and the
overflow flag via `fft_accel_get_last_overflow(dev)`.

---

## 4. Design rules

Each rule below states what the configuration enforces, why the rule
exists, and what fails if the rule is violated.

### 4.1. BRAM read-latency contract (PG078 §1.3)

The AXI BRAM Controller's `READ_LATENCY` parameter is left at its default
value of `1`.  Both `blk_mem_gen` instances therefore have
`Register_PortA_Output_of_Memory_Primitives = false`, giving a strict
1-cycle BRAM read pipeline that matches the controller exactly.

PG078 §1.3 is explicit:

> When Read Latency is 1, the controller expects latency of one clock
> cycle from BRAM.  Therefore, the output register from the BRAM
> (Primitives Output Register/Core Output Register) cannot be selected.

The empirical confirmation lives on the bitstream: WireOut `0x22` shows the
xfft IP emits exactly N beats per N-point frame, and a marker pre-fill of
RX BRAM (`0xDEAD_xxxx`) read back from the CPU lines up word-for-word with
the DMA write address.

> **Failure mode — change either side of the contract:**
> If `Register_PortA_Output_of_Memory_Primitives` is set to `true` while
> the controller stays at `READ_LATENCY=1`, the controller samples the
> BRAM data port one cycle too early.  Every CPU read returns the
> *previously-addressed* word — a 1-word off-by-one shift on the entire
> output spectrum.

### 4.2. Single-port BRAM access

The AXI BRAM Controllers are configured with `SINGLE_PORT_BRAM = 1`, and
the `blk_mem_gen` instances use `Memory_Type = Single_Port_RAM`.  All DMA
writes and CPU reads serialise through `BRAM_PORTA`.

> **Failure mode — re-enable dual-port:**
> With dual-port (`SINGLE_PORT_BRAM = 0`), the SmartConnect can return an
> early `BRESP=OKAY` to the DMA before the write reaches the BRAM fabric
> on Port A while the CPU reads on Port B concurrently.  The CPU then
> reads pre-DMA data and the IOC interrupt no longer marks "output ready".

### 4.3. DMA arming order (S2MM before MM2S)

Step 4 of the transform sequence arms `S_AXIS_S2MM` *before*
`M_AXIS_MM2S`.  S2MM raises `TREADY=1` as soon as it is armed, so the xfft
output stream has a sink ready before the input stream begins.

> **Failure mode — arm MM2S first:**
> In nonrealtime throttle mode, `m_axis_data_tready=0` back-pressures
> through the xfft pipeline to `s_axis_data_tready=0`.  MM2S blocks
> waiting for `TREADY`, the IP never accepts the input frame, and the
> transform times out.

### 4.4. Symmetric DMA byte length (N × 4 each way)

Both channels are programmed with `byte_len = N * 4` bytes (16 384 bytes
for N = 4096).  The xfft IP emits exactly N output beats per N-point input
frame with `TLAST` on the final beat, so no asymmetric `(N+1)` or `(N-1)`
correction is needed in the driver.

> **Failure mode — over-length S2MM:**
> Programming `s2mm = (N + 1) * 4` asserts `TLAST` to the DMA one beat
> past the xfft frame boundary.  The DMA waits for a beat that never
> arrives, leaving the channel busy until the next reset and the IP in an
> undefined state.

### 4.5. xfft `aresetn` timing (PG109 §3)

The driver asserts `aresetn=0` for at least two `aclk` cycles before
de-asserting.  At 100 MHz the `k_busy_wait(1)` calls on either side of the
GPIO toggle give a 50× margin over the 2-cycle minimum and make the
requirement explicit instead of relying on MMIO write latency.

The reset signal is built in fabric as
`xfft_aresetn = gpio_io_o[0] AND peripheral_aresetn`
via a `util_vector_logic` AND gate, with `C_DOUT_DEFAULT = 1` on the GPIO
so the gate passes `peripheral_aresetn` unchanged on power-on.

> **Failure mode — skip the busy-wait:**
> Releasing `aresetn` within a single `aclk` cycle leaves the pipeline
> only partially flushed.  Stale `tvalid`/`tlast` levels from the previous
> frame can leak into the next, corrupting the first output beats.

### 4.6. AXI INTC initialisation order (IER before MER)

The driver writes the Interrupt Enable Register first
(`INTC_IER = MM2S | S2MM | FRAME_DONE`), then the Master Enable Register
(`INTC_MER = ME | HIE`).

> **Failure mode — write MER alone:**
> Enabling the master without enabling any channel leaves
> `axi_intc/intr` permanently low.  The DMA fires `introut` correctly but
> the IRQ never reaches the CPU; `fft_accel_transform()` returns
> `-ETIMEDOUT` and the post-mortem snapshot shows `INTC_ISR = 0`.

### 4.7. DMASR W1C before INTC IAR

Inside the ISR, the per-channel handler clears the DMA `DMASR` IRQ bits
(`IOC_IRQ`, `ERR_IRQ`) by writing them back as W1C, *then* acknowledges
the INTC by writing the channel mask to `INTC_IAR`.

> **Failure mode — IAR first:**
> `mm2s_introut` and `s2mm_introut` are still high when `INTC_IAR` is
> written because the underlying DMA IRQ has not been cleared.  The INTC
> ISR bit re-asserts on the next clock edge, the CPU re-enters the ISR,
> and `k_sem_give()` fires twice — the next `fft_accel_transform()` then
> takes a stale semaphore count and reads garbage from RX BRAM.

---

## 5. Observability

A permanent diagnostic surface is built into the bitstream so the
pipeline can be inspected on running hardware without rebuilding.

| Endpoint | Width | Contents |
|----------|------:|----------|
| WireOut `0x20` | [10:0] | RX pipe FIFO byte count |
| WireOut `0x21` bit 0 | 1 | `M_AXIS_MM2S TVALID` (DMA sending input) |
| WireOut `0x21` bit 1 | 1 | `xfft s_axis_data TREADY` (xfft accepting) |
| WireOut `0x21` bit 2 | 1 | `periph_rstn(0)` (system reset released) |
| WireOut `0x22` [15:0]  | 16 | `pre_first_tlast_beats` — first-frame beat count after `aresetn` |
| WireOut `0x22` [31:16] | 16 | `beats_in_last_frame` — most recent frame's beat count |
| WireOut `0x23` [7:0]   | 8  | `tlast_count` — modulo-256 count of `TLAST` events |

`pre_first_tlast_beats` and `beats_in_last_frame` are produced by the
[`fft_beat_counter`](fpga/xem7310/fft_beat_counter.vhd) entity in
[`xem7310_top.vhd`](fpga/xem7310/xem7310_top.vhd).  It is a passive
observer on the xfft `m_axis_data` interface; it counts every
`TVALID && TREADY` handshake in the `aclk` domain and latches the count
at each rising `TLAST`.

[`scripts/uart_bridge.py`](scripts/uart_bridge.py) decodes the WireOut
state into one of three outcomes:

- **Outcome A** — `pre_first = beats_in_last = N`: PG109-correct, no
  phantom output beat after reset.
- **Outcome B** — `pre_first = N + 1`: first frame contains an extra beat
  from a pipeline-flush failure.
- **Outcome C** — counts vary frame-to-frame: an upstream back-pressure
  bug on the S2MM TREADY path.

The accelerator on this bitstream produces Outcome A on every transform;
this is the empirical confirmation of the §4.1 read-latency contract and
the §4.4 symmetric-length rule.

---

## 6. Verification surface

The `ostomachion_fft` ZTEST suite in
[`zephyr_app/tests/test_fft_accel.cpp`](zephyr_app/tests/test_fft_accel.cpp)
exercises the design rules above on real hardware.  Each test guards a
specific failure mode:

| # | Test | Guards |
|---|------|--------|
| 1 | `test_dc_response` | DC input dominates bin 0; coarse functional sanity |
| 2 | `test_dc_exact` | DC magnitude within ±5 %; catches partial bin-energy split |
| 3 | `test_single_tone` | Cosine at bin 8 peaks exactly at 8 or 4088 (off-by-one regression for the BRAM read-latency contract) |
| 4 | `test_no_off_by_one` | Cosine at bin 1 peaks exactly at 1 or 4095 (tightest off-by-one guard) |
| 5 | `test_y_n_minus_1` | `g_out[N-1]` is populated; catches under-length S2MM transfers |
| 6 | `test_roundtrip_latency` | One 4096-pt transform completes within 2000 µs (interrupt/DMA scheduling) |
| 7 | `test_invalid_n` | Non-4096 transform lengths return `-EINVAL` |
| 8 | `test_sequential` | Two back-to-back transforms each produce valid output (stale-IRQ regression) |

Run the suite on connected hardware with:

```bash
make test-accel-hw
```

The Makefile target builds the firmware against `prj_accel.conf`, uploads
it via the UART bootloader, switches the bridge to 115 200 baud, and waits
for `PROJECT EXECUTION SUCCESSFUL`.
