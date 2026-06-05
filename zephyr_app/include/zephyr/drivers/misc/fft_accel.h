/*
 * fft_accel.h — Public API for the Ostomachion FFT accelerator driver
 * Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
 */

#ifndef ZEPHYR_DRIVERS_MISC_FFT_ACCEL_H_
#define ZEPHYR_DRIVERS_MISC_FFT_ACCEL_H_

#include <zephyr/types.h>
#include <zephyr/device.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief One complex sample in Q1.15 fixed-point format.
 *
 * 1.0 is represented as 32767 (0x7FFF).
 * -1.0 is represented as -32768 (0x8000).
 */
struct fft_sample_t {
	int16_t re;  /**< Real part,      Q1.15 */
	int16_t im;  /**< Imaginary part, Q1.15 */
};

/**
 * @brief Run an N-point complex FFT on the hardware accelerator.
 *
 * Blocks until the DMA transfer and FFT computation are complete,
 * or until CONFIG_FFT_ACCEL_TIMEOUT_MS elapses (default 100 ms).
 *
 * @param dev  Pointer to FFT accelerator device (from DT_NODELABEL).
 * @param in   Input samples, length @p n (Q1.15 complex).
 * @param out  Output buffer, length @p n.
 * @param n    Transform size.  Only 4096 is supported by this hardware;
 *             any other value returns -EINVAL.
 * @return 0 on success, negative errno on failure:
 *         -ENODEV   device is not ready (init failed or null pointer)
 *         -EINVAL   @p n != 4096
 *         -ETIMEDOUT DMA did not complete within CONFIG_FFT_ACCEL_TIMEOUT_MS
 *         -EIO      DMA reported an error
 */
int fft_accel_transform(const struct device *dev,
			const struct fft_sample_t *in,
			struct fft_sample_t *out,
			size_t n);

/**
 * @brief Check whether the last transform produced a fixed-point overflow.
 *
 * The xfft overflow flag (m_axis_status_tdata[0]) is NOT delivered through the
 * interrupt path.  A fabric sticky latch records it (set on any scaled-stage
 * overflow during the frame, cleared by the per-transform aresetn pulse), and
 * fft_accel_transform() reads it back over the AXI GPIO input channel
 * (GPIO_DATA2 bit 0) after the S2MM completion — see ACCEL_ARCH.md §2.3.  If
 * this flag is true the output bins may contain corrupted values; reduce the
 * input amplitude or re-examine the scaling schedule.  The flag reflects the
 * most recent fft_accel_transform() call.
 *
 * @param dev  Pointer to FFT accelerator device.
 * @return true if overflow was detected in the last transform, false otherwise.
 */
bool fft_accel_get_last_overflow(const struct device *dev);

#ifdef __cplusplus
}
#endif

#endif /* ZEPHYR_DRIVERS_MISC_FFT_ACCEL_H_ */
