/* Round-trip test for the libldacdec glue.
 *
 * Sony's encoder is packaged, so we can produce genuine LDAC frames here and
 * check the decoder reproduces the signal in every output format the PipeWire
 * plugin can negotiate.
 *
 * SPDX-License-Identifier: MIT
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ldac/ldacBT.h>

#include "ldacdec-glue.h"

#define CHANNELS	2
#define LSU		LDACBT_ENC_LSU		/* 128 samples per encode call */
#define MTU		679			/* typical A2DP payload size */
#define CHUNKS		200			/* ~0.53 s of audio */
#define TONE_HZ		1000.0
#define TONE_AMP	0.5

#define SKIP_FRAMES	4	/* encoder/MDCT priming */

/* LDAC packs 128 samples per frame at 44.1/48 kHz and 256 at 88.2/96 kHz. */
static int frame_samples(int rate) { return rate > 50000 ? 256 : 128; }

static int failures;

static void check(bool ok, const char *what)
{
	printf("%-58s %s\n", what, ok ? "ok" : "FAIL");
	if (!ok)
		failures++;
}

/* Read one sample from a decoded buffer, normalised back to [-1.0, 1.0]. */
static double read_sample(const uint8_t *buf, size_t index, int fmt)
{
	switch (fmt) {
	case LDACDEC_FMT_S16:
		return ((const int16_t *)buf)[index] / 32768.0;
	case LDACDEC_FMT_S24: {
		const uint8_t *p = buf + index * 3;
		int32_t v = (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
				((uint32_t)p[2] << 16));
		if (v & 0x800000)
			v -= 0x1000000;		/* sign extend 24 -> 32 bit */
		return v / 8388608.0;
	}
	case LDACDEC_FMT_S32:
		return ((const int32_t *)buf)[index] / 2147483648.0;
	case LDACDEC_FMT_F32:
		return ((const float *)buf)[index];
	default:
		return 0.0;
	}
}

static size_t fmt_sample_size(int fmt)
{
	return fmt == LDACDEC_FMT_S16 ? 2 : fmt == LDACDEC_FMT_S24 ? 3 : 4;
}

struct result {
	double rms;
	long samples;
	long frames;
	bool decode_ok;
	bool sane_geometry;
	bool finite;
};

/* Encode a tone and decode it straight back, in the given output format. */
static struct result round_trip(int fmt, int rate, const float *pcm, size_t pcm_samples)
{
	struct result r = { .decode_ok = true, .sane_geometry = true, .finite = true };
	HANDLE_LDAC_BT enc;
	ldacdec_glue_t *dec;
	double sum_sq = 0.0;
	size_t offset = 0;

	enc = ldacBT_get_handle();
	if (enc == NULL)
		return (struct result){ .decode_ok = false };

	if (ldacBT_init_handle_encode(enc, MTU, LDACBT_EQMID_HQ,
				LDACBT_CHANNEL_MODE_STEREO,
				LDACBT_SMPL_FMT_F32, rate) != 0) {
		ldacBT_free_handle(enc);
		return (struct result){ .decode_ok = false };
	}

	dec = ldacdec_glue_new();
	if (dec == NULL) {
		ldacBT_free_handle(enc);
		return (struct result){ .decode_ok = false };
	}

	while (offset + (size_t)LSU * CHANNELS <= pcm_samples) {
		unsigned char stream[LDACBT_MAX_NBYTES];
		uint8_t out[LDACDEC_MAX_FRAME_BYTES];
		int pcm_used = 0, stream_sz = 0, frame_num = 0;
		const uint8_t *p = stream;
		size_t left;
		int f;

		if (ldacBT_encode(enc, (void *)(pcm + offset), &pcm_used,
					stream, &stream_sz, &frame_num) != 0) {
			r.decode_ok = false;
			break;
		}
		offset += (size_t)LSU * CHANNELS;

		if (stream_sz <= 0)
			continue;

		left = (size_t)stream_sz;
		for (f = 0; f < frame_num; ++f) {
			int consumed = 0, written = 0;
			size_t n, i;

			if (ldacdec_glue_decode(dec, p, left, out, sizeof(out), fmt,
						&consumed, &written) != 0) {
				r.decode_ok = false;
				goto done;
			}
			if (consumed <= 0 || (size_t)consumed > left) {
				r.sane_geometry = false;
				goto done;
			}
			if ((size_t)written != (size_t)frame_samples(rate) * CHANNELS
					* fmt_sample_size(fmt))
				r.sane_geometry = false;
			if (ldacdec_glue_rate(dec) != rate ||
			    ldacdec_glue_channels(dec) != CHANNELS)
				r.sane_geometry = false;

			n = (size_t)written / fmt_sample_size(fmt);
			r.frames++;
			if (r.frames > SKIP_FRAMES) {
				for (i = 0; i < n; ++i) {
					double v = read_sample(out, i, fmt);
					if (!isfinite(v))
						r.finite = false;
					sum_sq += v * v;
					r.samples++;
				}
			}

			p += consumed;
			left -= (size_t)consumed;
		}
	}
done:
	if (r.samples > 0)
		r.rms = sqrt(sum_sq / (double)r.samples);

	ldacdec_glue_free(dec);
	ldacBT_free_handle(enc);
	return r;
}

