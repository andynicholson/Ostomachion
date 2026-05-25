# FFT Accelerator Debug Log

Running record of bugs found, fixes applied, and open questions for the
Ostomachion FFT accelerator pipeline (Xilinx xfft v9.1 + AXI DMA + NEORV32).

---

## Hardware overview

```
CPU (NEORV32 RISC-V)
  │
  └─ XBUS → xbus2axi4lite bridge → AXI SmartConnect (3M × 5S)
                                         │
                          ┌──────────────┼──────────────────────────┐
                          │              │                           │
                     AXI DMA        AXI INTC               AXI GPIO
                  0x40000000       0x40010000             0x40020000
                     MM2S│ S2MM      IRQ out→NEORV32       bit0=xfft_aresetn
                         │    │
                    TX BRAM  RX BRAM
                  0x41000000 0x41008000
                    32 KB      32 KB
                         │    │
                    AXI-Stream (TDATA 32-bit Q1.15, TVALID/TREADY)
                         │    │
                       Xilinx xfft v9.1
                   (N=4096, C_ARCH=3 pipelined streaming,
                    natural-order output, all stages scaled,
                    nonrealtime throttle mode)
```

**AXI INTC channel wiring:**

| Channel | Source | Driver handling |
|---------|--------|----------------|
| Ch0 | DMA MM2S complete / error | Logs error, gives sem on error |
| Ch1 | DMA S2MM complete / error | Gives sem on IOC or error |
| Ch2 | xfft m_axis_status_tvalid | No action (frame-complete, not reliably overflow-only) |

**Transfer sequence per `fft_accel_transform()` call:**
1. Write N=4096 samples to TX BRAM via MMIO
2. Assert xfft aresetn (GPIO=0), DMA software reset, release aresetn (GPIO=1)
3. Arm S2MM first (TREADY=1 before xfft output begins), then MM2S
4. Wait on semaphore for S2MM IOC interrupt
5. Read N samples from RX BRAM via MMIO

---

## Issues found and resolved

### Issue 1 — AXI INTC not initialised: no interrupts delivered

**Symptom:** `fft_accel_transform()` always timed out.  DMA completed
(S2MM_DMASR IOC bit set when read at timeout) but the ISR never ran.

**Root cause:** The AXI INTC Master Enable Register (`MER`) was not being
written.  The INTC requires both `ME` (bit 0) and `HIE` (bit 1) to be set
before it will assert its IRQ output pin.  `IER` was also not being programmed,
so even with MER set, no channel would pass through.

**Fix:** Added to `fft_accel_init()`:
```c
intc_wr(cfg, INTC_IER, INTC_CH_MM2S | INTC_CH_S2MM | INTC_CH_OVFLO);
intc_wr(cfg, INTC_MER, INTC_MER_ME | INTC_MER_HIE);
```

**Status:** Confirmed fixed.

---

### Issue 2 — Spurious re-entry: ISR fired twice per DMA completion

**Symptom:** After fixing Issue 1, `k_sem_give()` was being called twice per
transfer.  The second call left a stale count on `irq_sem`, causing the next
`k_sem_take()` to return immediately with stale data in the BRAM.

**Root cause:** AXI INTC channels 0 and 1 are **level-sensitive**
(`C_KIND_OF_INTR` = 0).  `mm2s_introut` / `s2mm_introut` stay asserted until
the DMA DMASR register is cleared (W1C).  Writing INTC IAR before clearing
DMASR causes the ISR bit to re-assert immediately after the IAR write —
triggering a second ISR entry where `give_sem` fires again on the stale `isr`
snapshot.

**Fix:** W1C-clear DMASR first, then write INTC IAR:
```c
dma_wr(cfg, DMA_MM2S_DMASR, mm2s_sr);   // de-asserts mm2s_introut
// ... (ch1 same) ...
intc_wr(cfg, INTC_IAR, isr);             // now safe to acknowledge
```

Also added `k_sem_reset()` at the top of each `fft_accel_transform()` call to
discard any stale count left by a timed-out previous transfer.

**Status:** Confirmed fixed.

---

### Issue 3 — `fft dc` FAIL: DC peak at out[0] was wrong value

**Symptom:** With all-DC input (re=16384, im=0 for all 4096 samples), the
expected result is out[0].re ≈ 16384.  Instead, out[0] held a near-zero or
stale value.  Direct reads of raw BRAM addresses showed BRAM[1] contained the
correct 16384 value, not BRAM[0].

