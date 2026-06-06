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

/**
 * @brief Load the 4096-entry per-bin complex filter coefficient table.
 *
 * Writes @p n complex Q1.15 coefficients H[k] = {re, im} into the fabric
 * coefficient BRAM.  During a filtered transform the hardware complex
 * multiplier scales FFT bin X[k] by H[k] before the inverse transform, so this
 * table defines the frequency response (low/high/band-pass, notch, or any
 * combination — see ostomachion/filter_mask.hpp for synthesis helpers).
 *
 * Serialised by the same internal mutex as fft_accel_transform(): a load that
 * races an in-flight transform blocks until it completes.  Issues a
 * data-memory fence after the fill so the coefficients are globally visible
 * before the next transform's DMA trigger.
 *
 * @note Requires the filter-pipeline bitstream (coeff BRAM mapped at the DTS
 *       "coeff_bram" region).  When the DTS node has no "coeff_bram" entry the
 *       driver leaves coeff_bram_base at 0 and this call returns -ENOTSUP.
 *
 * @param dev     FFT accelerator device.
 * @param coeffs  Coefficient table, length @p n ({re, im} Q1.15 per bin).
 * @param n       Table length (must be 4096; other values return -EINVAL).
 * @return 0 on success, -ENODEV if not ready, -EINVAL if @p n != 4096,
 *         -ENOTSUP if the bitstream has no coefficient BRAM.
 */
int fft_accel_load_coeffs(const struct device *dev,
			  const struct fft_sample_t *coeffs,
			  size_t n);

/**
 * @brief Run one N-point FFT → per-bin filter → IFFT (time-domain round trip).
 *
 * Identical sequence to fft_accel_transform(), but selects the filtered
 * datapath: the result in @p out is the inverse transform of the
 * coefficient-scaled spectrum (back in the time domain), not the raw FFT bins.
 * Load the coefficient table first with fft_accel_load_coeffs().
 *
 * @param dev  FFT accelerator device.
 * @param in   Input samples (re/im Q1.15), length @p n.
 * @param out  Output buffer, same size.
 * @param n    Transform size (must be 4096).
 * @return 0 on success, negative errno on error or timeout.
 */
int fft_accel_transform_filtered(const struct device *dev,
				 const struct fft_sample_t *in,
				 struct fft_sample_t *out,
				 size_t n);

/**
 * @brief Select the S2MM output source: forward-FFT bins or filtered IFFT.
 *
 * @p bypass = true routes the forward-FFT output straight to RX BRAM (the
 * frequency-domain behaviour of the pre-filter design); false routes it
 * through the filter + inverse transform.  fft_accel_transform() and
 * fft_accel_transform_filtered() set this explicitly per call, so this API is
 * only needed for diagnostics / interactive use.
 *
 * On a forward-FFT-only bitstream the underlying GPIO bit is unimplemented
 * (read-as-zero / write-ignored), so calls are harmless no-ops there.
 *
 * @param dev     FFT accelerator device.
 * @param bypass  true = forward-FFT only, false = filtered round trip.
 */
void fft_accel_set_filter_bypass(const struct device *dev, bool bypass);

/** @brief Return the current filter-bypass selection (see set_filter_bypass). */
bool fft_accel_get_filter_bypass(const struct device *dev);

#ifdef __cplusplus
}
#endif

#endif /* ZEPHYR_DRIVERS_MISC_FFT_ACCEL_H_ */
