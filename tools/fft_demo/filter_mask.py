"""Host-side spectral-filter helpers for the FFT demo.

Mirrors the firmware brick-wall mask synthesis (zephyr_app/src/fft_demo_main.c
``demo_synth_mask`` / ``filter_mask.hpp`` ``synth``) **bit-for-bit**, so the
H[k] overlay drawn in the UI matches the coefficient table the fabric actually
applies — and packs / unpacks the FrontPanel control + status words.

Control word (host → WireIn 0x01 → firmware @ 0x9000_0010):

    [2:0]   mode  (0=bypass/off, 1=LP, 2=HP, 3=BP, 4=notch)
    [14:3]  lo    (folded-frequency bin, 0..2048)
    [26:15] hi    (folded-frequency bin, 0..2048)

Status word (firmware @ 0x9000_0014 → WireOut 0x28 → host):

    [2:0] applied_mode  [3] filter_avail  [4] last_overflow  [5] last_failed

Band-edge convention (matches the C++ HAL / firmware, NOT the single-arg shell):
LP uses ``hi`` as the cutoff, HP uses ``lo`` as the cutoff, BP/notch use both.
The UI's :class:`_FilterPanel` maps its cutoff/lo/hi sliders onto (lo, hi)
accordingly; :func:`synth_mask` and the firmware both consume the raw (lo, hi).
"""

from __future__ import annotations

import numpy as np


# ── Filter modes — must match the firmware control-word encoding (FILT_*). ──
MODE_BYPASS = 0
MODE_LP     = 1
MODE_HP     = 2
MODE_BP     = 3
MODE_NOTCH  = 4

# Human-readable names indexed by mode value (combo box / labels).
MODE_NAMES = ["Off", "Low-pass", "High-pass", "Band-pass", "Notch"]

# Q1.15 passband gain used by the firmware/fabric (0x7FFF ≈ +0.999969).
PASS_GAIN = 0x7FFF


def folded_freq(k: np.ndarray | int, n: int) -> np.ndarray | int:
    """Folded (physical) frequency index: bin k mirrors to n-k, take the lower.

    Vectorised over a numpy array or scalar; identical to the firmware
    ``demo_folded_freq`` and ``filter_mask.hpp`` ``folded_freq``."""
    return np.minimum(k, n - k)


def synth_mask(mode: int, lo: int, hi: int, n: int = 4096) -> np.ndarray:
    """Brick-wall mask as an ``(n, 2)`` int16 Q1.15 array.

    Passband bins get ``{PASS_GAIN, 0}``; stopband bins ``{0, 0}`` — bit-for-bit
    identical to the firmware synth, so the on-screen H[k] overlay matches the
    fabric coefficient table.  ``lo``/``hi`` are folded-frequency bin indices
    (0..n/2):

      * LP    — passband ``f <= hi``
      * HP    — passband ``f >= lo``
      * BP    — passband ``lo <= f <= hi``
      * Notch — stopband ``lo <= f <= hi`` (pass everything else)

    A bypass / unknown mode yields an all-stop mask (no coefficients).
    """
    k = np.arange(n)
    f = folded_freq(k, n)
    if mode == MODE_LP:
        passband = f <= hi
    elif mode == MODE_HP:
        passband = f >= lo
    elif mode == MODE_BP:
        passband = (f >= lo) & (f <= hi)
    elif mode == MODE_NOTCH:
        passband = (f < lo) | (f > hi)
    else:  # MODE_BYPASS / unknown
        passband = np.zeros(n, dtype=bool)
    out = np.zeros((n, 2), dtype=np.int16)
    out[passband, 0] = PASS_GAIN
    return out


def mask_passband(mode: int, lo: int, hi: int, n: int = 4096) -> np.ndarray:
    """Boolean passband over all n bins (for the shaded overlay).

    Equivalent to ``synth_mask(...)[:, 0] != 0`` but skips the int16 alloc."""
    return synth_mask(mode, lo, hi, n)[:, 0] != 0


def pack_filter_cfg(mode: int, lo: int, hi: int) -> int:
    """Pack the 32-bit filter control word (see module docstring)."""
    return ((mode & 0x7)
            | ((int(lo) & 0xFFF) << 3)
            | ((int(hi) & 0xFFF) << 15))


def unpack_status(word: int) -> dict:
    """Decode the firmware status echo word into a dict of fields."""
    return {
        "mode":     word & 0x7,
        "avail":    bool(word & 0x8),
        "overflow": bool(word & 0x10),
        "failed":   bool(word & 0x20),
    }


__all__ = [
    "MODE_BYPASS", "MODE_LP", "MODE_HP", "MODE_BP", "MODE_NOTCH",
    "MODE_NAMES", "PASS_GAIN",
    "folded_freq", "synth_mask", "mask_passband",
    "pack_filter_cfg", "unpack_status",
]