**Observation:** This was the off-by-one symptom.  The FFT output was shifted
by exactly one sample in BRAM — Y[k] was at BRAM[k+1] rather than BRAM[k].

**Root cause — confirmed:** After the AXI DMA S2MM channel is armed (TREADY
asserted), the xfft IP's natural-order output sorter briefly asserts
`m_axis_data_tvalid=1` for one word before it is ready to produce real output.
This is documented xfft v9.1 behaviour (PG109): `C_ARCH=3` pipelined streaming
keeps `m_axis_data_tvalid` asserted across frames (between transforms).
After `aresetn` de-assertion the output pipeline register fires one phantom
word.  S2MM captures this at BRAM[0].  Y[0] lands at BRAM[1], Y[k] at
BRAM[k+1].

**Partial root cause — stale first AXI read:** In addition to the off-by-one,
the very first `sys_read32()` after returning from interrupt context returned
pre-DMA data for that address, regardless of which BRAM word was read.
Subsequent reads in the same loop returned correct data.  Adding a
`fence` instruction did not help (RISC-V `fence` orders CPU-issued stores only;
it cannot wait for writes issued by a different AXI master, the DMA).

**What is confirmed vs hypothesised:**

| Claim | Status |
|-------|--------|
| Y[k] is at BRAM[k+1], not BRAM[k] | **Confirmed by direct BRAM reads** |
| First `sys_read32()` after ISR returns stale data | **Confirmed by experiment** |
| xfft asserts tvalid for one phantom word after aresetn de-assertion | **Hypothesis** (consistent with PG109 C_ARCH=3 behaviour; not directly observed on hardware) |
| The phantom is the source of the +1 offset | **Hypothesis** (most plausible explanation; no alternative confirmed) |

**Fix applied (driver):**
```c
/* Dummy read of BRAM[0]: absorbs the stale-first-read penalty AND
 * discards the phantom word (which is at BRAM[0] regardless of cause). */
(void)sys_read32(cfg->rx_bram_base);

for (size_t i = 0; i < n; i++) {
    uint32_t word = sys_read32(cfg->rx_bram_base + (i + 1) * 4);
    out[i].re = (int16_t)(word & 0xFFFFu);
    out[i].im = (int16_t)(word >> 16);
}
```

**Status:** `fft dc` PASS, `fft sine` PASS after this fix.

---

### Issue 4 — Y[N-1] silently lost

**Symptom:** When the off-by-one was understood, it became clear that if the
DMA transfer length is exactly N×4 bytes and BRAM[0] is consumed by the phantom
word, then BRAM[1..N-1] holds Y[0..N-2] and Y[N-1] falls at BRAM[N], which is
one word past the end of the transfer window.  Y[N-1] (bin 4095) was being
silently dropped — the DMA never wrote it.

**Fix applied (three coordinated changes):**

1. **Driver** — DMA transfer length N+1 words:
   ```c
   uint32_t byte_len = (uint32_t)((n + 1) * sizeof(struct fft_sample_t));
   ```
   With N+1 words transferred: BRAM[0]=phantom, BRAM[1..N]=Y[0..N-1].
   All N output samples are now captured.

2. **Block design** (`ostomachion_bd.tcl`) — RX BRAM depth 8192 words (32 KB):
   The next power-of-2 above N+1=4097 is 8192.  Using 4097 directly would
   cause Vivado to synthesise 8192 locations anyway (BRAM primitives are
   strictly power-of-2), so 8192 is specified explicitly.  TX BRAM also set
   to 8192 for uniformity.

3. **Address map** — RX BRAM moved from `0x41004000` to `0x41008000`:
   A 32 KB (0x8000) AXI region must be placed at a base address that is a
   multiple of 0x8000.  `0x41004000` is only 16K-aligned; the AXI SmartConnect
   address validator rejected it with:
   ```
   ERROR: [BD 41-1075] The proposed address '0x4100_4000 [ 32K ]' is misaligned.
   The next aligned offset for this range is '0x4100_8000'.
   ```
   TX BRAM remains at `0x41000000` (32K-aligned).  RX BRAM moved to
   `0x41008000` (32K-aligned, no overlap with TX).

**Status:** Code and hardware configuration changes applied.  Bitstream rebuild
required to verify on hardware.

---

### Issue 5 — AXI write-read ordering: CPU reads stale BRAM data

**Symptom:** With a true dual-port BRAM and `Register_PortB_Output=true`, CPU
reads of RX BRAM immediately after the S2MM IOC interrupt returned stale (pre-
DMA) values.  Experimenting with 3 dummy reads before the main loop showed that
multiple consecutive reads returned duplicate stale data — not just the first.

