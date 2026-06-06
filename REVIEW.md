# Ostomachion — Architectural Contract & Review Ledger

This file is the **standing architectural contract** for the Ostomachion
platform: the load-bearing invariants the implementation must keep, each stated
in active voice with the failure mode that appears when the rule is broken and
the test or constraint that enforces it. It complements
[ACCEL_ARCH.md](ACCEL_ARCH.md) (the FFT-pipeline contract) and
[CLAUDE.md](CLAUDE.md) (the architecture-rules summary).

It is **not** a point-in-time changelog. Treat every clause in §2–§8 as a rule
that a reviewer or a CI gate must be able to check. §9 is the live ledger of
open items; close items by fixing them and deleting the row, not by re-muting
the gate that would catch them.

> **How to use this file when you change the design**
> 1. If you touch a subsystem in §2–§8, re-read its clauses first; they encode
>    decisions that were paid for with real hardware debugging.
> 2. If a clause stops being true, the change is either a bug or a contract
>    amendment — never silent. Update the clause and its enforcing test in the
>    same commit.
> 3. New defects, drift, and robustness gaps go in §9 with a file:line anchor.

**Verification basis (RC1 — `master` @ the host-filter-control gateware).** This
ledger was produced by a top-to-bottom review (RTL, block design, Zephyr
firmware, host tooling, CI, docs) cross-checked against source — including the
NEORV32 v1.11.6 submodule RTL (`neorv32/rtl/core/*.vhd`) for every
register-bitfield and hardware-behaviour claim. Synthesis evidence is current
for the gateware: the staged Vivado 2025.1 (`xc7a200tfbg484-1`) build
(`build_id` = `43ab2d0`, **which is the merged host-filter-control RTL** — WireIn
0x01 / WireOut 0x28 / the widened XBUS decode / the two filter CDCs) **passed**
the quality gates — **WNS +0.042 ns, WHS +0.015 ns, 0 failing endpoints, DRC
clean**, bitstream + MCS written. The only `master` commits after it (the PyQt
demo and the docs pass) touch **no `fpga/` files**, so the bitstream represents
`master`'s gateware; `git log 43ab2d0..HEAD -- fpga/` is empty. The
filter datapath is **HW-verified on the XEM7310** (§5a). The one verification
item re-confirmed for RC1 is the **GHDL + Zephyr co-simulation gate** (§8,
`make test-zephyr` → `PROJECT EXECUTION SUCCESSFUL`, no failing suite); it is
the single CI gate that must be green on the RC commit before tagging.

---

## 1. Overall assessment

The architecture is sound and unusually disciplined. The boundary model — the
CPU reaches the accelerator **only** through the AXI map (DMA registers + BRAM
windows + INTC), while the host PC reaches FrontPanel wires/pipes in parallel —
is clean and consistently enforced in fabric (SmartConnect address exclusions),
not merely by convention. The block design is genuinely recreated from Tcl with
no checkpoints in the tree; the xfft scaling schedule is arithmetically exact;
the CDC structures gate correctly on XPM reset-busy; the data-memory fences in
the FFT driver are correctly placed; and the timing constraints close with a
structural clock-group exception rather than fragile name-matched globs.

The residual risk does **not** live in the datapath. The two functional defects
the earlier review found — the WDT lock that never engaged and the I2C
zero-length dereference — are **fixed and merged** (collapsed into §6); the
comment/docstring drift is reconciled. What remains for RC1 is **verification
coverage, not correctness**: a handful of gaps where a real behaviour is proven
by hand (HIL / interactive shell) but has no automated CI gate, so a future
change could regress it silently. These are enumerated in §9 with an RC1
disposition (BLOCKER / ADVISED / NICE); none is a datapath defect.

> **RC1 go/no-go in one line:** gateway and datapath are GO (synthesis current
> and HW-verified — see the verification-basis header and §5a); the single hard
> gate before tagging is confirming the GHDL+Zephyr co-sim green on the RC
> commit (§8 / §9 intro). Everything else in §9 is an ADVISED/NICE coverage
> hardening, to be accepted or scheduled explicitly — never muted.

The single highest-leverage discipline remains **treat docs as code**: every
guarantee a comment states must be one a test or constraint enforces, and every
"fixed" claim must be re-checked against the tree it now lives in.

---

## 2. Datapath ordering contract (FFT driver)

Source: [`zephyr_app/drivers/accel/fft_accel.c`](zephyr_app/drivers/accel/fft_accel.c).
These clauses are verified-correct in the current tree; do not regress them.

### 2.1 Data-memory fences bracket every BRAM↔DMA handoff
The driver issues `barrier_dmem_fence_full()` **after** the TX-BRAM fill loop
(before any DMA register write) and again **after** `k_sem_take()` succeeds
(before the RX-BRAM read loop).

