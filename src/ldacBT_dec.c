/* libldacBT_dec — Sony's LDAC decode API, implemented with libldacdec.
 *
 * BlueALSA can act as an A2DP Sink for LDAC: src/a2dp-ldac.c contains a
 * complete decode thread.  It is compiled only when HAVE_LDAC_DECODE is
 * defined, which configure sets from `pkg-config ldacBT-dec`.  No such package
 * exists — Sony open sourced the LDAC encoder and never the decoder — so the
 * sink path is normally dead code.  This library is that missing package: it
 * exports the two entry points the decode thread calls and implements them on
 * top of hegdi/libldacdec, a clean-room LDAC decoder.
 *
 * Handle ownership.  In Sony's API a single handle type serves both directions
 * and is allocated by ldacBT_get_handle(), which lives in libldacBT_enc.  The
 * layout of that object is private to the encoder, so this library never
 * dereferences it and uses the pointer purely as an opaque key into the table
 * below.
 *
 * Lifetime.  ldacBT_free_handle() also belongs to the encoder.  Interposing it
 * to get a destroy hook would redirect the encoder library's own internal calls
 * through this one, so it is deliberately not done: entries are instead reused
 * when a handle is re-initialised and evicted when the table fills.  A stream
 * that ends without its slot being reused therefore keeps one decoder alive
 * until the slot is needed again.  With MAX_DECODERS slots that is bounded, and
 * in practice BlueALSA runs one decode thread per transport and the freed
 * handle address is usually handed straight back by malloc, so the slot is
 * matched and reset on the next stream.
 *
 * SPDX-License-Identifier: MIT
 */
#include <pthread.h>
#include <stddef.h>

#include <ldacBT.h>

#include "ldacdec-glue.h"

/* Enough for several concurrent A2DP sink transports; see Lifetime above. */
#define MAX_DECODERS 8

struct slot {
	HANDLE_LDAC_BT key;	/* NULL when free */
	ldacdec_glue_t *dec;
	unsigned long stamp;	/* for least-recently-initialised eviction */
};

static struct slot slots[MAX_DECODERS];
static unsigned long clock_seq;
static pthread_mutex_t slots_lock = PTHREAD_MUTEX_INITIALIZER;

/* Bytes per sample for a Sony LDACBT_SMPL_FMT_* value, 0 if unrecognised. */
static size_t fmt_sample_size(int fmt)
{
	switch (fmt) {
	case LDACBT_SMPL_FMT_S16:
		return 2;
	case LDACBT_SMPL_FMT_S24:
		return 3;
	case LDACBT_SMPL_FMT_S32:
	case LDACBT_SMPL_FMT_F32:
		return 4;
	default:
		return 0;
	}
}

/* Caller must hold slots_lock. */
static struct slot *slot_find(HANDLE_LDAC_BT key)
{
	int i;

	for (i = 0; i < MAX_DECODERS; ++i)
		if (slots[i].key == key)
			return &slots[i];
	return NULL;
}

int ldacBT_init_handle_decode(HANDLE_LDAC_BT hLdacBt, int cm, int sf,
		int nshift, int var0, int var1)
{
	ldacdec_glue_t *dec;
	struct slot *s;
	int i;

	/* The frame header carries the real channel configuration and sample
	 * rate, and libldacdec follows it, so these are accepted and ignored. */
	(void)cm;
	(void)sf;
	(void)nshift;
	(void)var0;
	(void)var1;

	if (hLdacBt == NULL)
		return -1;

	dec = ldacdec_glue_new();
	if (dec == NULL)
		return -1;

	pthread_mutex_lock(&slots_lock);

	s = slot_find(hLdacBt);
	if (s == NULL)
		s = slot_find(NULL);
	if (s == NULL) {
		/* Table full: drop the slot initialised longest ago. */
		s = &slots[0];
		for (i = 1; i < MAX_DECODERS; ++i)
			if (slots[i].stamp < s->stamp)
				s = &slots[i];
	}

	/* Covers all three cases above: re-initialising this handle, claiming a
	 * free slot, and evicting somebody else's. */
	if (s->dec != NULL)
		ldacdec_glue_free(s->dec);

	s->key = hLdacBt;
	s->dec = dec;
	s->stamp = ++clock_seq;

	pthread_mutex_unlock(&slots_lock);
	return 0;
}

int ldacBT_decode(HANDLE_LDAC_BT hLdacBt, unsigned char *p_bs,
		unsigned char *p_pcm, LDACBT_SMPL_FMT_T fmt, int bs_bytes,
		int *used_bytes, int *wrote_bytes)
{
	ldacdec_glue_t *dec;
	size_t sample_size, dst_size;
	struct slot *s;
	int rc;

	if (p_bs == NULL || p_pcm == NULL || used_bytes == NULL ||
			wrote_bytes == NULL || bs_bytes <= 0)
		return -1;

	sample_size = fmt_sample_size(fmt);
	if (sample_size == 0)
		return -1;

	/* Sony's contract is that p_pcm holds LDACBT_MAX_LSU * channels samples,
	 * and the caller is not asked to say how big it made it.  One frame
	 * yields at most 256 samples per channel, so 256 * channels * sample_size
	 * is needed and LDACBT_MAX_LSU * channels * sample_size is guaranteed.
	 * LDACBT_MAX_LSU * sample_size sits between the two for every channel
	 * count LDAC allows (1 or 2), so it is a safe bound to hand the decoder
	 * without knowing the channel count yet. */
	dst_size = (size_t)LDACBT_MAX_LSU * sample_size;

	pthread_mutex_lock(&slots_lock);
	s = slot_find(hLdacBt);
	dec = s != NULL ? s->dec : NULL;
	pthread_mutex_unlock(&slots_lock);

	if (dec == NULL)
		return -1;	/* not initialised for decoding, or slot evicted */

	/* The glue validates the frame header against bs_bytes before decoding;
	 * libldacdec's bit reader trusts the declared frame length and this data
	 * arrives over the air. */
	rc = ldacdec_glue_decode(dec, p_bs, (size_t)bs_bytes, p_pcm, dst_size,
			(int)fmt, used_bytes, wrote_bytes);

	return rc == 0 ? 0 : -1;
}
