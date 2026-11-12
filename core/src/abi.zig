//! L'ABI C : ce que Kotlin, Swift et JavaScript appellent réellement.
//!
//! Deliberately small and deliberately boring. Every platform binding is a
//! place a bug can hide, so the surface they share is eight functions and no
//! structs — integers, pointers and lengths only, which every FFI in the world
//! gets right.
//!
//! The asymmetry between the two sides is the design, not an accident:
//!
//!   * **Encoding is synchronous.** PCM in, one packet out. The caller already
//!     knows when it has 20 ms of microphone.
//!
//!   * **Decoding is push/pull.** Frames arrive when the network feels like
//!     it; playback asks every 20 ms regardless. It is the buffer that decides
//!     *when* audio comes out, which is the whole point of it existing.

const std = @import("std");
const core = @import("core.zig");

const frame = core.frame;
const jitter = core.jitter;
const codec = core.codec;

/// A fixed heap, allocated once. There is no `malloc` worth relying on across
/// Android, iOS and a freestanding WebAssembly module, and an audio path
/// should not be allocating on the fly anyway: a codec that stalls to find
/// memory is a codec that drops a word.
///
/// **Un tas par sens, et chacun rendu d'un bloc à la fermeture.**
///
/// Il n'y en avait qu'un, partagé, et c'était une fuite. Un
/// `FixedBufferAllocator` est une pile : `free` ne récupère que la dernière
/// allocation. Or `goul_recv_close` libérait le décodeur *avant* le tampon de
/// gigue, c'est-à-dire dans l'ordre où ils avaient été pris — le décodeur, qui
/// n'était plus au sommet, n'était donc jamais rendu. Une vingtaine de cycles
/// ouverture/fermeture suffisaient à épuiser les 512 Ko : `goul_recv_open`
/// renvoyait alors `ERR_MEMORY`, et le téléphone affichait « Canal
/// indisponible » sans plus jamais s'en remettre. Un simple changement d'ordre
/// aurait suffi ce jour-là, et aurait re-cassé au premier bloc ajouté.
///
/// Les séparer supprime aussi le couplage entre les deux sens : fermer la
/// réception pendant qu'une émission était ouverte laissait fuir les deux.
///
/// Les tailles couvrent largement ce que chaque sens alloue réellement — un
/// état Opus (~18 Ko) et, en réception, 64 emplacements de 1 Ko (~66 Ko).
var recv_heap: [320 * 1024]u8 = undefined;
var recv_fba = std.heap.FixedBufferAllocator.init(&recv_heap);
const recv_allocator = recv_fba.threadSafeAllocator();

var send_heap: [192 * 1024]u8 = undefined;
var send_fba = std.heap.FixedBufferAllocator.init(&send_heap);
const send_allocator = send_fba.threadSafeAllocator();

/// Return codes. Negative is a failure, zero or above is a length or a count —
/// the C convention every caller here already expects.
pub const OK: c_int = 0;
pub const ERR_ARG: c_int = -1;
pub const ERR_STATE: c_int = -2;
pub const ERR_CODEC: c_int = -3;
pub const ERR_MEMORY: c_int = -4;

fn toCode(err: anyerror) c_int {
    return switch (err) {
        error.BadArgument, error.BufferTooSmall => ERR_ARG,
        error.OutOfMemory => ERR_MEMORY,
        error.InvalidState => ERR_STATE,
        else => ERR_CODEC,
    };
}

// ── Émission ────────────────────────────────────────────────────────────────

const Sender = struct {
    encoder: codec.Encoder,
    stream_id: u32,
    seq: u16,
};

var sender: ?Sender = null;

/// Opens a transmission. `stream_id` identifies this press of the button and
/// must be the same one the control event announced, or listeners will treat
/// the audio as belonging to nobody.
pub export fn goul_send_open(stream_id: u32, bitrate: i32) c_int {
    goul_send_close();
    sender = .{
        .encoder = codec.Encoder.init(send_allocator, bitrate) catch |err| return toCode(err),
        .stream_id = stream_id,
        .seq = 0,
    };
    return OK;
}

