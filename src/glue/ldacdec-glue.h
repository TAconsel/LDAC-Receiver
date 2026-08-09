/* Narrow wrapper around libldacdec, for use by the PipeWire LDAC codec plugin.
 *
 * libldacdec's own headers define unprefixed min()/max()/container_of() macros
 * and pull in its internal logging header, so they must not be included next to
 * the SPA headers.  Everything from libldacdec stays behind this interface.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef LDACDEC_GLUE_H
#define LDACDEC_GLUE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Output sample formats.  The values match Sony's LDACBT_SMPL_FMT_T so that a
 * caller holding an LDACBT_SMPL_FMT_* value can pass it through unchanged. */
enum ldacdec_fmt {
	LDACDEC_FMT_S16 = 0x2,	/**< signed 16 bit, host endian */
	LDACDEC_FMT_S24 = 0x3,	/**< signed 24 bit, 3 bytes packed little endian */
	LDACDEC_FMT_S32 = 0x4,	/**< signed 32 bit, host endian */
	LDACDEC_FMT_F32 = 0x5,	/**< float, normalised to [-1.0, 1.0] */
};

/** Largest PCM output one frame can produce: 256 samples * 2 channels * 4 bytes. */
#define LDACDEC_MAX_FRAME_BYTES (256 * 2 * 4)

typedef struct ldacdec_glue ldacdec_glue_t;

/** Allocate and initialise a decoder. Returns NULL on failure. */
ldacdec_glue_t *ldacdec_glue_new(void);

void ldacdec_glue_free(ldacdec_glue_t *glue);

/**
 * Decode exactly one LDAC frame.
 *
 * The frame header is validated against \a src_size before decoding, so a
 * truncated or malformed packet is rejected rather than read past its end.
 *
 * \param src        Start of an LDAC frame.
 * \param src_size   Bytes available at \a src.
 * \param dst        PCM output buffer.
 * \param dst_size   Bytes available at \a dst.
 * \param fmt        One of enum ldacdec_fmt.
 * \param consumed   Bytes consumed from \a src.
 * \param written    Bytes written to \a dst.
 * \return 0 on success, -1 on error (nothing is written on error).
 */
int ldacdec_glue_decode(ldacdec_glue_t *glue,
		const void *src, size_t src_size,
		void *dst, size_t dst_size, int fmt,
		int *consumed, int *written);

/** Channels in the most recently decoded frame, or -1 if none succeeded yet. */
int ldacdec_glue_channels(ldacdec_glue_t *glue);

/** Sample rate of the most recently decoded frame, or -1 if none succeeded yet. */
int ldacdec_glue_rate(ldacdec_glue_t *glue);

#ifdef __cplusplus
}
#endif

#endif /* LDACDEC_GLUE_H */
