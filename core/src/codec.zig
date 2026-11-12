//! Opus, enveloppé.
//!
//! Thin on purpose: libopus is the part of this project that is *already*
//! correct, and every line wrapped around it is a line that can be wrong. What
//! this file adds is the two decisions that are ours, not Opus's — the frame
//! size and the encoder profile — and a Zig error set instead of return codes.

const std = @import("std");
// libopus, traduit depuis src/opus_c.h par le build (voir build.zig : linkOpus).
const c = @import("opus_c");

/// 48 kHz mono. Opus is happiest at 48k and resampling on a phone to save
/// bandwidth we do not need would cost quality we do need — the rider is on a
/// motorbike, in traffic.
pub const sample_rate: i32 = 48_000;
pub const channels: i32 = 1;

/// 20 ms per frame: 960 samples at 48 kHz. Long enough that the six-byte
/// header is negligible, short enough that dropping one is a blink.
pub const frame_size: usize = 960;

pub const Error = error{
    BadArgument,
    BufferTooSmall,
    InternalError,
    InvalidPacket,
    Unimplemented,
    InvalidState,
    OutOfMemory,
    Unknown,
};

/// `OpusEncoder` and `OpusDecoder` are opaque, so their alignment cannot be
/// asked for. libopus allocates its own states with plain `malloc`, so
/// matching malloc's guarantee on a 64-bit target is both correct and what
/// upstream itself relies on.
const state_align: std.mem.Alignment = .@"16";

fn check(code: c_int) Error!void {
    if (code >= 0) return;
    return switch (code) {
        c.OPUS_BAD_ARG => error.BadArgument,
        c.OPUS_BUFFER_TOO_SMALL => error.BufferTooSmall,
        c.OPUS_INTERNAL_ERROR => error.InternalError,
        c.OPUS_INVALID_PACKET => error.InvalidPacket,
        c.OPUS_UNIMPLEMENTED => error.Unimplemented,
        c.OPUS_INVALID_STATE => error.InvalidState,
        c.OPUS_ALLOC_FAIL => error.OutOfMemory,
        else => error.Unknown,
    };
}

pub const Encoder = struct {
    handle: *c.OpusEncoder,
    allocator: std.mem.Allocator,
    /// Alignment carried in the type: freeing a `[]u8` that was allocated
    /// aligned is a mismatch the allocator rightly refuses.
    memory: []align(state_align.toByteUnits()) u8,

    /// `bitrate` in bits per second. 24000 is comfortable for speech; below
    /// about 16000 a voice on a noisy street starts to smear.
    pub fn init(allocator: std.mem.Allocator, bitrate: i32) !Encoder {
        const size = c.opus_encoder_get_size(channels);
        const memory = try allocator.alignedAlloc(u8, state_align, @intCast(size));
        errdefer allocator.free(memory);

        const handle: *c.OpusEncoder = @ptrCast(memory.ptr);
        try check(c.opus_encoder_init(handle, sample_rate, channels, c.OPUS_APPLICATION_VOIP));

        // VOIP already tunes for speech. What follows are the decisions that
        // belong to a delivery radio rather than to a general audio app.
        //
        // Constrained VBR. Measured at 24 kbit/s, average bytes per 20 ms
        // frame over 40 frames:
        //
        //                      parole   silence
        //     CBR                  60        18
        //     VBR contraint        57         9
        //     VBR libre            57         9
        //
        // Two things worth stating because they are not what one expects.
        //
        // The saving is not on speech — 60 to 57 is noise. It is on *silence*,
        // which halves, and on a push-to-talk channel silence is most of the
        // airtime: the pauses inside a sentence, the moment before releasing
        // the button. With DTX on top, a sustained silence falls to one byte.
        //
        // And the constraint costs nothing measurable, so it stays. It bounds
        // the peaks, which is free insurance on a link that is already
        // struggling.
        _ = c.opus_encoder_ctl(handle, c.OPUS_SET_BITRATE_REQUEST, @as(i32, bitrate));
        _ = c.opus_encoder_ctl(handle, c.OPUS_SET_VBR_REQUEST, @as(i32, 1));
        _ = c.opus_encoder_ctl(handle, c.OPUS_SET_VBR_CONSTRAINT_REQUEST, @as(i32, 1));

        // Inband FEC lets the decoder rebuild a frame the server dropped from
        // the next one; DTX makes holding the button in silence nearly free.
        _ = c.opus_encoder_ctl(handle, c.OPUS_SET_INBAND_FEC_REQUEST, @as(i32, 1));
        _ = c.opus_encoder_ctl(handle, c.OPUS_SET_PACKET_LOSS_PERC_REQUEST, @as(i32, 5));
        _ = c.opus_encoder_ctl(handle, c.OPUS_SET_DTX_REQUEST, @as(i32, 1));

        return .{ .handle = handle, .allocator = allocator, .memory = memory };
    }

    pub fn deinit(self: *Encoder) void {
        self.allocator.free(self.memory);
        self.* = undefined;
    }

    /// Encodes exactly one 20 ms frame. Returns the slice of `out` written.
    pub fn encode(self: *Encoder, pcm: []const i16, out: []u8) Error![]u8 {
        if (pcm.len != frame_size) return error.BadArgument;

        const written = c.opus_encode(
            self.handle,
            pcm.ptr,
            @intCast(frame_size),
            out.ptr,
            @intCast(out.len),
        );
        try check(written);
        return out[0..@intCast(written)];
    }
};