/// Encodes 20 ms of microphone into a ready-to-send frame — header included,
/// so the caller never has to know the wire format.
///
/// `pcm_len` must be exactly `goul_frame_samples()`. Returns the number of
/// bytes written to `out`, or a negative code.
pub export fn goul_send_push(
    pcm: [*]const i16,
    pcm_len: usize,
    out: [*]u8,
    out_cap: usize,
) c_int {
    var s = &(sender orelse return ERR_STATE);
    if (pcm_len != codec.frame_size) return ERR_ARG;
    if (out_cap < frame.header_len) return ERR_ARG;

    var packet: [frame.max_payload]u8 = undefined;
    const encoded = s.encoder.encode(pcm[0..pcm_len], &packet) catch |err| return toCode(err);

    const written = frame.encode(out[0..out_cap], .{
        .stream_id = s.stream_id,
        .seq = s.seq,
        .payload = encoded,
    }) catch return ERR_ARG;

    s.seq +%= 1;
    return @intCast(written.len);
}

pub export fn goul_send_close() void {
    if (sender) |*s| {
        s.encoder.deinit();
        sender = null;
    }
    // Le tas d'émission n'appartient qu'à ce sens : le rendre entier ici, plutôt
    // que de compter sur l'ordre des libérations ci-dessus.
    send_fba.reset();
}

// ── Réception ───────────────────────────────────────────────────────────────

const Receiver = struct {
    decoder: codec.Decoder,
    buffer: jitter.Buffer,
};

var receiver: ?Receiver = null;

pub export fn goul_recv_open(target_ms: u32, max_ms: u32) c_int {
    goul_recv_close();
    var decoder = codec.Decoder.init(recv_allocator) catch |err| return toCode(err);
    errdefer decoder.deinit();

    receiver = .{
        .decoder = decoder,
        .buffer = jitter.Buffer.init(recv_allocator, .{
            .target_ms = target_ms,
            .max_ms = max_ms,
        }) catch |err| return toCode(err),
    };
    return OK;
}

/// Hands a frame straight off the socket to the buffer. Cheap on purpose:
/// this runs on whatever thread the WebSocket delivers on, and it must not
/// block the audio thread that is pulling.
pub export fn goul_recv_push(bytes: [*]const u8, len: usize) c_int {
    var r = &(receiver orelse return ERR_STATE);
    const parsed = frame.decode(bytes[0..len]) catch return ERR_ARG;
    r.buffer.push(parsed);
    return OK;
}

/// Asks for the next 20 ms to play. Called on the audio clock.
///
/// Returns the number of samples written to `pcm`: a whole frame when there is
/// audio — real or concealed — and 0 for silence, which means the buffer is
/// still filling or the transmission is over. Never blocks.
pub export fn goul_recv_pull(pcm: [*]i16, pcm_cap: usize) c_int {
    var r = &(receiver orelse return ERR_STATE);
    if (pcm_cap < codec.frame_size) return ERR_ARG;

    return switch (r.buffer.pull()) {
        .silence => 0,
        .frame => |packet| blk: {
            const n = r.decoder.decode(packet, pcm[0..pcm_cap]) catch |err| break :blk toCode(err);
            break :blk @intCast(n);
        },
        // One frame per call: the caller asked for 20 ms and gets 20 ms. The
        // rest of the gap is concealed on the following calls, which is what
        // keeps playback on the clock instead of catching up in a burst.
        .conceal => blk: {
            const n = r.decoder.conceal(pcm[0..pcm_cap]) catch |err| break :blk toCode(err);
            break :blk @intCast(n);
        },
    };
}

/// Ends the current transmission, letting what is buffered play out.
pub export fn goul_recv_end_stream() void {
    if (receiver) |*r| r.buffer.endStream();
}

pub export fn goul_recv_close() void {
    if (receiver) |*r| {
        r.decoder.deinit();
        r.buffer.deinit(recv_allocator);
        receiver = null;
    }
    // Le tas de réception n'appartient qu'à ce sens : le rendre entier ici,
    // plutôt que de compter sur l'ordre des libérations ci-dessus.
    recv_fba.reset();
}

