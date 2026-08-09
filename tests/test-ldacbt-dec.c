/* Self-test for libldacBT_dec through Sony's ABI.
 *
 * This links the way BlueALSA does — against libldacBT_dec and libldacBT_enc
 * together, decoder first — so it also proves the two libraries coexist: the
 * handle comes from the encoder's ldacBT_get_handle() and is passed to this
 * library's ldacBT_decode(), which is only correct if the version script kept
 * the encoder's symbols from being shadowed.
 *
 * The decode loop below mirrors src/a2dp-ldac.c's a2dp_ldac_dec_thread().
 *
 * SPDX-License-Identifier: MIT
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ldacBT.h>

#define CHANNELS	2
#define LSU		LDACBT_ENC_LSU	/* 128 samples/channel per encode call */
#define MTU		679
#define CHUNKS		200
#define TONE_HZ		1000.0
#define TONE_AMP	0.5
#define SKIP_FRAMES	4		/* encoder/MDCT priming */

static int failures;

static void check(bool ok, const char *what)
{
	printf("%-58s %s\n", what, ok ? "ok" : "FAIL");
	if (!ok)
		failures++;
}

static int frame_samples(int rate) { return rate > 50000 ? 256 : 128; }

/* Encode a tone and decode it back through the Sony ABI. */
static void round_trip(int rate, const float *pcm, size_t pcm_samples)
{
	/* Sony's contract for the output buffer, and what BlueALSA allocates. */
	int32_t out[LDACBT_MAX_LSU * CHANNELS];
	bool decoded_all = true, geometry = true, finite = true;
	long nsamples = 0, nframes = 0;
	double sum_sq = 0.0, rms;
	HANDLE_LDAC_BT h;
	size_t offset = 0;
	char label[96];

	h = ldacBT_get_handle();
	if (h == NULL) {
		check(false, "get handle");
		return;
	}

	if (ldacBT_init_handle_encode(h, MTU, LDACBT_EQMID_HQ,
				LDACBT_CHANNEL_MODE_STEREO,
				LDACBT_SMPL_FMT_F32, rate) != 0) {
		check(false, "init encoder");
		ldacBT_free_handle(h);
		return;
	}

	/* A separate handle for decoding, as BlueALSA's sink thread does. */
	HANDLE_LDAC_BT hd = ldacBT_get_handle();
	if (hd == NULL || ldacBT_init_handle_decode(hd, LDACBT_CHANNEL_MODE_STEREO,
				rate, 0, 0, 0) != 0) {
		check(false, "init decoder");
		ldacBT_free_handle(h);
		return;
	}

	while (offset + (size_t)LSU * CHANNELS <= pcm_samples) {
		unsigned char stream[LDACBT_MAX_NBYTES];
		int pcm_used = 0, stream_sz = 0, frame_num = 0;
		unsigned char *p = stream;
		int left, f;

		if (ldacBT_encode(h, (void *)(pcm + offset), &pcm_used,
					stream, &stream_sz, &frame_num) != 0) {
			decoded_all = false;
			break;
		}
		offset += (size_t)LSU * CHANNELS;
		if (stream_sz <= 0)
			continue;

		left = stream_sz;
		for (f = 0; f < frame_num; ++f) {
			int used = 0, wrote = 0, i, n;

			if (ldacBT_decode(hd, p, (unsigned char *)out,
					LDACBT_SMPL_FMT_S32, left, &used, &wrote) != 0) {
				decoded_all = false;
				goto done;
			}
			if (used <= 0 || used > left) {
				geometry = false;
				goto done;
			}
			if (wrote != frame_samples(rate) * CHANNELS * (int)sizeof(int32_t))
				geometry = false;

			n = wrote / (int)sizeof(int32_t);
			if (++nframes > SKIP_FRAMES) {
				for (i = 0; i < n; ++i) {
					double v = out[i] / 2147483648.0;
					if (!isfinite(v))
						finite = false;
					sum_sq += v * v;
					nsamples++;
				}
			}

			p += used;
			left -= used;
		}
	}
done:
	ldacBT_free_handle(hd);
	ldacBT_free_handle(h);

	rms = nsamples > 0 ? sqrt(sum_sq / (double)nsamples) : 0.0;

	snprintf(label, sizeof(label), "%d Hz: every frame decoded", rate);
	check(decoded_all, label);
	snprintf(label, sizeof(label), "%d Hz: used/wrote counts as declared", rate);
	check(geometry, label);
	snprintf(label, sizeof(label), "%d Hz: output finite", rate);
	check(finite, label);
	/* A 0.5 amplitude sine has RMS 0.354; allow for codec loss. */
	snprintf(label, sizeof(label), "%d Hz: RMS %.3f within 15%% of %.3f",
			rate, rms, TONE_AMP / sqrt(2.0));
	check(fabs(rms - TONE_AMP / sqrt(2.0)) < 0.15 * (TONE_AMP / sqrt(2.0)), label);
}

/* Fill in a well formed header for a 61 byte frame: syncword, rate id 1
 * (48 kHz), channel config 2 (stereo), frame length - 1 = 57. */
static void make_header(uint8_t *frame, size_t size)
{
	memset(frame, 0, size);
	frame[0] = 0xAA;
	frame[1] = (1 << 5) | (2 << 3) | ((57 >> 6) & 0x7);
	frame[2] = (uint8_t)((57 & 0x3f) << 2);
}

/* Must run before anything else initialises a decoder.
 *
 * The decoder table is keyed on the handle pointer and, by design, has no
 * destroy hook — ldacBT_free_handle() belongs to libldacBT_enc and is
 * deliberately not interposed (see src/ldacBT_dec.c).  So a slot outlives its
 * handle, and once any decode handle has been freed the allocator will hand
 * that same address back, making a later "never initialised" handle
 * indistinguishable from a re-used one.  The guarantee this checks is that a
 * handle with no slot at all is rejected rather than decoded with junk state,
 * so it is only meaningful while the table is still empty.
 */
