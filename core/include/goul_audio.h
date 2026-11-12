/*
 * L'ABI C du cœur audio de Goul.
 *
 * The implementation is Zig, in github.com/raucheacho/goul (core/), and the same source runs
 * as WebAssembly in the dispatch console. This header exists so Swift and any
 * other C caller can reach it.
 *
 * Two rules the whole surface follows:
 *
 *   - Negative is a failure, zero or above is a length or a count.
 *   - One call at a time. The scratch buffers below are shared, so capture and
 *     playback must not touch them concurrently.
 */

#ifndef GOUL_AUDIO_H
#define GOUL_AUDIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GOUL_OK 0
#define GOUL_ERR_ARG (-1)
#define GOUL_ERR_STATE (-2)
#define GOUL_ERR_CODEC (-3)
#define GOUL_ERR_MEMORY (-4)

/* Renseignements ---------------------------------------------------------- */

/** Samples in one 20 ms frame. */
int goul_frame_samples(void);

/** 48 kHz. */
int goul_sample_rate(void);

/* Tampons d'échange ------------------------------------------------------- */

/** Microphone in before encoding, decoded audio out after goul_recv_pull. */
int16_t *goul_pcm_buffer(void);

/** Encoded frames, both directions. */
uint8_t *goul_frame_buffer(void);
int goul_frame_buffer_cap(void);

/** Six uint32_t, for goul_recv_stats. */
uint32_t *goul_stats_buffer(void);

/* Émission ---------------------------------------------------------------- */

/** @param stream_id identifies one press of the button. */
int goul_send_open(uint32_t stream_id, int32_t bitrate);

/** Encodes one frame. Returns bytes written to `out`, or a negative code. */
int goul_send_push(const int16_t *pcm, size_t pcm_len, uint8_t *out, size_t out_cap);

void goul_send_close(void);

/* Réception --------------------------------------------------------------- */

int goul_recv_open(uint32_t target_ms, uint32_t max_ms);

/** Hands a frame off the socket to the play-out buffer. */
int goul_recv_push(const uint8_t *bytes, size_t len);

/** Writes the next 20 ms. Returns samples, or 0 for silence. Never blocks. */
int goul_recv_pull(int16_t *pcm, size_t pcm_cap);

/** The transmission is over; what is buffered still plays out. */
void goul_recv_end_stream(void);

void goul_recv_close(void);

/** received, played, dropped_late, dropped_full, underruns, concealed. */
int goul_recv_stats(uint32_t *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* GOUL_AUDIO_H */
