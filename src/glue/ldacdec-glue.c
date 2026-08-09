/* Narrow wrapper around libldacdec. See ldacdec-glue.h.
 *
 * SPDX-License-Identifier: MIT
 */
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "ldacdec.h"		/* libldacdec, kept out of the caller's namespace */

#include "ldacdec-glue.h"

/* LDAC frame header, most significant bit first:
 *   8 bits  syncword (0xAA)
 *   3 bits  sample rate id
 *   2 bits  channel config id
 *   9 bits  frame length - 1
 *   2 bits  frame status
 * The payload that follows is (frame length) bytes, so a whole frame occupies
 * LDAC_HEADER_BYTES + frame length. */
#define LDAC_HEADER_BYTES	3
#define LDAC_SYNCWORD		0xAA

/* Channel config ids, as used by libldacdec's block tables. */
#define LDAC_CCID_MONO		0
#define LDAC_CCID_DUAL		1
#define LDAC_CCID_STEREO	2

struct ldacdec_glue {
	ldacdec_t dec;
	bool decoded;
	/* ldacDecode() always writes int16 PCM; we take the float channel data
	 * instead, but still have to give it somewhere to put this. */
	int16_t scratch[MAX_FRAME_SAMPLES * 2];
};

static const int sample_rate_id_to_frame_samples[4] = { 128, 128, 256, 256 };

static inline int32_t clamp_i32(double v, int32_t lo, int32_t hi)
{
	double r = round(v);
	if (r <= (double)lo)
		return lo;
	if (r >= (double)hi)
		return hi;
	return (int32_t)r;
}

static size_t fmt_sample_size(int fmt)
{
	switch (fmt) {
	case LDACDEC_FMT_S16:
		return 2;
	case LDACDEC_FMT_S24:
		return 3;
	case LDACDEC_FMT_S32:
	case LDACDEC_FMT_F32:
		return 4;
	default:
		return 0;
	}
}

ldacdec_glue_t *ldacdec_glue_new(void)
{
	ldacdec_glue_t *glue;

	glue = calloc(1, sizeof(*glue));
	if (glue == NULL)
		return NULL;

	if (ldacdecInit(&glue->dec) != 0) {
		free(glue);
		return NULL;
	}
	return glue;
}

void ldacdec_glue_free(ldacdec_glue_t *glue)
{
	free(glue);
}

int ldacdec_glue_channels(ldacdec_glue_t *glue)
{
	if (!glue->decoded)
		return -1;
	return ldacdecGetChannelCount(&glue->dec);
}

int ldacdec_glue_rate(ldacdec_glue_t *glue)
{
	if (!glue->decoded)
		return -1;
	return ldacdecGetSampleRate(&glue->dec);
}

/* Interleave and convert the decoded float channel data into dst. */
static void write_pcm(const frame_t *frame, void *dst, int fmt, int channels, int samples)
{
	int smpl, ch;

	switch (fmt) {
	case LDACDEC_FMT_S16: {
		int16_t *out = dst;
		for (smpl = 0; smpl < samples; ++smpl)
			for (ch = 0; ch < channels; ++ch)
				*out++ = (int16_t)clamp_i32(frame->channels[ch].pcm[smpl],
						INT16_MIN, INT16_MAX);
		break;
	}
	case LDACDEC_FMT_S24: {
		uint8_t *out = dst;
		for (smpl = 0; smpl < samples; ++smpl) {
			for (ch = 0; ch < channels; ++ch) {
				int32_t v = clamp_i32((double)frame->channels[ch].pcm[smpl] * 256.0,
						-8388608, 8388607);
				*out++ = (uint8_t)(v & 0xff);
				*out++ = (uint8_t)((v >> 8) & 0xff);
				*out++ = (uint8_t)((v >> 16) & 0xff);
			}
		}
		break;
	}
	case LDACDEC_FMT_S32: {
		int32_t *out = dst;
		for (smpl = 0; smpl < samples; ++smpl)
			for (ch = 0; ch < channels; ++ch)
				*out++ = clamp_i32((double)frame->channels[ch].pcm[smpl] * 65536.0,
						INT32_MIN, INT32_MAX);
		break;
	}
	case LDACDEC_FMT_F32: {
		float *out = dst;
		for (smpl = 0; smpl < samples; ++smpl)
			for (ch = 0; ch < channels; ++ch)
				*out++ = frame->channels[ch].pcm[smpl] / 32768.0f;
		break;
	}
	default:
		break;
	}
}

int ldacdec_glue_decode(ldacdec_glue_t *glue,
		const void *src, size_t src_size,
		void *dst, size_t dst_size, int fmt,
		int *consumed, int *written)
{
	const uint8_t *hdr = src;
	int rate_id, ccid, frame_length, channels, samples;
	size_t frame_bytes, sample_size, need;
	int bytes_used = 0;

	sample_size = fmt_sample_size(fmt);
	if (sample_size == 0)
		return -1;

	/* Validate the header before letting the bit reader loose on the frame:
	 * it trusts the declared frame length and does no bounds checking, and
	 * this data comes straight off the air. */
	if (src_size < LDAC_HEADER_BYTES)
		return -1;
	if (hdr[0] != LDAC_SYNCWORD)
		return -1;

	rate_id = hdr[1] >> 5;
	ccid = (hdr[1] >> 3) & 0x3;
	frame_length = (((hdr[1] & 0x7) << 6) | (hdr[2] >> 2)) + 1;

	if (ccid == LDAC_CCID_MONO) {
		channels = 1;
	} else if (ccid == LDAC_CCID_STEREO) {
		channels = 2;
	} else {
		/* Dual channel splits a frame into two single-channel blocks;
		 * libldacdec decodes both into the same buffer, so it cannot be
		 * reproduced correctly. The plugin does not advertise it. */
		return -1;
	}

	frame_bytes = (size_t)LDAC_HEADER_BYTES + frame_length;
	if (frame_bytes > src_size)
		return -1;

	samples = sample_rate_id_to_frame_samples[rate_id];

	need = (size_t)samples * channels * sample_size;
	if (need > dst_size)
		return -1;

	if (ldacDecode(&glue->dec, (uint8_t *)src, glue->scratch, &bytes_used) != 0)
		return -1;

	/* Guard against the decoder having read a different frame shape than the
	 * header we validated above. */
	if (glue->dec.frame.channelCount != channels ||
	    glue->dec.frame.frameSamples != samples ||
	    glue->dec.frame.sampleRateId != rate_id)
		return -1;
	if (bytes_used <= 0 || (size_t)bytes_used > src_size)
		return -1;

	write_pcm(&glue->dec.frame, dst, fmt, channels, samples);

	glue->decoded = true;
	*consumed = bytes_used;
	*written = (int)need;

	return 0;
}