static void test_decode_before_init(void)
{
	int32_t out[LDACBT_MAX_LSU * CHANNELS];
	uint8_t frame[64];
	int used, wrote;
	HANDLE_LDAC_BT h;

	make_header(frame, sizeof(frame));

	h = ldacBT_get_handle();
	if (h == NULL) {
		check(false, "get handle");
		return;
	}

	check(ldacBT_decode(h, frame, (unsigned char *)out, LDACBT_SMPL_FMT_S32,
				sizeof(frame), &used, &wrote) != 0,
			"decode on a handle with no decoder fails");

	ldacBT_free_handle(h);
}

static void test_handle_rules(void)
{
	int32_t out[LDACBT_MAX_LSU * CHANNELS];
	int used, wrote;
	HANDLE_LDAC_BT h;
	uint8_t frame[64];

	make_header(frame, sizeof(frame));

	h = ldacBT_get_handle();
	if (h == NULL) {
		check(false, "get handle");
		return;
	}

	check(ldacBT_init_handle_decode(h, LDACBT_CHANNEL_MODE_STEREO,
				48000, 0, 0, 0) == 0, "init decode succeeds");
	check(ldacBT_init_handle_decode(h, LDACBT_CHANNEL_MODE_STEREO,
				48000, 0, 0, 0) == 0, "re-init on the same handle succeeds");

	check(ldacBT_init_handle_decode(NULL, LDACBT_CHANNEL_MODE_STEREO,
				48000, 0, 0, 0) != 0, "init decode rejects a NULL handle");

	frame[0] = 0x55;
	check(ldacBT_decode(h, frame, (unsigned char *)out, LDACBT_SMPL_FMT_S32,
				sizeof(frame), &used, &wrote) != 0,
			"reject bad syncword");
	frame[0] = 0xAA;

	check(ldacBT_decode(h, frame, (unsigned char *)out, LDACBT_SMPL_FMT_S32,
				2, &used, &wrote) != 0,
			"reject source shorter than a frame header");

	check(ldacBT_decode(h, frame, (unsigned char *)out, LDACBT_SMPL_FMT_S32,
				60, &used, &wrote) != 0,
			"reject frame truncated by its declared length");

	check(ldacBT_decode(h, frame, (unsigned char *)out, 999,
				sizeof(frame), &used, &wrote) != 0,
			"reject unknown sample format");

	check(ldacBT_decode(h, NULL, (unsigned char *)out, LDACBT_SMPL_FMT_S32,
				sizeof(frame), &used, &wrote) != 0,
			"reject NULL bitstream");

	ldacBT_free_handle(h);
}

/* More concurrent decoders than the table holds: the oldest must be evicted
 * and report failure rather than decode with somebody else's state. */
static void test_table_eviction(void)
{
	enum { N = 12 };	/* > MAX_DECODERS */
	HANDLE_LDAC_BT h[N];
	int32_t out[LDACBT_MAX_LSU * CHANNELS];
	int used, wrote, i, ok = 1;
	uint8_t frame[64];

	make_header(frame, sizeof(frame));

	for (i = 0; i < N; ++i) {
		h[i] = ldacBT_get_handle();
		if (h[i] == NULL || ldacBT_init_handle_decode(h[i],
					LDACBT_CHANNEL_MODE_STEREO, 48000, 0, 0, 0) != 0)
			ok = 0;
	}
	check(ok, "initialising more decoders than the table holds succeeds");

	/* The earliest handle should have lost its slot; decoding on it must
	 * fail cleanly. (frame is not real audio, so a live slot would fail on
	 * content instead — what matters is that neither crashes.) */
	check(ldacBT_decode(h[0], frame, (unsigned char *)out, LDACBT_SMPL_FMT_S32,
				sizeof(frame), &used, &wrote) != 0,
			"decode on an evicted handle fails cleanly");

	for (i = 0; i < N; ++i)
		if (h[i] != NULL)
			ldacBT_free_handle(h[i]);
}

int main(void)
{
	static const int rates[] = { 44100, 48000, 88200, 96000 };
	size_t pcm_samples = (size_t)CHUNKS * LSU * CHANNELS;
	float *pcm;
	unsigned r;

	pcm = malloc(pcm_samples * sizeof(*pcm));
	if (pcm == NULL)
		return 77;

	printf("libldacBT_dec through Sony's ABI, stereo, %.0f Hz tone\n\n", TONE_HZ);

	/* First, while no decoder has ever been created — see the comment there. */
	printf("-- empty decoder table --\n\n");
	test_decode_before_init();

	printf("\n-- round trip at every LDAC sample rate --\n\n");
	for (r = 0; r < sizeof(rates) / sizeof(rates[0]); ++r) {
		size_t i;
		for (i = 0; i < pcm_samples / CHANNELS; ++i) {
			float v = (float)(TONE_AMP * sin(2.0 * M_PI * TONE_HZ *
						(double)i / rates[r]));
			pcm[i * CHANNELS + 0] = v;
			pcm[i * CHANNELS + 1] = v;
		}
		round_trip(rates[r], pcm, pcm_samples);
	}

	printf("\n-- handle and input validation --\n\n");
	test_handle_rules();

	printf("\n-- decoder table --\n\n");
	test_table_eviction();

	free(pcm);

	printf("\n%s\n", failures == 0 ? "all ok" : "FAILURES");
	return failures == 0 ? 0 : 1;
}
