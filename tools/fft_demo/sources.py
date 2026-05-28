"""Signal source generators for the FFT demo.

Each generator returns a complex sample frame as a (N, 2) int16 numpy array
in Q1.15 (the format the firmware copies straight into TX BRAM).  Output
shape is (N, 2) where column 0 is re, column 1 is im.

A helper `pack_q15_frame()` converts that array into the packed-uint32
little-endian byte buffer that fp_fft_pipe_bridge.vhd expects on BTPipeIn
0x81 ({im[31:16], re[15:0]} per 32-bit pipe word).
"""

from __future__ import annotations

import numpy as np


# Q1.15: 1.0 → 0x7FFF, -1.0 → 0x8000.  Use 0x7FFF (= 32767) as the unit
# so multiplication by amplitude in [-1, 1] doesn't round-saturate.
Q15_UNIT = 32767


def _to_q15(re: np.ndarray, im: np.ndarray) -> np.ndarray:
    """Stack real & imaginary float arrays into a (N, 2) int16 Q1.15 frame.

    Inputs are clipped to [-1, 1] before scaling so a noisy signal can't
    silently roll over into a different sign at the saturation boundary.
    """
    if re.shape != im.shape or re.ndim != 1:
        raise ValueError("re and im must be 1-D arrays of equal length")
    re_c = np.clip(re, -1.0, 1.0)
    im_c = np.clip(im, -1.0, 1.0)
    frame = np.empty((re_c.size, 2), dtype=np.int16)
    frame[:, 0] = np.round(re_c * Q15_UNIT).astype(np.int16)
    frame[:, 1] = np.round(im_c * Q15_UNIT).astype(np.int16)
    return frame


# ── Generators ────────────────────────────────────────────────────────────


def make_dc(amplitude: float, n: int = 4096) -> np.ndarray:
    """Constant real DC signal: re = amplitude, im = 0."""
    re = np.full(n, amplitude, dtype=np.float64)
    im = np.zeros(n, dtype=np.float64)
    return _to_q15(re, im)


def make_sine(amplitude: float,
              bin_index: int,
              n: int = 4096,
              phase: float = 0.0) -> np.ndarray:
    """Real cosine at the given FFT bin (so it lands exactly on a bin)."""
    k = np.arange(n)
    re = amplitude * np.cos(2.0 * np.pi * bin_index * k / n + phase)
    im = np.zeros(n, dtype=np.float64)
    return _to_q15(re, im)


def make_two_sines(a1: float, bin1: int,
                   a2: float, bin2: int,
                   n: int = 4096) -> np.ndarray:
    k = np.arange(n)
    re = (a1 * np.cos(2.0 * np.pi * bin1 * k / n)
          + a2 * np.cos(2.0 * np.pi * bin2 * k / n))
    im = np.zeros(n, dtype=np.float64)
    return _to_q15(re, im)


def make_noise(sigma: float, n: int = 4096,
               rng: np.random.Generator | None = None) -> np.ndarray:
    """Real-valued white Gaussian noise with stddev `sigma`."""
    rng = rng or np.random.default_rng()
    re = rng.standard_normal(n) * sigma
    im = np.zeros(n, dtype=np.float64)
    return _to_q15(re, im)


def make_sine_plus_noise(amplitude: float,
                         bin_index: int,
                         sigma: float,
                         n: int = 4096,
                         rng: np.random.Generator | None = None) -> np.ndarray:
    rng = rng or np.random.default_rng()
    k = np.arange(n)
    re = (amplitude * np.cos(2.0 * np.pi * bin_index * k / n)
          + rng.standard_normal(n) * sigma)
    im = np.zeros(n, dtype=np.float64)
    return _to_q15(re, im)


# ── Packing for the transport ─────────────────────────────────────────────


def pack_q15_frame(frame: np.ndarray) -> bytes:
    """Convert a (N, 2) int16 Q1.15 frame into the bridge's wire format.

    Each 32-bit word is little-endian {im[15:0] @ bits31..16, re[15:0] @ bits15..0}.
    Returns a bytes object exactly N * 4 long.
    """
    if frame.ndim != 2 or frame.shape[1] != 2 or frame.dtype != np.int16:
        raise ValueError("frame must be (N, 2) int16")
    re_u16 = frame[:, 0].astype(np.uint32) & 0xFFFF
    im_u16 = frame[:, 1].astype(np.uint32) & 0xFFFF
    words = (im_u16 << 16) | re_u16
    return words.astype(np.uint32).tobytes()


def unpack_q15_frame(buf: bytes | bytearray | memoryview, n: int = 4096) -> np.ndarray:
    """Convert a 4*N raw bytes buffer back into a (N, 2) int16 Q1.15 frame."""
    if len(buf) != 4 * n:
        raise ValueError(f"buffer must be {4 * n} bytes, got {len(buf)}")
    words = np.frombuffer(buf, dtype=np.uint32)
    re = (words & 0xFFFF).astype(np.int16)
    im = ((words >> 16) & 0xFFFF).astype(np.int16)
    out = np.empty((n, 2), dtype=np.int16)
    out[:, 0] = re
    out[:, 1] = im
    return out


def q15_to_complex(frame: np.ndarray) -> np.ndarray:
    """Convert a (N, 2) int16 Q1.15 frame to a complex128 array in [-1, 1]."""
    re = frame[:, 0].astype(np.float64) / float(Q15_UNIT)
    im = frame[:, 1].astype(np.float64) / float(Q15_UNIT)
    return re + 1j * im


__all__ = [
    "Q15_UNIT",
    "make_dc", "make_sine", "make_two_sines", "make_noise", "make_sine_plus_noise",
    "pack_q15_frame", "unpack_q15_frame", "q15_to_complex",
]
