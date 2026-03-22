/*
 * fft_accel.h — Public API for the Ostomachion FFT accelerator driver
 * Copyright (c) 2026  SPDX-License-Identifier: Apache-2.0
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
 * or until a 100 ms timeout elapses.
 *
 * @param dev  Pointer to FFT accelerator device (from DT_NODELABEL).
 * @param in   Input samples, length @p n (Q1.15 complex).
 * @param out  Output buffer, length @p n.
 * @param n    Transform size.  Only 64 is supported by this hardware;
 *             any other value returns -EINVAL.
 * @return 0 on success, negative errno on failure.
 */
int fft_accel_transform(const struct device *dev,
			const struct fft_sample_t *in,
			struct fft_sample_t *out,
			size_t n);

#ifdef __cplusplus
}
#endif

#endif /* ZEPHYR_DRIVERS_MISC_FFT_ACCEL_H_ */
