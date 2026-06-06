# Ostomachion v1.0.0-rc1 — Master-Architect Release Review

**Reviewer role:** senior FPGA architect · **Scope:** whole platform (RTL, block
design, Zephyr firmware/drivers, host tooling, CI, docs) · **Basis:** `master`
at the host-filter-control gateware (`build_id` = `43ab2d0`), cross-checked
against source and the NEORV32 v1.11.6 submodule RTL.

This review is the standing companion to [REVIEW.md](../REVIEW.md) (the
architectural contract + open ledger), which has been reconciled to the merged
tree in the same change.

---

## 1. Verdict

**Gateware and datapath: GO.** The architecture is sound and unusually
disciplined — the CPU reaches the accelerator only through the AXI map while the
host reaches FrontPanel wires/pipes in parallel, enforced *structurally* in
fabric (SmartConnect address exclusions), not by convention. Synthesis is
**current for the gateway** and **closes with margin**; the filter datapath is
**hardware-verified** on the XEM7310.

**Tagging RC1: the one hard gate is now GREEN.** The GHDL+Zephyr co-simulation
was re-run on the RC commit and **passed** — `PROJECT EXECUTION SUCCESSFUL`,
4 suites, 62 `PASS -`, **0 `FAIL -` / 0 Assertion / 0 FATAL**, the Makefile gate
printing `PASS: sim completed and no ZTEST failures detected`. Everything else is
verification-coverage hardening to be accepted or scheduled explicitly, not
correctness risk.