**Diagnosis:** With `SINGLE_PORT_BRAM {0}` (dual-port), the AXI BRAM
controller uses Port A for DMA writes and Port B for CPU reads simultaneously.
The AXI SmartConnect may return BRESP to the DMA before the write actually
reaches the BRAM data array (early response buffering), allowing a CPU read
on Port B to race ahead of the DMA write on Port A and return stale data from
the BRAM output register.

**Fix applied** (`ostomachion_bd.tcl`):
- AXI BRAM controller: `SINGLE_PORT_BRAM {1}`
- blk_mem_gen: `Memory_Type {Single_Port_RAM}` (removes Port B)
- All BRAM_PORTB connections removed from the block design

Single-port mode forces all accesses (DMA writes and CPU reads) through Port A,
serialising them and eliminating the simultaneous-access race.

**Note:** This hardware fix addresses a different failure mode from the dummy
read fix in Issue 3.  The dummy read handles the stale-first-read on the CPU
AXI read path; single-port BRAM handles the DMA write not yet reaching BRAM
before the CPU reads.  Both fixes are in place.

**Status:** TCL change applied.  Bitstream rebuild required.

---

## Current state of all changes

### Driver (`zephyr_app/drivers/accel/fft_accel.c`)

| Change | Reason |
|--------|--------|
| S2MM armed before MM2S | Prevents TREADY=0 deadlock on nonrealtime throttle mode |
| `k_sem_reset()` at start of each transform | Discards stale semaphore count from timed-out prior call |
| DMASR W1C before INTC IAR | Prevents spurious re-entry on level-sensitive INTC channels |
| `byte_len = (n+1) * 4` | Captures Y[N-1] which falls at BRAM[N] due to phantom at BRAM[0] |
| Dummy read of `rx_bram_base` | Absorbs stale-first-read penalty; simultaneously discards phantom |
| Loop reads `BRAM[i+1]` for `out[i]`, i in [0,N) | Skips phantom at BRAM[0]; reads all N samples Y[0..N-1] |
| `k_busy_wait(1)` after aresetn assert and release | Makes the PG109 ≥2 aclk-cycle requirement explicit |
| Post-IOC `S2MM_DMASR.IDLE` check | Detects spurious IOC delivered while channel still running |
| `0xDEADBEEF` sentinel at BRAM[N] | Hard-fails any DMA transfer that does not write Y[N-1] |
| `INTC_CH_OVFLO` → `INTC_CH_FRAME_DONE` | ch2 is `m_axis_status_tvalid` (frame-done), not overflow |

### Block design (`fpga/xem7310/ostomachion_bd.tcl`)

| Change | Reason |
|--------|--------|
| Both BRAMs: `Memory_Type {Single_Port_RAM}` | Serialises DMA writes and CPU reads through one port |
| Both BRAMs: `SINGLE_PORT_BRAM {1}` on AXI BRAM controller | Matches blk_mem_gen single-port mode |
| BRAM_PORTB connections removed | Port B no longer exists in single-port mode |
| Both BRAMs: `Write_Depth_A {8192}` | Power-of-2 depth; RX needs >4096 for N+1 transfer; TX matched for uniformity |
| TX BRAM address range `0x41000000`, `0x00008000` | Was 0x4000 (16 KB); matched to 8192-word depth |
| RX BRAM address `0x41008000`, range `0x00008000` | Was `0x41004000`; moved for 32K alignment requirement |

### DTS overlay (`zephyr_app/app_accel.overlay`)

| Change | Reason |
|--------|--------|
| TX BRAM reg `<0x41000000 0x8000>` | Was 0x4000; matches new 32 KB BRAM |
| RX BRAM reg `<0x41008000 0x8000>` | Was `0x41004000 0x4000`; new address and size |
| `dma-max-bytes = <16388>` | Maximum DMA RX transfer length: (N+1)×4 = 4097×4 bytes (renamed from `bram-size` for clarity) |

---

## Open questions

### Q1 — Is the phantom word real?

The +1 offset in BRAM is confirmed by experiment.  The explanation (xfft
C_ARCH=3 asserts tvalid for one word after aresetn de-assertion) is a
hypothesis consistent with PG109 but not directly measured.

Alternative explanations that have not been definitively ruled out:
- AXI DMA S2MM captures one word from xfft's registered output pipeline before
  the first real sample arrives, due to pipeline latency after aresetn release.
- The xfft natural-order sorter inserts a latency word before its first output
  that is unrelated to tvalid behaviour.