> **Why:** the TX/RX BRAMs and the DMA control registers are *different* AXI
> slaves behind the SmartConnect, which gives no global write-ordering
> guarantee. `sys_write32` is only a compiler-ordering barrier. NEORV32 has no
> D-cache, so this is a store/load-ordering problem, not a coherency one.
> **Failure mode without the fences:** the MM2S `LENGTH` trigger overtakes the
> final BRAM store and the DMA reads stale input for the last beat(s); the CPU
> read loop observes pre-DMA RX-BRAM contents.

### 2.2 `k_sem_reset()` sits *after* both DMA resets and *before* arming
The semaphore is reset once both channels are quiesced (software-reset complete,
xfft back out of reset) but before either channel is armed.

> **Failure mode if reset earlier (before the ~4096-word fill):** a late
> IOC/ERR ISR from a previously timed-out transfer slips a stale `k_sem_give()`
> through the fill window; the next `k_sem_take()` returns immediately on bogus
> data. **Enforcing test:** `test_sequential` (two back-to-back transforms;
> the second is all-zero and every output bin must be ~0).

### 2.3 ISR clears DMA `DMASR` (W1C) before acknowledging INTC `IAR`
Each per-channel ISR branch writes the DMASR IRQ bits back (W1C) to de-assert
`mm2s_introut`/`s2mm_introut`, *then* writes the channel mask to `INTC_IAR`.

> **Failure mode if IAR first:** for level-sensitive channels the INTC ISR bit
> re-asserts on the next edge because the source line is still high; the CPU
> re-enters the ISR and `k_sem_give()` fires twice. See ACCEL_ARCH §4.7.

### 2.4 S2MM is armed before MM2S; both use symmetric `N×4` byte counts
See ACCEL_ARCH §4.3–§4.4. S2MM's `TREADY` must be high before xfft output
begins (nonrealtime throttle mode back-pressures the whole pipeline otherwise),
and the xfft emits exactly N beats per N-point frame so no `(N±1)` correction is
needed. **Enforcing tests:** `test_single_tone`, `test_no_off_by_one` (exact
peak bin, zero tolerance), `test_y_n_minus_1`.

---

## 3. Clock-domain-crossing contract (board RTL)

Source: [`xem7310_top.vhd`](fpga/xem7310/xem7310_top.vhd),
[`fp_fft_pipe_bridge.vhd`](fpga/xem7310/fp_fft_pipe_bridge.vhd),
[`fp_uart_bridge.vhd`](fpga/xem7310/fp_uart_bridge.vhd).

### 3.1 Every `xpm_fifo_async` gates its enables on reset-busy
All four async FIFOs across the two bridges expose `wr_rst_busy`/`rd_rst_busy`
and AND them into the corresponding `wr_en`/`rd_en` **and** into the host
handshake flags (`pi_ready`/`po_ready`/`tx_ready`/`rx_ready`). The busy flags
are consumed in their own clock domain, so this adds no new CDC.

> **Why:** XPM **drops** writes/reads issued while reset-busy is asserted. Each
> reset (the FIFOs take `rst <= not sys_rstn`, an `aclk`-domain reset, while
> straddling `aclk`↔`fp_clk`) otherwise opens a silent data-loss / lockup
> window. Do not tie these flags to `open`.

### 3.2 The cycles/frame-count CDC uses `xpm_cdc_array_single`, **not** a handshake
`cdc_cycles_i` and `cdc_frame_i` are per-bit 2-FF synchronisers.

> **Why this is correct, and why the handshake was rejected:** firmware writes
> `cycles_sys` and bumps `frame_count_sys` on the *same* `sys_clk` edge
> (`REG_PUBLISH`), and both hold constant thereafter. `frame_count_sys` is a
> monotonic counter, so any bit-skew the host could observe is bounded to
> `old → new` — never an out-of-sequence value. A prior rewrite to
> `xpm_cdc_handshake` **introduced a real on-hardware defect**: when a firmware
> publish arrived while the previous handshake was still acknowledging
> (`cdc_busy=1`), the publish was silently dropped, `frame_count_fp` fell behind
> `frame_count_sys` by one, and the host waited forever. **Do NOT switch this
> CDC back to a handshake.** Synthesis success masked the bug; only on-board USB
> load surfaced it. (The in-code comment now states the correct
> same-edge-publish rationale and carries a "do NOT reintroduce a handshake"
> warning.)

