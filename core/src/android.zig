//! Le pont JNI, pour Android.
//!
//! Kotlin cannot call a C ABI directly, so this is the layer in between. It is
//! kept as thin as the browser's, and for the same reason: every binding is a
//! place a bug can hide.
//!
//! The trick that keeps it thin is `NewDirectByteBuffer`. Rather than passing
//! arrays across JNI — which means pinning, copying, or both, fifty times a
//! second — Kotlin is handed a `ByteBuffer` that *is* the module's own scratch
//! memory. It writes microphone samples straight into the encoder's input and
//! reads frames straight out of its output. Nothing is copied, and the calls
//! that do the work take no arguments at all.
//!
//! This mirrors what the browser does with `goul_pcm_buffer()` and a
//! `Int16Array` over the WebAssembly memory. Same design, same buffers, same
//! contract: one call at a time, from the audio thread.

const std = @import("std");
const abi = @import("abi.zig");
const codec = @import("codec.zig");
const frame = @import("frame.zig");

// JNI, traduit depuis src/jni_c.h par le build (voir build.zig : addTarget).
const c = @import("jni_c");

// Referenced so the C ABI exports survive alongside the JNI ones — the
// linker would otherwise drop everything Kotlin does not name.
comptime {
    _ = abi;
}

/// `jni.h` types `JNIEnv` as a pointer already, so a `JNIEnv*` parameter is a
/// pointer to that. Two dereferences reach the function table.
const Env = [*c]c.JNIEnv;

/// The JNI function table. `env` is a pointer to a pointer to it, which is
/// the C binding of what C++ hides behind method syntax.
inline fn call(env: Env) @TypeOf(env.*.*) {
    return env.*.*;
}

// ── Tampons partagés ────────────────────────────────────────────────────────

/// The encoder's input and the decoder's output, as a `ByteBuffer` Kotlin can
/// write into. Little-endian 16-bit samples — `asShortBuffer()` on the Kotlin
/// side after setting the byte order.
export fn Java_expo_modules_goulaudio_GoulAudioNative_pcmBuffer(
    env: Env,
    _: c.jobject,
) c.jobject {
    return call(env).NewDirectByteBuffer.?(
        env,
        abi.goul_pcm_buffer(),
        @intCast(codec.frame_size * @sizeOf(i16)),
    );
}

/// Where an encoded frame appears, and where an arriving one is written.
export fn Java_expo_modules_goulaudio_GoulAudioNative_frameBuffer(
    env: Env,
    _: c.jobject,
) c.jobject {
    return call(env).NewDirectByteBuffer.?(
        env,
        abi.goul_frame_buffer(),
        @intCast(frame.max_frame_len),
    );
}

// ── Émission ────────────────────────────────────────────────────────────────

export fn Java_expo_modules_goulaudio_GoulAudioNative_sendOpen(
    _: Env,
    _: c.jobject,
    stream_id: c.jint,
    bitrate: c.jint,
) c.jint {
    // jint is signed and a stream id is not; the bit pattern is what matters.
    return abi.goul_send_open(@bitCast(stream_id), bitrate);
}

/// Encodes whatever is in the PCM buffer into the frame buffer. Returns the
/// number of bytes written, or a negative code.
export fn Java_expo_modules_goulaudio_GoulAudioNative_sendPush(
    _: Env,
    _: c.jobject,
) c.jint {
    return abi.goul_send_push(
        abi.goul_pcm_buffer(),
        codec.frame_size,
        abi.goul_frame_buffer(),
        frame.max_frame_len,
    );
}

export fn Java_expo_modules_goulaudio_GoulAudioNative_sendClose(_: Env, _: c.jobject) void {
    abi.goul_send_close();
}

// ── Réception ───────────────────────────────────────────────────────────────

export fn Java_expo_modules_goulaudio_GoulAudioNative_recvOpen(
    _: Env,
    _: c.jobject,
    target_ms: c.jint,
    max_ms: c.jint,
) c.jint {
    return abi.goul_recv_open(@intCast(target_ms), @intCast(max_ms));
}

/// Hands the first `length` bytes of the frame buffer to the play-out buffer.
export fn Java_expo_modules_goulaudio_GoulAudioNative_recvPush(
    _: Env,
    _: c.jobject,
    length: c.jint,
) c.jint {
    if (length < 0) return abi.ERR_ARG;
    return abi.goul_recv_push(abi.goul_frame_buffer(), @intCast(length));
}

/// Writes the next 20 ms into the PCM buffer. Returns the sample count, or 0
/// for silence.
export fn Java_expo_modules_goulaudio_GoulAudioNative_recvPull(_: Env, _: c.jobject) c.jint {
    return abi.goul_recv_pull(abi.goul_pcm_buffer(), codec.frame_size);
}

export fn Java_expo_modules_goulaudio_GoulAudioNative_recvEndStream(_: Env, _: c.jobject) void {
    abi.goul_recv_end_stream();
}

export fn Java_expo_modules_goulaudio_GoulAudioNative_recvClose(_: Env, _: c.jobject) void {
    abi.goul_recv_close();
}

/// Play-out counters into a Kotlin `IntArray` of at least six entries:
/// received, played, droppedLate, droppedFull, underruns, concealed.
export fn Java_expo_modules_goulaudio_GoulAudioNative_recvStats(
    env: Env,
    _: c.jobject,
    out: c.jintArray,
) c.jint {
    const stats_count = 6;
    if (call(env).GetArrayLength.?(env, out) < stats_count) return abi.ERR_ARG;

    var values: [stats_count]u32 = undefined;
    const written = abi.goul_recv_stats(&values, stats_count);
    if (written < 0) return written;

    // Signed on the Java side; the counters stay far below 2^31 in practice
    // and a wrap would only distort a diagnostic, never the audio.
    var signed: [stats_count]c.jint = undefined;
    for (values, 0..) |value, i| signed[i] = @intCast(value);

    call(env).SetIntArrayRegion.?(env, out, 0, stats_count, &signed);
    return stats_count;
}

// ── Renseignements ──────────────────────────────────────────────────────────

export fn Java_expo_modules_goulaudio_GoulAudioNative_frameSamples(_: Env, _: c.jobject) c.jint {
    return abi.goul_frame_samples();
}

export fn Java_expo_modules_goulaudio_GoulAudioNative_sampleRate(_: Env, _: c.jobject) c.jint {
    return abi.goul_sample_rate();
}