| Area | State | Evidence |
|------|-------|----------|
| Architecture / boundary model | ✅ sound | SmartConnect MM2S/S2MM exclusions; coeff BRAM CPU-only (REVIEW §5/§5a) |
| Timing closure (current RTL) | ✅ **WNS +0.042 / WHS +0.015, 0 failing, DRC clean** | staged build `43ab2d0` = merged host-control RTL; `git log 43ab2d0..HEAD -- fpga/` empty |
| Filter datapath | ✅ HW-verified | XEM7310 sn 2537001HTD: 14/14 fft, 7/7 filter_mask, brick-wall 16×/14×/13×, N-beat Outcome A (REVIEW §5a) |
| §2 driver ordering contract | ✅ intact post-refactor | fences / `k_sem_reset` / W1C→IAR / S2MM-first all present in merged `fft_accel.c` |
| Prior functional defects (WDT lock, I2C zero-len) | ✅ fixed & merged (#6) | collapsed into REVIEW §6 |
| GHDL+Zephyr CI gate on RC commit | ✅ **green** | `make test-zephyr` on the RC commit: PROJECT EXECUTION SUCCESSFUL, 4 suites, 62 PASS, 0 FAIL/FATAL |
| Automated coverage of overflow / WDT-lock / host-control | ⚠️ gaps | hand-verified only; REVIEW §9.1–§9.5 |

---

## 2. What is proven vs. assumed vs. missing

**Proven (do not re-litigate):**
- xfft scaling `0x1555` = exact ÷4096 unity gain; inverse `0x1554` = ÷N
  overflow-safe round trip (the gain budget is arithmetically derived).
- Every `xpm_fifo_async` gates enables + host-ready on reset-busy; all CDCs are
  `xpm_cdc_array_single` (quasi-static), never a handshake — including the two
  **new** filter-control crossings (now documented, REVIEW §3.6).
- Timing closes with a *structural* `set_clock_groups -asynchronous` cut, not
  fragile name-matched globs; the +42 ps worst path is a pre-existing intra-domain
  property of the ~100.8 MHz FIFO logic, unchanged by the filter work.
- The filter multiply is pipelined (the single-stage version failed at
  −4.376 ns); `cmpy_normalizer` reduction is bit-identical to the firmware
  `sat_round_q15`, which is why host mask composition predicts the fabric.

**Assumed / hand-verified (no CI gate — the honest gaps):**
- The HIL filter results (§5a) were taken on the filter bitstream on one DUT;
  they are not re-run automatically per commit.
- The overflow readback chain is verified only by the interactive `fft overflow`
  shell sweep — no ZTEST (REVIEW §9.3).
- The WDT two-step lock is correct in code but has no `-EPERM`-under-lock test
  (REVIEW §9.1).
- The host filter control path (firmware double-read debounce + PyQt client) is
  exercised only indirectly + by hand (REVIEW §9.5).

**Missing for a clean tag:**
- A confirmed-green GHDL+Zephyr co-sim on the exact RC commit (see §3).

---

## 3. Go / no-go gates

### ✅ CLEARED — GHDL+Zephyr co-sim green on the RC commit
This was the one CI job not yet *observed* green on a post-filter `master`
commit: the long (~90-min) `make test-zephyr` (earlier runs were cancelled by
the concurrency group, not failed). It was **re-run on the RC commit and
passed**: `PROJECT EXECUTION SUCCESSFUL`, 4 testsuites, 62 `PASS -`, **0
`FAIL -` / 0 Assertion / 0 FATAL**, Makefile gate `=== PASS: sim completed and
no ZTEST failures detected ===`. With this green, **no BLOCKER remains** — the
RC is clear to tag once the items below are dispositioned.

### ADVISED — accept or schedule the coverage gaps (REVIEW §9.1–§9.4)
None blocks the *datapath*, but each is a place CI cannot catch a regression:
- **§9.1** no test that WDT LOCK blocks `disable()` (`-EPERM`).
- **§9.2** clang-tidy `xargs` lacks `-r`; Twister can pass on an empty selection.
- **§9.3** `fft_accel.c` / `wdt_neorv32.c` never linted (config-gated out); no
  automated overflow ZTEST.
- **§9.4** `test_y_n_minus_1` is a weak (`>0`, stale-buffer-vulnerable) guard.

Recommended RC1 disposition: land the cheap, high-value ones (§9.2 `xargs -r`,
§9.4 sentinel) before tagging; schedule §9.1/§9.3 (need HIL / a second
lint config) for rc2. **This is the release owner's risk call — surfaced, not
silently deferred.**

### NICE — post-RC hardening (REVIEW §9.5)
Add the `tools/fft_demo` mask-replica + offscreen-UI tests to CI; `.gitignore`
the Vivado `*.backup.{jou,log}` and clean the untracked remote cruft (`NEXTPLAN`,
`twister-out/`, `build_zephyr_pr2/`) so a release tag/`make fpga-release`
captures nothing stray.

---

## 4. Honest test-coverage matrix

| Subsystem | Sim (CI) | Twister (CI) | HIL (manual) | Shell only | Untested |
|-----------|:--:|:--:|:--:|:--:|:--:|
| Filter-mask synthesis math | ✅ (host + on-sim) | ✅ build | ✅ | | |
| Peripheral ZTEST (SPI/I2C/GPIO) | ✅ run | ✅ build | ⚠️ FAIL — MC1 HW not fitted (expected) | | |
| Forward FFT datapath | — (xfft not in GHDL) | ✅ compile | ✅ 8/8 | | |
| Filter datapath (LP/HP/notch, bypass, beat-count) | — | ✅ compile | ✅ 6/6 | | |
| Overflow readback (M1 chain) | | | (sweep) | ✅ `fft overflow` | no ZTEST (§9.3) |
| WDT lock tamper-resistance | | | | | no `-EPERM` test (§9.1) |
| Host filter control (debounce + PyQt) | | | ✅ indirectly via §5a | host unit tests by hand | no CI gate (§9.5) |

**Reading:** the datapath is well-covered by HIL and the math by CI; the gaps
are all "proven by hand, not gated" — exactly the §9 ADVISED items.

> The `i2c`/`spi` HIL failures on the DUT are **expected** (the MC1 loopback
> jumper / I2C-slave hardware is not fitted) and must not be mistaken for a
> regression at release — they fail identically on any commit.

---

## 5. Ledger reconciliation done in this change

REVIEW.md was brought current with the merged tree (it had drifted because the
host-control / demo PRs merged after the last review pass):

- **§9.0 collapsed** — the merged PR #6 fixes (WDT lock, I2C zero-length, doc
  drift) folded into §6/§3; the open ledger re-scoped to what is actually open
  for RC1, each tagged BLOCKER/ADVISED/NICE.
- **§3.4 drift fixed** — the XBUS FFT-pipe decode is now the **32-byte /
  6-register** window (`adr[27:5]`, regs 0x10 filter_cfg + 0x14 applied_status),
  not the old 4-register `adr[27:4]`.
- **Coverage added** — new §3.6 (the two filter CDCs), §3.3 (the 2nd
  `fft_beat_counter` on `xfft_1` → WireOut 0x27, `FP_EP_COUNT` 13), and a new
  §5b (the host-driven filter-control contract: double-read debounce, status
  echo, `-ENOTSUP` graceful degrade).
- **Verification-basis header + §1 refreshed** to name the exact gateware commit
  certified and the one open CI gate.

---

## 6. Cutting the tag (once the BLOCKER is green)

```bash
git tag -a v1.0.0-rc1 -m "Ostomachion v1.0.0-rc1 — first release candidate"
make fpga-release VERSION=v1.0.0-rc1   # stages bit/mcs + timing/util/drc + build_id
git add release/v1.0.0-rc1/ && git commit -m "release: v1.0.0-rc1 artifacts"
git push --follow-tags
```

The release tooling (`scripts/gen_release_artifacts.sh`, `make fpga-release`) is
in place and unused; the current bitstream + reports are the right artifacts to
stage (the gateware is unchanged since `43ab2d0`).