**What would confirm it:** An ILA probe on `M_AXIS_DATA_TVALID` and
`M_AXIS_DATA_TDATA` immediately after aresetn de-assertion, captured before
MM2S starts sending input.  If tvalid is high for one cycle before the first
real sample, the phantom word theory is confirmed.  The debug bitstream target
(`make fpga-synth` with `debug` arg) generates an ILA-instrumented bitstream
that could capture this.

### Q2 — Does the single-port BRAM fix actually solve the stale-read issue?

The stale-read symptom (3 dummy reads, all returning stale data) was diagnosed
as a dual-port BRAM write-ordering issue.  The single-port BRAM change was
applied but has not been tested on hardware yet — it was part of the same
bitstream rebuild as the depth/address changes.

If single-port BRAM does not eliminate the need for the dummy read, there may
be an additional source of stale reads (e.g., SmartConnect early BRESP even
on Port A, or XBUS pipeline register `XBUS_REGSTAGE_EN => true` in
`xem7310_top.vhd` adding latency on the CPU read path).

The dummy read fix is in place regardless and is inexpensive, so even if
single-port BRAM fully eliminates the stale read the dummy read does no harm
(it discards the phantom which needs to be skipped anyway).

### Q3 — Are all N output bins now correct end-to-end?

The combination of fixes covers:
- BRAM[0] phantom: discarded by dummy read
- Y[0..N-2]: read from BRAM[1..N-1] ✓
- Y[N-1]: captured at BRAM[N] by N+1 transfer ✓

This has not yet been validated on hardware after the bitstream rebuild.
The `fft dc`, `fft sine`, and `fft diag` shell commands (and the ZTEST suite
`test_fft_accel.cpp`) should all be run after the next bitstream flash.

---

## Pending actions

1. **Rebuild bitstream** — incorporates single-port BRAM, 8192-word depth, and
   new RX BRAM address `0x41008000`.
2. **Flash and run ZTEST** — `make test-accel-hw` after `make fpga-program`.
3. **Validate all bins** — in particular verify Y[4095] (bin 4095) is non-zero
   for a tone at bin 4088 (mirror of bin 8 in `test_single_tone`).
4. **ILA capture (optional)** — confirm or refute the phantom-word hypothesis
   by probing M_AXIS_DATA_TVALID after aresetn de-assertion.

---

## DMA architecture review — Phase 1 → Phase 4 (2026-04-26)

A broad audit of the FFT/DMA pipeline produced the following commit-ready
fixes.  Items left open are explicitly tagged *Deferred*.

### Resolution table

| Issue | Fix (this branch) | Status |
|-------|-------------------|--------|
| Issue 1 — INTC not initialised | MER + IER write at init | **Resolved** |
| Issue 2 — Spurious ISR re-entry | DMASR W1C before INTC IAR | **Resolved** |
| Issue 3 — Off-by-one on `out[0]` | N+1 DMA transfer + dummy read + sentinel safety net (3a hardening) | **Mitigated**; root-cause AXIS gate deferred to post-Phase-2 ILA |
| Issue 4 — Y[N-1] silently lost | byte_len = (N+1)×4; RX BRAM 8192 words; integrity sentinel at BRAM[N] | **Resolved** |
| Issue 5 — Stale BRAM reads | Single-port BRAM | **Resolved (RTL applied; on-hw verification pending)** |

### Phase 3a — Hardening (always-applicable, applied)

| File | Change |
|------|--------|
| `zephyr_app/tests/test_fft_accel.cpp` | Tightened `test_single_tone` to ±0-bin, added `test_dc_exact` (±5%), `test_no_off_by_one` (bin-1 cosine, ±0-bin), `test_y_n_minus_1` (verifies BRAM[N] non-zero) |
| `zephyr_app/drivers/accel/fft_accel.c` | Added explicit `k_busy_wait(1)` around xfft aresetn assertion and release (PG109 ≥2 aclk cycles); post-IOC S2MM `DMASR.IDLE` validation; transfer-integrity sentinel `0xDEADBEEF` written to BRAM[N] before each transform and re-read post-IOC (sentinel survival → hard `-EIO`); renamed `INTC_CH_OVFLO` → `INTC_CH_FRAME_DONE` (ch2 is frame-done, not overflow) |
| `zephyr_app/app_accel.overlay`, `dts/bindings/misc/ostomachion,fft-accel.yaml` | Renamed DTS property `bram-size` → `dma-max-bytes` (the value is the maximum DMA transfer length, not BRAM size) |
| `fpga/xem7310/build.tcl` | Expanded ILA debug probe set: now also marks `xfft_0/m_axis_data*` (TVALID, TLAST, TDATA), `xfft_rst_and/Res` (post-AND aresetn), and `axi_gpio_0/gpio_io_o*` for definitive phantom-word capture in a single experiment |