### 3.3 The beat-counter status words are staged into `okClk` before sampling
There are **two** `fft_beat_counter` instances — one on the `xfft_0` (forward)
output, exposed on `okWireOut` **0x22/0x23**, and one on the `xfft_1` (inverse)
output, exposed on **0x27** (the filtered-path analogue; proves the N-beat /
TLAST-on-`N−1` invariant survives `cmpy`+normalizer+IFFT — §5a). All cross
`aclk → okClk` through `xpm_cdc_array_single` before the WireOut samples them.
They are quasi-static (change only on `tlast`/`aresetn`), so per-bit
synchronisers are sufficient and the host reads them between frames. `okWireOut`
0x28 carries the firmware filter-status echo (§5b). `FP_EP_COUNT` is **13**
([`xem7310_top.vhd:262`](fpga/xem7310/xem7310_top.vhd#L262)); WireIns (0x00 UART
cfg, 0x01 filter cfg) produce no `okEH` output and are not counted.

### 3.4 The XBUS FFT-pipe region decodes the full in-region offset
The demux selects `fp_fft_pipe_bridge` only when
`adr[31:28]=0x9 AND adr[27:5]=0` ([`xem7310_top.vhd:681-682`](fpga/xem7310/xem7310_top.vhd#L681-L682)),
so exactly `0x9000_00{00..1F}` — a **32-byte, six-register** window — hit the
bridge: `0x00` POP, `0x04` PUSH, `0x08` STATUS, `0x0C` PUBLISH, `0x10`
FILTER_CFG (R), `0x14` APPLIED (W). The host-filter-control work widened this
from the original four-register / `adr[27:4]` window when it added the filter
cfg + status-echo registers ([`fp_fft_pipe_bridge.vhd:103-108`](fpga/xem7310/fp_fft_pipe_bridge.vhd#L103-L108);
bridge `xbus_addr` is `std_ulogic_vector(4 downto 0)`).

> **Failure mode if the offset is under-decoded:** every 32-byte-aligned address
> in the 256 MB `0x9xxx_xxxx` region aliases onto the bridge registers, so a
> stray access silently pops/pushes a sample (or rewrites the filter cfg). Any
> other in-region address falls through to the BD bridge (unmapped there →
> `xbus_err`). The in-window gap offsets (`0x18`/`0x1C`) read 0 via the
> bridge's `others` arm.

### 3.5 Single-bit BD ports sourced from a vector are `std_logic_vector(0 downto 0)`
`fft_status_overflow` and `xfft_aresetn` are declared as `(0 downto 0)` and
indexed `(0)` at use sites, matching how the generated wrapper emits ports
sliced from a vector.

> **Why:** declaring them scalar `std_logic` is a type error that fails
> `synth_design` elaboration — and is invisible to GHDL, so it only appears in
> Vivado. (This bit the M1 overflow work once already.)

### 3.6 The host-filter-control words cross with `xpm_cdc_array_single`, like cycles/frame
Two further crossings were added with the host filter control path
([`fp_fft_pipe_bridge.vhd:476,491`](fpga/xem7310/fp_fft_pipe_bridge.vhd#L476-L491)):
`cdc_filter_cfg_i` carries the host filter control word (WireIn 0x01) `fp_clk →
sys_clk`, and `cdc_applied_i` carries the firmware status echo `sys_clk →
fp_clk` (WireOut 0x28). Both are per-bit `xpm_cdc_array_single`, for the same
reason as §3.2: each word is quasi-static (the host updates the cfg a few times
per second and then holds it; the firmware writes the echo on one `sys_clk` edge
and holds it).

> **Why a handshake is wrong here too, and how word-coherence is handled:** the
> §3.2 "do NOT reintroduce a handshake" rule applies identically. The one extra
> hazard — a host `UpdateWireIns` can momentarily *tear* the multi-field cfg word
> (mode/lo/hi) mid-update — is closed in **firmware**, not RTL: the demo reads
> the cfg twice and acts only when two reads agree (the double-read debounce,
> §5b). Do not add an RTL handshake to "fix" tearing; it would re-create the
> dropped-publish defect §3.2 documents.

---

## 4. Timing-closure contract (constraints)

Source: [`xem7310.xdc`](fpga/xem7310/xem7310.xdc),
[`build.tcl`](fpga/xem7310/build.tcl),
[`check_build.tcl`](fpga/xem7310/check_build.tcl).

### 4.1 Asynchronous clock groups are the *primary* CDC exception
`set_clock_groups -asynchronous` declares `sys_clk`, `okUH0`, and `jtag_tck`
mutually asynchronous, each with `-include_generated_clocks`. This cuts every
`sys_clk ↔ okClk ↔ jtag` crossing **structurally**, independent of instance
names. The per-instance `set_false_path` globs that follow are retained as
self-documenting belt-and-suspenders; they are subsumed but harmless.

> **Why structural, not glob-only:** a name-matched `set_false_path` silently
> matches nothing if an instance is renamed, quietly re-timing a real CDC path.
> **Verified on the implemented checkpoint:** the cross-domain
> `mmcm0_clk0 → okUH0` paths report large positive slack (≈ +4.8 ns), so they no
> longer constrain closure; the worst path (+0.042 ns) is intra-domain in the
> `~100.8 MHz` FIFO logic. The full build closes at **WNS +0.042 / WHS +0.023,
> 0 failing endpoints**.

### 4.2 The thin +42 ps worst-path margin is a pre-existing design property
The worst setup path lives in the `~100.8 MHz okClk` FIFO domain and is the same
on `master` as on any datapath-only branch. It is **not** a regression from the
fence/CDC/overflow work. Treat any drop below ~+40 ps as a real regression to
investigate, not noise.

### 4.3 Quality gates query structured results, never grep report text
`build.tcl`/`check_build.tcl` gate on `get_drc_violations` filtered to
`Error`/`Critical` severity and on `WNS/WHS >= 0` from `get_timing_paths` — not
on `regexp {ERROR}` over report text (which false-matches rule names).
`check_build.tcl` additionally flags unconstrained timing endpoints.

> **Current DRC state:** clean — the only violations present are WARNING-severity
> REQP entries from the FrontPanel okHost IP, which the severity filter
> correctly ignores.

---

## 5. Accelerator block-design contract

Source: [`ostomachion_bd.tcl`](fpga/xem7310/ostomachion_bd.tcl). All
verified-correct; the inline derivation comments are load-bearing — keep them.

- **xfft scaling word `0x1555` (5461) = exact unity gain.** Bit 0 = FWD; six
  2-bit `SCALE_SCH` fields each `0b10` (÷4) cancel the radix-4 butterfly gain
  `4^6 = 4096`. This is the conservative schedule under which in-range Q1.15
  input cannot overflow an intermediate stage. **Do not "optimise" the schedule
  without re-running the overflow sweep** (`fft overflow` shell command).
- **SmartConnect address isolation is structural.** `Data_MM2S` is assigned only
  `tx_bram` and excludes the DMA lite regs, `rx_bram`, `intc`, and `gpio`;
  `Data_S2MM` is assigned only `rx_bram` with the symmetric exclusions. A runaway
  descriptor cannot scribble the wrong BRAM or a control register.
- **INTC `C_KIND_OF_INTR = 0x4`:** Ch0 (MM2S) and Ch1 (S2MM) level-sensitive;
  Ch2 (xfft frame-done) edge-sensitive — required because
  `m_axis_status_tvalid` is a one-cycle pulse that a level channel would miss.
- **Overflow readback path (M1):** the BD slices `m_axis_status_tdata[0]` out
  (width-querying the pin so a non-1-bit status bus still works), `xem7310_top`
  latches it sticky (cleared by the per-transform `aresetn`), and the AXI GPIO
  *input* channel (`C_IS_DUAL=1`) exposes it at `GPIO_DATA2` (0x08) bit 0.
  Verified end-to-end on hardware via the `fft overflow` amplitude sweep.

---

## 5a. Programmable filter pipeline contract (FFT → filter → IFFT)

Source: [`ostomachion_bd.tcl`](fpga/xem7310/ostomachion_bd.tcl),
[`spectral_filter.vhd`](fpga/xem7310/spectral_filter.vhd),
[`cmpy_normalizer.vhd`](fpga/xem7310/cmpy_normalizer.vhd),
[`xem7310_top.vhd`](fpga/xem7310/xem7310_top.vhd),
[`fft_accel.c`](zephyr_app/drivers/accel/fft_accel.c),
[`filter_mask.hpp`](zephyr_app/include/ostomachion/filter_mask.hpp).
Full architecture: [ACCEL_ARCH.md §7](ACCEL_ARCH.md).

The forward FFT is extended into a programmable frequency-domain transform:
time → `xfft_0` → per-bin complex multiply `H[k]·X[k]` (`spectral_filter`) →
Q2.30→Q1.15 round/saturate (`cmpy_normalizer`) → `xfft_1` (inverse) → time. A
GPIO bypass bit selects the S2MM source so one bitstream serves both the plain
forward FFT and the filtered round trip.

- **Single multiply stage was a timing trap — now pipelined.** The first
  `fpga-synth` of the datapath FAILED at **WNS −4.376 ns**: the worst path ran
  coeff-BRAM(RAMB36) → 2× DSP48E1 → 8× CARRY4 → normalizer in ONE cycle (13
  logic levels, 14.255 ns logic). The complex multiply is now split into
  registered product (stage 2) and sum (stage 3) stages that map onto the
  DSP48E1 pipeline; TVALID/TLAST are pipelined identically so the N-beat /
  TLAST-on-`N−1` invariant holds (filter latency `L = 3 + NORM_LATENCY`).
- **`cmpy_normalizer` reduction == firmware `sat_round_q15`.** Round-half-up
  `>>15` + saturate, verified bit-for-bit against the C++ reference (host test
  `test_filter_mask` + a local GHDL TB). This is why on-CPU mask composition
  (`compose_mul`/`compose_max`) predicts the fabric result.
- **coeff BRAM is the one true-dual-port exception (vs §4.2 single-port).** CPU
  writes Port A under the driver mutex while no transform runs; the filter reads
  Port B during a transform; the two never touch the same address. Port B keeps
  `READ_LATENCY=1` (no output register) and is latency-compensated against `X`,
  so `H[k]` aligns with `X[k]` — an added register shifts the mask one bin.
- **Inverse scaling word `0x1554` (÷N) is the production default.** Forward +
  inverse both ÷N gives a `1/N` round-trip (attenuated, overflow-safe). The
  unscaled `0x0000` (exact-identity ×filter, but can overflow) is for the
  low-amplitude all-pass demo ONLY. See ACCEL_ARCH §7.1 for the gain budget.
- **Channel map preserved.** INTC Ch2 frame-done is re-sourced from `xfft_1`
  (IFFT done); `NUM_PORTS`, `C_KIND_OF_INTR`, IER, and the ISR are UNCHANGED.
  GPIO widened to 2 bits each way (ch1 bit1 = bypass, ch2 bit1 = aggregated
  overflow). Address map adds only coeff BRAM at `0x4200_0000`/16 KiB,
  CPU-only, excluded from both DMA spaces.

> **🔍 HW-verification status.** Vivado 2025.1 (`xc7a200tfbg484-1`):
> - **PR3 (coeff BRAM only):** `fpga-synth` PASSED — WNS **+0.042 ns**, WHS
>   +0.012, DRC clean, LUT 11.64 %, BRAM 27.53 %.
> - **PR4 (full filter datapath):** `fpga-synth` PASSED — WNS **+0.042 ns**
>   (identical to master's pre-existing worst path — zero timing regression),
>   WHS +0.022, DRC clean, LUT 14.13 %, BRAM 30.14 %, bitstream written. The
>   −4.376 ns single-stage path was fixed by the multiply pipelining above.
> - **On-DUT HIL — CONFIRMED on the XEM7310 (serial 2537001HTD).** Programmed
>   the filter bitstream and ran the full `make test-accel-hw` ZTEST image:
>   - `ostomachion_fft` **14/14 PASS** (the 8 forward-FFT tests + the 6 filter
>     tests), `ostomachion_filter_mask` **7/7 PASS**.
>   - **N-beat invariant through the filter chain:** WireOut beat counter read
>     `last_frame = 4096 = N`, **Outcome A (PG109-correct, no phantom beat)** on
>     every observed frame — so `cmpy`+normalizer+`xfft_1` preserve exactly N
>     beats to S2MM.
>   - **Brick-wall response** (time-domain output energy, pass-tone vs stop-tone
>     — robust to the ÷N round-trip attenuation): lowpass 34499 vs 2163 (**16×**),
>     highpass 35640 vs 2598 (**14×**), notch 34821 vs 2731 (**13×**).
>   - **Bypass == plain:** `transform()` on the filter bitstream peaks at the
>     forward-FFT bin (bin 8), and all-pass round trip is non-zero with no
>     overflow. **M-finding verdict: fully verified on hardware.**
>
> *(Two pre-existing bugs surfaced during bring-up and were fixed here:*
> *(1) `make test-accel-hw`/`test-hw` never passed `-DCONFIG_ZTEST=y`, so the*
> *HIL image had no tests at all — added the flag.  (2) the brick-wall ztests*
> *re-FFT'd the ÷N-attenuated round-trip output, landing in the quantization*
> *floor (`pass 7 / stop 15`); rewritten to compare time-domain pass/stop tone*
> *energy.  The `i2c`/`spi` suites still FAIL on this DUT — they need the MC1*
> *loopback jumper / I2C-slave hardware that is not fitted, unrelated to the*
> *accelerator.)*

**Enforcing tests:** host `test_filter_mask` (mask math); on-sim
`ostomachion_filter_mask` (links/runs on NEORV32); HIL `test_filter_allpass_roundtrip`,
`test_filter_lowpass`/`highpass`/`notch`, `test_filter_beat_count_invariant`,
`test_filter_bypass_equals_plain` — **all green on the XEM7310**.

---

## 5b. Host-driven filter control contract (FrontPanel → firmware)

Source: [`xem7310_top.vhd`](fpga/xem7310/xem7310_top.vhd),
[`fp_fft_pipe_bridge.vhd`](fpga/xem7310/fp_fft_pipe_bridge.vhd),
[`fft_demo_main.c`](zephyr_app/src/fft_demo_main.c),
[`tools/fft_demo/`](tools/fft_demo/). The PyQt demo programs the fabric filter
live: the host picks a mode and the firmware loads the coeff BRAM and runs the
filtered round trip. The control path the host crosses into is:

- **WireIn 0x01 → XBUS `0x10` (filter cfg), WireOut 0x28 ← XBUS `0x14` (status
  echo).** Both CDC'd `array_single` (§3.6). The cfg word packs `{mode, lo, hi}`;
  the echo packs `{applied_mode, filter_avail, last_overflow, last_failed}`.
- **Double-read debounce closes the multi-field tear window.** Firmware reads
  the cfg word twice (straddling the frame-pop) and reprograms coefficients only
  when two reads agree **and** the value differs from the last applied
  ([`fft_demo_main.c`](zephyr_app/src/fft_demo_main.c)).
  > **Failure mode without it:** a host `UpdateWireIns` mid-update is sampled
  > torn (new `mode` with old `hi`), triggering a one-frame nonsense mask or a
  > spurious reload. This is the §3.6 hazard, closed in firmware (never with an
  > RTL handshake — see §3.2/§3.6).
- **Status echo is publish-before-the-host-sees-it, and the host never
  misreads freq-vs-time.** The echo reports the mode actually applied, so the
  host knows whether a returned frame is forward-FFT bins (bypass) or the
  filtered ÷N time-domain signal. At most one transitional frame at a mode change.
- **Graceful degrade on a forward-only bitstream.** `fft_accel_load_coeffs`
  returns `-ENOTSUP` when no coeff BRAM is present; the firmware falls back to
  the plain forward FFT and reports `filter_avail = 0`, so the same host tool is
  safe against either bitstream (the WireIn write is a harmless no-op there).

> **Enforcing tests:** exercised indirectly on the XEM7310 by the §5a brick-wall
> HIL tests (which drive this exact path) and the host `tools/fft_demo`
> mask-replica + offscreen-UI unit tests. **Coverage gap (open):** the debounce
> itself and the PyQt client have no automated regression gate — see §9.

---

## 6. Peripheral-driver contract

Source: [`i2c_neorv32.c`](zephyr_app/drivers/i2c/i2c_neorv32.c),
[`spi_neorv32.c`](zephyr_app/drivers/spi/spi_neorv32.c),
[`wdt_neorv32.c`](zephyr_app/drivers/wdt/wdt_neorv32.c). Register bitfields below
are re-confirmed against NEORV32 v1.11.6 RTL.

- **SPI polling pattern is upstream-correct.** `put → while(BUSY) → read DATA`
  is valid because `SPI_CTRL_BUSY` (bit 31) is RTL-defined as
  `rtx_engine.busy OR tx_fifo not empty` (`neorv32_spi.vhd:172`), so when it
  clears the full-duplex byte is complete and the RX FIFO holds the result. The
  clock-field shifts (`PRSC<<3`, `CDIV<<6`, `HIGHSPEED=BIT(10)`,
  `IRQ_RX_AVAIL=BIT(20)`) all match the RTL constants.
- **SPI ISR guards the chained TX write.** A `TX_FULL` slot completes the
  transfer with `-EIO` rather than silently dropping a byte (which would stall
  until the spi_context timeout).
- **I2C ISR checks every `twi_*_nb()` push and issues at most one STOP per path.**
  The STOP-flag decision reads `msgs[msg_idx]` *before* `msg_idx++` (no
  one-past-the-end read on the final message). A bounded `TWI_XFER_TIMEOUT`
  (1 s) backstops a lost FIRQ so a dropped interrupt cannot hang the caller
  forever.
- **The I2C interrupt path skips zero-length messages, like the polling path.**
  The IRQ state machine skips leading zero-length messages at transfer start and
  trailing ones at each `next_msg` advance
  ([`i2c_neorv32.c:421-457`](zephyr_app/drivers/i2c/i2c_neorv32.c#L421-L457)).
  > **Failure mode without the skip:** a zero-length message (I2C bus scan /
  > SMBus quick command) dereferences `buf[0]` of an empty buffer and clocks one
  > stray byte. HW-only path (`CONFIG_I2C_NEORV32_INTERRUPT`); the GHDL sim uses
  > the polling path, so this is verified by construction against the polling
  > path it now mirrors.
- **WDT lock requires a *two-step* enable-then-lock write.** STRICT alone does
  not prevent a plain `CTRL = 0` disable — only the LOCK bit does — and
  [`neorv32_wdt.vhd:95`](neorv32/rtl/core/neorv32_wdt.vhd#L95) latches LOCK only
  if EN is *already* set (`ctrl.lock <= data(lock) and ctrl.enable`). So
  `wdt_setup()` writes `EN|STRICT|TIMEOUT` first, then a second write OR-ing in
  `LOCK` ([`wdt_neorv32.c:68-72`](zephyr_app/drivers/wdt/wdt_neorv32.c#L68-L72)),
  so EN is high when LOCK latches. A single combined write silently no-ops the
  lock.
  > **Lesson (paid for in hardware semantics):** synthesis and compile cannot
  > catch a combined-write lock no-op — it is a register-behaviour contract.
  > **Coverage gap (open):** no automated test asserts `disable()` returns
  > `-EPERM` under `CONFIG_WDT_NEORV32_LOCK=y` — see §9.1.

---

## 7. Host-tooling contract

Source: [`tools/fft_demo/`](tools/fft_demo/), [`scripts/`](scripts/).

- **The FrontPanel handle lives entirely on the worker `QThread`.** It is
  created, opened, used, and closed only on that thread (the Opal Kelly handle
  is not thread-safe); the GUI thread renders via queued signals. `closeEvent`
  stops and joins the worker, and `transport.close()` releases the device via
  `IsOpen()/Close()` so a lingering handle cannot block the next open.
- **Frame ordering is publish-before-push.** Firmware writes `REG_PUBLISH`
  (latches `cycles_sys` *and* bumps `frame_count_sys` on one edge) before pushing
  the output frame, so when the host sees `frame_counter` advance, `hw_cycles` is
  already valid. Wrap is handled by `(n - prev) & 0xFFFFFFFF`.
- **Q1.15 wire format is `{im[31:16], re[15:0]}` little-endian** and is
  consistent across host pack/unpack, the RTL bridge, and the firmware
  (`fft_demo_main.c`, `fft_accel.c`). Verified end-to-end.

---

## 8. CI / build-gate contract

Source: [`.github/workflows/ci.yml`](.github/workflows/ci.yml),
[`vivado-synth.yml`](.github/workflows/vivado-synth.yml),
[`Makefile`](Makefile), [`testcase.yaml`](zephyr_app/testcase.yaml).

Every gate must be able to **fail**. The following hold today; keep them:

- Every piped CI step sets `set -o pipefail`; there are no `|| true` masks.
- clang-tidy runs with `--warnings-as-errors='*'` (overriding the empty
  `WarningsAsErrors` in `.clang-tidy`), so any finding fails the step.
- The `nm` step selects an installed RISC-V binary and exits 1 if none/the ELF
  is missing, keeping error text out of the uploaded memory map.
- Twister builds a real project at the `zephyr_app/` root and excludes the `hw`
  tag; the DRC/timing gates are severity-aware (§4.3).
- `make test-zephyr` passes only on non-empty UART output **and**
  `PROJECT EXECUTION SUCCESSFUL` **and** the absence of `FAIL -`/`Assertion
  failed`/`FATAL`/failed-suite markers.
- The firmware-analysis build uses `prj.conf` (a real production image; ZTEST is
  opt-in, never baked into the base config).
- Third-party GitHub Actions are SHA-pinned with version comments.

> **Known robustness gaps in these gates are tracked in §9.2–§9.3.** They do not
> make a gate inert *today*, but they would let one pass silently under a future
> layout change.

---

## 9. Open ledger

Each item is a confirmed defect, drift, or robustness gap with a source anchor.
Close an item by fixing it and deleting its row. Items resolved on a branch stay
recorded under §9.0 (with the durable lesson) until the PR merges, then collapse
into the relevant §2–§8 clause.

### 9.0 — Resolved & collapsed (PR #6, merged `fc3b354`)

The "Review pass 2" findings are **merged on `master`** and their durable rules
now live in the §2–§8 clauses — per this file's own rule, the rows are collapsed
rather than carried:

- **WDT LOCK two-step write** (was 9.1) → §6 "WDT lock requires a two-step
  enable-then-lock write". *Code fixed; the `-EPERM`-under-lock test gap is the
  one piece that remains open — re-filed as §9.1 below.*
- **I2C interrupt-path zero-length skip** (was 9.2) → §6 "The I2C interrupt path
  skips zero-length messages".
- **Doc/comment drift** (was 9.3–9.7) → corrected in the relevant clauses
  (overflow GPIO-latch readback in §5; AXI-INTC topology; the `fp_fft_pipe_bridge`
  same-edge-publish rationale folded into §3.2/§3.6).

### Open for RC1

Each item is a confirmed gap with a source anchor and an RC1 disposition
(**BLOCKER** / **ADVISED** / **NICE**). Close by fixing and deleting the row.

#### 9.1 — ADVISED — no automated test that WDT LOCK blocks `disable()`
The two-step lock is fixed in code (§6), but no ZTEST asserts `wdt_disable()`
returns `-EPERM` under `CONFIG_WDT_NEORV32_LOCK=y` — it is a HW-semantics
contract a compile cannot catch, and the Kconfig defaults off.
> **Fix:** a HIL ZTEST that enables the lock and asserts `disable()` → `-EPERM`.

### CI robustness gaps (latent, not inert today)

#### 9.2 — ADVISED — clang-tidy / Twister can pass on an empty selection
[`ci.yml`](.github/workflows/ci.yml): the clang-tidy step pipes the
selected-file list into `xargs` **without `-r`/`--no-run-if-empty`**, and GNU
`xargs` runs the command once on empty input (verified: exit 0). If the path
filter ever selects zero files, clang-tidy processes nothing and the gate passes
silently. Likewise Twister exits 0 if `--integration` narrows the selection to
zero testcases.
> **Fix:** assert the file list is non-empty before `xargs` (and/or add `-r`);
> after Twister, assert ≥1 testcase actually built/ran.

#### 9.3 — ADVISED — accelerator/WDT drivers are never linted; no ZTEST covers overflow
The firmware-analysis build uses `prj.conf`, so `drivers/accel/fft_accel.c`
(gated `CONFIG_FFT_ACCEL`) and `drivers/wdt/wdt_neorv32.c`
(gated `CONFIG_WDT_NEORV32`) are absent from `compile_commands.json` and never
tidied — both are on CLAUDE.md's "do not change casually" list. Separately, the
overflow path (§5, ACCEL_ARCH §2.3) is verified only by the interactive
`fft overflow` shell command, never by an automated ZTEST, so CI cannot regress
the M1 chain.
> **Fix:** run a second clang-tidy pass against a config that enables
> `CONFIG_FFT_ACCEL`/`CONFIG_WDT_NEORV32`, and add a ZTEST that asserts
> `overflow == false` for an in-range frame (the positive-assertion case needs
> the deliberately under-scaled bitstream and stays HIL-only).

#### 9.4 — ADVISED — `test_y_n_minus_1` is a weak guard for the under-length-S2MM mode
[`test_fft_accel.cpp`](zephyr_app/tests/test_fft_accel.cpp) asserts only
`mag_sq(g_out[4095]) > 0`. Because the file-scope buffer is reused, a stale value
left in `BRAM[4095]` by a prior frame would also pass. **Fix:** clear
`g_out[N-1]` to a sentinel before the transform, or assert it is comparable to
the symmetric peak `g_out[1]`.

#### 9.5 — NICE — the host filter control path has no automated regression gate
The §5b firmware double-read debounce and the `tools/fft_demo` PyQt client are
exercised only by the §5a HIL brick-wall tests and host-side unit tests run
by hand; neither the debounce nor the GUI has a CI gate. Not RC1-blocking (the
datapath they drive is HIL-verified), but a future change could silently break
the freq-vs-time interpretation or the tear-window guard.
> **Fix:** add the `tools/fft_demo` mask-replica + offscreen-UI tests to CI
> (`host-tests`-style), and a sim/HIL assertion on the applied-status echo.

---

## 10. Verified-correct, do-not-regress (quick index)

These were checked against source (and, where noted, NEORV32 v1.11.6 RTL) and
are correct. They are the implicit acceptance set for any future change.

- xfft `0x1555` = ÷4096 exact unity gain; SmartConnect MM2S/S2MM isolation;
  INTC edge/level per channel; the dual-channel GPIO overflow readback.
- The FFT driver fences (§2.1), `k_sem_reset` ordering (§2.2), ISR W1C→IAR
  ordering (§2.3), S2MM-before-MM2S arming and symmetric `N×4` (§2.4).
- All four XPM FIFOs gate on reset-busy (§3.1); `array_single` (not handshake)
  for cycles/frame-count (§3.2); beat-counter staging (§3.3); the XBUS region
  decode (§3.4); `(0 downto 0)` port typing (§3.5).
- `set_clock_groups -asynchronous` as the primary CDC cut; the build closes at
  WNS +0.042 / WHS +0.023 with 0 failing endpoints; DRC clean (§4).
- SPI polling pattern and clock-field shifts (RTL-confirmed); SPI ISR
  dropped-byte guard; I2C single-STOP + off-by-one fix + bounded timeout (§6).
- PyQt demo threading + handle lifecycle; publish-before-push frame ordering;
  Q1.15 endianness across host/RTL/firmware (§7).
- The CI gates can fail (pipefail, warnings-as-errors, severity-aware DRC,
  strict `test-zephyr` PASS check, SHA-pinned actions) (§8).
- The eight `ostomachion_fft` ZTESTs map name-for-name to ACCEL_ARCH §6 failure
  modes; the off-by-one and stale-IRQ guards use zero/tight tolerances.
