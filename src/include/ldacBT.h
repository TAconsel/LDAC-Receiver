/* Sony LDAC API header, extended with the decoder entry points.
 *
 * The packaged libldacbt-enc-dev ships an `ldacBT.h` covering only the encoder,
 * because that is all Sony open sourced.  BlueALSA's `src/a2dp-ldac.c` includes
 * <ldacBT.h> for both directions, so its A2DP Sink path needs the decode
 * prototypes to be visible under that same name.
 *
 * This header is installed into its own directory and pulls the real one in
 * with #include_next, so the encoder declarations stay in exactly one place.
 * For that to work this directory must be searched *before* /usr/include/ldac.
 * Both ldacBT-abr.pc and ldacBT-enc.pc put -I/usr/include/ldac on the command
 * line ahead of ldacBT-dec.pc's Cflags, so relying on the .pc alone is not
 * enough — configure BlueALSA with CPPFLAGS pointing here as well:
 *
 *     ./configure CPPFLAGS="-I<prefix>/include/ldac-dec" ...
 *
 * automake emits $(CPPFLAGS) ahead of the per-target CFLAGS that carry the
 * pkg-config flags, so that reliably wins.  install.sh does this for you.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef LDACBT_DEC_SHIM_H
#define LDACBT_DEC_SHIM_H

#include_next <ldacBT.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Initialise a handle for decoding.
 *
 * The handle must have come from ldacBT_get_handle(); in Sony's API one handle
 * type serves both directions.  A handle already initialised for decoding is
 * reset by calling this again.
 *
 *   cm      channel mode of the stream (LDAC_CHANNEL_MODE_*), advisory only:
 *           the real geometry is read from each frame header
 *   sf      sampling frequency in Hz, likewise advisory
 *   nshift  unused, pass 0
 *   var0    unused, pass 0
 *   var1    unused, pass 0
 *
 * Returns 0 on success, -1 on failure.
 */
LDACBT_API int ldacBT_init_handle_decode(HANDLE_LDAC_BT hLdacBt, int cm, int sf,
		int nshift, int var0, int var1);

/* Decode exactly one ldac_transport_frame.
 *
 *   p_bs         start of the frame
 *   p_pcm        interleaved PCM output; per Sony's contract it must hold at
 *                least LDACBT_MAX_LSU * channels samples
 *   fmt          output sample format
 *   bs_bytes     bytes readable at p_bs
 *   used_bytes   out: bytes consumed from p_bs
 *   wrote_bytes  out: bytes written to p_pcm
 *
 * Returns 0 on success, -1 on failure; nothing is written on failure.
 */
LDACBT_API int ldacBT_decode(HANDLE_LDAC_BT hLdacBt, unsigned char *p_bs,
		unsigned char *p_pcm, LDACBT_SMPL_FMT_T fmt, int bs_bytes,
		int *used_bytes, int *wrote_bytes);

#ifdef __cplusplus
}
#endif

#endif /* LDACBT_DEC_SHIM_H */