### Phase 3b — Root-cause AXIS gate (deferred)

Recommended fix is a TLAST-aware AXIS gate between `xfft_0/m_axis_data` and
`axi_dma_0/S_AXIS_S2MM` that drops any beat asserted before the first real
frame.  Once the gate is in place:

- `byte_len` returns to `N*4` (no +1)
- The driver's dummy read of `BRAM[0]` is removed
- Output loop becomes `out[i] = BRAM[i]`
- BRAM depth can return to 4096 words / 16 KB (RX may stay 32K-aligned)

Insertion point is documented in `fpga/xem7310/ostomachion_bd.tcl` at the
`xfft_0/m_axis_data ↔ axi_dma_0/S_AXIS_S2MM` connection ("Phase 3b — AXIS
phantom gate").  The gate change is gated on Phase 2 ILA evidence (Q1):

- **Outcome A** (TVALID=1 + TLAST=0 beat between aresetn rising edge and the
  first MM2S beat) — gate confirmed necessary; insert and update driver.
- **Outcome B** (no phantom; TLAST early-terminates at beat N) — restore
  `byte_len = N*4` without inserting a gate; the integrity sentinel will
  flag this case immediately as `-EIO` if the existing build still produces it.
- **Outcome C** (other) — fix targeted to the observed waveform.

### Phase 3c — Stale-read confirmation (deferred)

Only relevant once Phase 3b removes the dummy read.  Single-port BRAM is
expected to make the dummy read unnecessary; if a regression appears,
investigate `XBUS_REGSTAGE_EN => true` in `fpga/xem7310/xem7310_top.vhd`
and add an explicit `DMA_S2MM_DMACR` read-back as a memory barrier before
BRAM reads.

### Phase 2 — Settle the phantom hypothesis

The ILA infrastructure now covers the full set of nets needed for a single
debug capture to settle Q1 (`fpga/xem7310/build.tcl` debug section):

```
make fpga-synth FPGA_DIR=fpga/xem7310 -- -tclargs debug
make fpga-program BIT_FILE=build/xem7310/ostomachion_xem7310_debug.bit
# Open Vivado Hardware Manager → load build/xem7310/debug_probes.ltx
# Trigger on rising edge of xfft_rst_and/Res
# Capture xfft_0/m_axis_data_tvalid, m_axis_data_tlast for ~1024 cycles
```

The presence (or absence) of a TVALID=1 + TLAST=0 beat before the first
MM2S transfer is the deciding signal for the Phase 3b decision tree above.

### Phase 4 — Validation status

Compile-time validation completed on this branch:

- `west build -b neorv32/neorv32/minimalboot zephyr_app -- -DEXTRA_CONF_FILE='prj_accel.conf;prj_hw_test.conf'`
  → ROM 68 %, RAM 70 %; clean build of the FFT driver (with sentinel + reset
  timing + S2MM IDLE validation), the renamed `dma-max-bytes` DTS property,
  and the tightened ZTEST suite (`test_dc_exact`, `test_no_off_by_one`,
  `test_y_n_minus_1`, exact-bin `test_single_tone`).
- `west build -b neorv32/neorv32/minimalboot zephyr_app -- -DEXTRA_CONF_FILE=prj_shell.conf`
  → ROM 94 %, RAM 74 %; clean build of `fft_shell.c` against the renamed
  driver fields.

Twister parses the test root but stops on a pre-existing platform name
(`xem7310` HIL configurations have no in-tree board definition); fixing that
parser-level error is independent of this audit and is filed as a follow-up.

Pending hardware validation (requires bitstream + XEM7310 board):

1. `make fpga-synth -- -tclargs debug` then `make fpga-program` of the debug
   bitstream and run the Phase 2 ILA capture per the procedure above.
2. `make test-accel-hw` to execute the tightened ZTEST suite — any future
   off-by-one regression will surface as either a `test_no_off_by_one`
   failure (peak at bin 0/2 instead of bin 1) or a sentinel-survival
   `-EIO` from `fft_accel_transform()`.
3. `make shell-hw` and run `fft dc`, `fft sine 1`, `fft sine 8`,
   `fft sine 4088` for visual confirmation that `Y[N-1]` is captured.