static void test_rejects_bad_input(void)
{
	ldacdec_glue_t *dec = ldacdec_glue_new();
	uint8_t out[LDACDEC_MAX_FRAME_BYTES];
	uint8_t frame[64];
	int consumed, written;

	if (dec == NULL) {
		check(false, "allocate decoder");
		return;
	}

	/* A well formed header for a 61 byte frame: syncword, rate id 1 (48 kHz),
	 * channel config 2 (stereo), frame length - 1 = 57. */
	memset(frame, 0, sizeof(frame));
	frame[0] = 0xAA;
	frame[1] = (1 << 5) | (2 << 3) | ((57 >> 6) & 0x7);
	frame[2] = (uint8_t)((57 & 0x3f) << 2);

	check(ldacdec_glue_decode(dec, frame, 2, out, sizeof(out),
				LDACDEC_FMT_F32, &consumed, &written) != 0,
			"reject source shorter than a frame header");

	frame[0] = 0x55;
	check(ldacdec_glue_decode(dec, frame, sizeof(frame), out, sizeof(out),
				LDACDEC_FMT_F32, &consumed, &written) != 0,
			"reject bad syncword");
	frame[0] = 0xAA;

	/* Frame claims 3 + 58 = 61 bytes; offer one less. */
	check(ldacdec_glue_decode(dec, frame, 60, out, sizeof(out),
				LDACDEC_FMT_F32, &consumed, &written) != 0,
			"reject frame truncated by the declared length");

	check(ldacdec_glue_decode(dec, frame, sizeof(frame), out, 16,
				LDACDEC_FMT_F32, &consumed, &written) != 0,
			"reject destination too small for the frame");

	check(ldacdec_glue_decode(dec, frame, sizeof(frame), out, sizeof(out),
				999, &consumed, &written) != 0,
			"reject unknown sample format");

	/* Channel config 1 is dual channel, which we do not claim to support. */
	frame[1] = (1 << 5) | (1 << 3) | ((57 >> 6) & 0x7);
	check(ldacdec_glue_decode(dec, frame, sizeof(frame), out, sizeof(out),
				LDACDEC_FMT_F32, &consumed, &written) != 0,
			"reject dual channel frames");

	ldacdec_glue_free(dec);
}

int main(void)
{
	static const struct {
		int fmt;
		const char *name;
	} formats[] = {
		{ LDACDEC_FMT_F32, "F32" },
		{ LDACDEC_FMT_S32, "S32" },
		{ LDACDEC_FMT_S24, "S24" },
		{ LDACDEC_FMT_S16, "S16" },
	};
	static const int rates[] = { 44100, 48000, 88200, 96000 };
	const double expect_rms = TONE_AMP / sqrt(2.0);	/* 0.354 for a sine */
	size_t pcm_samples = (size_t)CHUNKS * LSU * CHANNELS;
	float *pcm;
	size_t i;
	unsigned f, rr;

	pcm = malloc(pcm_samples * sizeof(*pcm));
	if (pcm == NULL)
		return 77;

	printf("LDAC encode -> decode round trip, stereo, %.0f Hz tone\n", TONE_HZ);

	/* Every PCM format the plugin can negotiate, at the most common rate. */
	printf("\n-- output formats at 48000 Hz --\n\n");
	for (i = 0; i < pcm_samples / CHANNELS; ++i) {
		float v = (float)(TONE_AMP * sin(2.0 * M_PI * TONE_HZ * (double)i / 48000));
		pcm[i * CHANNELS + 0] = v;
		pcm[i * CHANNELS + 1] = v;
	}

	for (f = 0; f < sizeof(formats) / sizeof(formats[0]); ++f) {
		struct result r = round_trip(formats[f].fmt, 48000, pcm, pcm_samples);
		char label[80];

		snprintf(label, sizeof(label), "%s: every frame decoded", formats[f].name);
		check(r.decode_ok, label);

		snprintf(label, sizeof(label), "%s: frame geometry as declared", formats[f].name);
		check(r.sane_geometry, label);

		snprintf(label, sizeof(label), "%s: output is finite", formats[f].name);
		check(r.finite, label);

		snprintf(label, sizeof(label), "%s: decoded %ld frames", formats[f].name, r.frames);
		check(r.frames > 50, label);

		/* Lossy, so allow a wide margin; this is here to catch silence,
		 * wrong scaling and channel interleaving mistakes. */
		snprintf(label, sizeof(label), "%s: RMS %.4f within 15%% of %.4f",
				formats[f].name, r.rms, expect_rms);
		check(r.rms > expect_rms * 0.85 && r.rms < expect_rms * 1.15, label);
		printf("\n");
	}

	/* Every sample rate the sink advertises. 88.2/96 kHz use 256 sample frames,
	 * a different path through the decoder than 44.1/48 kHz. */
	printf("-- sample rates (F32) --\n\n");
	for (rr = 0; rr < sizeof(rates) / sizeof(rates[0]); ++rr) {
		int rate = rates[rr];
		struct result r;
		char label[80];

		for (i = 0; i < pcm_samples / CHANNELS; ++i) {
			float v = (float)(TONE_AMP * sin(2.0 * M_PI * TONE_HZ * (double)i / rate));
			pcm[i * CHANNELS + 0] = v;
			pcm[i * CHANNELS + 1] = v;
		}

		r = round_trip(LDACDEC_FMT_F32, rate, pcm, pcm_samples);

		snprintf(label, sizeof(label), "%d Hz: decoded, %d sample frames",
				rate, frame_samples(rate));
		check(r.decode_ok && r.sane_geometry && r.finite && r.frames > 20, label);

		snprintf(label, sizeof(label), "%d Hz: RMS %.4f within 15%% of %.4f",
				rate, r.rms, expect_rms);
		check(r.rms > expect_rms * 0.85 && r.rms < expect_rms * 1.15, label);
	}
	printf("\n");

	test_rejects_bad_input();

	free(pcm);
	printf("\n%s\n", failures == 0 ? "all checks passed" : "SOME CHECKS FAILED");
	return failures == 0 ? 0 : 1;
}
