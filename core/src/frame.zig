//! Le format de trame audio de Goul.
//!
//! One of these sits inside every binary WebSocket frame, after Phoenix's own
//! header. It is the contract between the phone, the browser and the server,
//! so it is small and it never changes meaning:
//!
//!     ┌──────────────┬────────┬─────────────────┐
//!     │ stream_id u32│ seq u16│ paquet Opus ... │
//!     └──────────────┴────────┴─────────────────┘
//!            4            2           n
//!
//! Six bytes of overhead per 20 ms frame — 300 B/s next to roughly 3 kB/s of
//! audio. Both fields earn their place:
//!
//!   * `stream_id` marks one press of the button. It is what lets a listener
//!     tell "the same person kept talking" from "someone else started", which
//!     the play-out buffer must know: inheriting the previous talker's backlog
//!     would replay their last word over the new one.
//!
//!   * `seq` is not needed for ordering — the transport is a WebSocket over
//!     TCP, so frames arrive in order or not at all. It is there to *detect
//!     the gap* when the server drops frames under its rate limit, so the
//!     decoder can conceal the hole instead of splicing two moments of speech
//!     together.
//!
//! Little-endian, because every platform this runs on is.

const std = @import("std");

pub const header_len = 6;

/// The largest Opus packet we accept. A 20 ms frame at the bitrates used for
/// voice is well under 200 bytes; this leaves room for a client that raises
/// quality without letting a malformed length allocate anything absurd.
pub const max_payload = 1024;
pub const max_frame_len = header_len + max_payload;

pub const Frame = struct {
    stream_id: u32,
    seq: u16,
    payload: []const u8,
};

pub const ParseError = error{
    TooShort,
    PayloadTooLarge,
};

/// Writes a frame into `out`, returning the slice actually used.
pub fn encode(out: []u8, frame: Frame) error{NoSpace}![]u8 {
    const total = header_len + frame.payload.len;
    if (out.len < total) return error.NoSpace;

    std.mem.writeInt(u32, out[0..4], frame.stream_id, .little);
    std.mem.writeInt(u16, out[4..6], frame.seq, .little);
    @memcpy(out[header_len..total], frame.payload);

    return out[0..total];
}

/// Reads a frame. The payload aliases `bytes` — it is not copied, so the
/// caller keeps `bytes` alive for as long as it uses the frame.
pub fn decode(bytes: []const u8) ParseError!Frame {
    if (bytes.len < header_len) return error.TooShort;

    const payload = bytes[header_len..];
    if (payload.len > max_payload) return error.PayloadTooLarge;

    return .{
        .stream_id = std.mem.readInt(u32, bytes[0..4], .little),
        .seq = std.mem.readInt(u16, bytes[4..6], .little),
        .payload = payload,
    };
}

/// How many frames separate `previous` from `current`, given that `seq` wraps
/// at 16 bits. Returns 1 for the normal case of consecutive frames, 0 for a
/// repeat, and n>1 when the server dropped n-1 frames in between.
///
/// The wrap matters in practice: at 50 frames a second a stream passes 65535
/// after about 22 minutes, which a channel left open on a long shift reaches.
pub fn distance(previous: u16, current: u16) u16 {
    return current -% previous;
}

const testing = std.testing;

test "round trip" {
    var buf: [max_frame_len]u8 = undefined;
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    const written = try encode(&buf, .{ .stream_id = 0x11223344, .seq = 7, .payload = &payload });
    try testing.expectEqual(@as(usize, header_len + 4), written.len);

    const frame = try decode(written);
    try testing.expectEqual(@as(u32, 0x11223344), frame.stream_id);
    try testing.expectEqual(@as(u16, 7), frame.seq);
    try testing.expectEqualSlices(u8, &payload, frame.payload);
}

test "a frame may carry no audio at all" {
    // The last frame of a stream can be empty; it still has to parse.
    var buf: [header_len]u8 = undefined;
    const written = try encode(&buf, .{ .stream_id = 1, .seq = 0, .payload = &.{} });

    const frame = try decode(written);
    try testing.expectEqual(@as(usize, 0), frame.payload.len);
}

test "truncated input is rejected rather than read past" {
    try testing.expectError(error.TooShort, decode(&[_]u8{ 1, 2, 3 }));
    try testing.expectError(error.TooShort, decode(&.{}));
}

test "an oversized payload is rejected" {
    const big: [max_payload + header_len + 1]u8 = @splat(0);
    try testing.expectError(error.PayloadTooLarge, decode(&big));
}

test "encode refuses a buffer it would overrun" {
    var small: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, encode(&small, .{
        .stream_id = 1,
        .seq = 1,
        .payload = &[_]u8{ 1, 2, 3 },
    }));
}

test "distance handles the 16-bit wrap" {
    try testing.expectEqual(@as(u16, 1), distance(10, 11));
    try testing.expectEqual(@as(u16, 0), distance(10, 10));
    try testing.expectEqual(@as(u16, 3), distance(10, 13));
    // 22 minutes into a stream.
    try testing.expectEqual(@as(u16, 1), distance(65535, 0));
    try testing.expectEqual(@as(u16, 2), distance(65535, 1));
}