pub const Decoder = struct {
    handle: *c.OpusDecoder,
    allocator: std.mem.Allocator,
    memory: []align(state_align.toByteUnits()) u8,

    pub fn init(allocator: std.mem.Allocator) !Decoder {
        const size = c.opus_decoder_get_size(channels);
        const memory = try allocator.alignedAlloc(u8, state_align, @intCast(size));
        errdefer allocator.free(memory);

        const handle: *c.OpusDecoder = @ptrCast(memory.ptr);
        try check(c.opus_decoder_init(handle, sample_rate, channels));

        return .{ .handle = handle, .allocator = allocator, .memory = memory };
    }

    pub fn deinit(self: *Decoder) void {
        self.allocator.free(self.memory);
        self.* = undefined;
    }

    /// Decodes one packet into `pcm`, which must hold a whole frame.
    pub fn decode(self: *Decoder, packet: []const u8, pcm: []i16) Error!usize {
        if (pcm.len < frame_size) return error.BufferTooSmall;

        const samples = c.opus_decode(
            self.handle,
            packet.ptr,
            @intCast(packet.len),
            pcm.ptr,
            @intCast(frame_size),
            0,
        );
        try check(samples);
        return @intCast(samples);
    }

    /// Invents one frame to cover a gap. Opus reconstructs the shape of the
    /// missing speech from what came before, which is far less jarring than
    /// the click that inserting silence produces.
    pub fn conceal(self: *Decoder, pcm: []i16) Error!usize {
        if (pcm.len < frame_size) return error.BufferTooSmall;

        const samples = c.opus_decode(
            self.handle,
            null,
            0,
            pcm.ptr,
            @intCast(frame_size),
            0,
        );
        try check(samples);
        return @intCast(samples);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A second of a 440 Hz tone, which survives a codec well enough to assert on.
fn tone(buf: []i16, phase: *f32) void {
    for (buf) |*sample| {
        sample.* = @intFromFloat(@sin(phase.*) * 8000.0);
        phase.* += 2.0 * std.math.pi * 440.0 / @as(f32, @floatFromInt(sample_rate));
    }
}

test "un aller-retour rend un signal de la bonne longueur" {
    var encoder = try Encoder.init(testing.allocator, 24000);
    defer encoder.deinit();
    var decoder = try Decoder.init(testing.allocator);
    defer decoder.deinit();

    var pcm: [frame_size]i16 = undefined;
    var phase: f32 = 0;
    tone(&pcm, &phase);

    var packet: [1024]u8 = undefined;
    const encoded = try encoder.encode(&pcm, &packet);
    try testing.expect(encoded.len > 0);
    try testing.expect(encoded.len < 200);

    var out: [frame_size]i16 = undefined;
    try testing.expectEqual(frame_size, try decoder.decode(encoded, &out));
}

test "le décodeur invente une trame pour combler un trou" {
    var decoder = try Decoder.init(testing.allocator);
    defer decoder.deinit();

    var out: [frame_size]i16 = undefined;
    try testing.expectEqual(frame_size, try decoder.conceal(&out));
}

test "encoder autre chose qu'une trame entière est refusé" {
    var encoder = try Encoder.init(testing.allocator, 24000);
    defer encoder.deinit();

    var short: [100]i16 = @splat(0);
    var packet: [1024]u8 = undefined;
    try testing.expectError(error.BadArgument, encoder.encode(&short, &packet));
}

test "un paquet corrompu est rejeté, pas interprété" {
    var decoder = try Decoder.init(testing.allocator);
    defer decoder.deinit();

    var out: [frame_size]i16 = undefined;
    const garbage = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    try testing.expectError(error.InvalidPacket, decoder.decode(&garbage, &out));
}

test "le silence finit par ne plus rien coûter" {
    var encoder = try Encoder.init(testing.allocator, 24000);
    defer encoder.deinit();

    const quiet: [frame_size]i16 = @splat(0);
    var packet: [1024]u8 = undefined;

    // Le DTX ne s'enclenche qu'après une dizaine de trames : Opus attend
    // d'être sûr que c'est un silence et pas une pause entre deux mots.
    var last: usize = 0;
    for (0..15) |_| last = (try encoder.encode(&quiet, &packet)).len;

    try testing.expect(last <= 3);
}

test "le VBR fait payer la parole et pas le silence" {
    var encoder = try Encoder.init(testing.allocator, 24000);
    defer encoder.deinit();

    var packet: [1024]u8 = undefined;
    var pcm: [frame_size]i16 = undefined;
    var phase: f32 = 0;

    var speech: usize = 0;
    for (0..15) |_| {
        tone(&pcm, &phase);
        speech = (try encoder.encode(&pcm, &packet)).len;
    }

    const quiet: [frame_size]i16 = @splat(0);
    var silence: usize = 0;
    for (0..15) |_| silence = (try encoder.encode(&quiet, &packet)).len;

    // Le rapport, pas la taille : les octets exacts sont un détail
    // d'implémentation d'Opus. Ce qui doit rester vrai, et ce qui fait la
    // facture de bande passante sur un canal de push-to-talk, c'est que le
    // silence coûte une fraction de la parole — parce que le silence, c'est
    // l'essentiel du temps d'antenne.
    try testing.expect(silence * 3 < speech);

    // 60 octets, c'est ce qu'un CBR à 24 kbit/s facturerait pour cette trame.
    // Le VBR doit rester en dessous, même si l'écart sur la parole est mince.
    try testing.expect(speech <= 60);
}