// ── Tampons d'échange ───────────────────────────────────────────────────────
//
// WebAssembly has no shared pointers with its host: JavaScript can only reach
// the module's linear memory, so it needs somewhere inside it to put a frame
// of PCM. These two buffers are that place.
//
// Static rather than allocated, which is the same decision as the fixed heap
// above and for the same reason — nothing on the audio path should be asking
// for memory. It also means the module exposes exactly two writable regions,
// each one frame long, which is a surface an auditor can check in a minute.
//
// One consequence, stated rather than assumed: a single call at a time. The
// browser calls from one AudioWorklet thread and the phones from their own
// audio threads, so this holds — but it is a contract, not an accident.

var pcm_scratch: [codec.frame_size]i16 = undefined;
var frame_scratch: [frame.max_frame_len]u8 = undefined;

/// Where to write 20 ms of microphone before encoding, and where decoded
/// audio appears after `goul_recv_pull`.
pub export fn goul_pcm_buffer() [*]i16 {
    return &pcm_scratch;
}

/// Where an encoded frame appears after `goul_send_push`, and where to write
/// one arriving off the socket before `goul_recv_push`.
pub export fn goul_frame_buffer() [*]u8 {
    return &frame_scratch;
}

pub export fn goul_frame_buffer_cap() c_int {
    return @intCast(frame_scratch.len);
}

/// Its own buffer rather than a corner of the frame one: a `Uint32Array` needs
/// four-byte alignment, which a `[N]u8` does not promise, and a statistics
/// call that quietly corrupted the frame being sent would be a nasty way to
/// find that out.
var stats_scratch: [6]u32 = undefined;

pub export fn goul_stats_buffer() [*]u32 {
    return &stats_scratch;
}

// ── Renseignements ──────────────────────────────────────────────────────────

/// Samples in one frame, so a caller can size its buffers without hard-coding
/// a number this library is free to change.
pub export fn goul_frame_samples() c_int {
    return @intCast(codec.frame_size);
}

pub export fn goul_sample_rate() c_int {
    return codec.sample_rate;
}

/// Play-out statistics, written into `out` in this order:
/// received, played, dropped_late, dropped_full, underruns, concealed.
///
/// Exposed because the only honest way to choose `target_ms` is to look at
/// what a real shift on a real network did — not to guess from a desk.
pub export fn goul_recv_stats(out: [*]u32, cap: usize) c_int {
    const r = &(receiver orelse return ERR_STATE);
    if (cap < 6) return ERR_ARG;

    const s = r.buffer.stats;
    out[0] = s.received;
    out[1] = s.played;
    out[2] = s.dropped_late;
    out[3] = s.dropped_full;
    out[4] = s.underruns;
    out[5] = s.concealed;
    return 6;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// Ouvrir et fermer en boucle doit être gratuit.
//
// C'est le test qui manquait. L'allocateur est un tampon fixe, donc toute
// mémoire non rendue l'est définitivement : une fuite ne se voit pas au
// premier cycle, elle se voit au vingtième, sur le terrain, sous la forme d'un
// « Canal indisponible » que rien ne rattrape. Deux cents cycles tiennent dans
// une seconde et couvrent une journée de reconnexions.
test "la réception s'ouvre et se ferme indéfiniment" {
    for (0..200) |_| {
        try testing.expectEqual(OK, goul_recv_open(120, 400));
        goul_recv_close();
    }
}

test "l'émission s'ouvre et se ferme indéfiniment" {
    for (0..200) |_| {
        try testing.expectEqual(OK, goul_send_open(1, 24_000));
        goul_send_close();
    }
}

// Les deux sens ne doivent pas se marcher dessus.
//
// Avec un tas partagé, fermer la réception pendant qu'une émission était
// ouverte ne rendait rien : la réception n'était plus au sommet de la pile.
// C'est exactement ce que fait un livreur qui raccroche en parlant.
test "fermer un sens pendant que l'autre est ouvert ne fuit pas" {
    for (0..200) |_| {
        try testing.expectEqual(OK, goul_recv_open(120, 400));
        try testing.expectEqual(OK, goul_send_open(1, 24_000));
        goul_recv_close();
        goul_send_close();
    }
}

// Réouvrir sans fermer est le cas du remontage d'effet côté React : l'appel
// est idempotent, et ne doit pas non plus consommer le tas.
test "réouvrir sans fermer ne fuit pas" {
    for (0..200) |_| {
        try testing.expectEqual(OK, goul_recv_open(120, 400));
    }
    goul_recv_close();
}
