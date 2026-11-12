//! Le tampon de lecture.
//!
//! Frames arrive from a WebSocket over TCP, which means they arrive **in
//! order and complete, or not at all** — there is no reordering to undo and
//! no loss to repair. What TCP does instead is *stall*: one retransmission on
//! a bad 4G link holds everything behind it, then the backlog lands at once.
//!
//! So this is not a classic jitter buffer fighting reordering. It has one
//! job: absorb a burst and feed playback at a constant rate. The whole design
//! follows from a single rule —
//!
//!   **When we are late, we drop. We never play faster.**
//!
//! Playing a backlog at speed is what makes audio sound sped-up and chipmunky,
//! and it never actually catches up because the words still take as long to
//! say. Dropping loses a fraction of a second and stays live. On a radio,
//! being current beats being complete.
//!
//! The buffer holds *encoded* frames, not decoded audio: an Opus packet is a
//! tenth the size of its PCM, and decoding at pull time is what lets an
//! underrun ask the codec to conceal the gap instead of splicing silence in.

const std = @import("std");
const frame_mod = @import("frame.zig");

/// Every frame is 20 ms of audio. This is fixed by the encoder, and having it
/// as a constant is what turns "how many frames are queued" into milliseconds.
pub const frame_ms: u32 = 20;

pub const Config = struct {
    /// How much audio to gather before playback starts. Too low and the first
    /// hiccup underruns; too high and the radio feels laggy. Six frames is a
    /// compromise that survives a typical mobile stall.
    target_ms: u32 = 120,

    /// Above this we are no longer buffering, we are behind. Frames get
    /// dropped until we are back to `target_ms`.
    max_ms: u32 = 400,

    /// Hard ceiling on stored frames, independent of the millisecond budget —
    /// a misbehaving sender must not be able to grow this without bound.
    capacity: u16 = 64,
};

pub const PullResult = union(enum) {
    /// Nothing to play: still filling up, or the stream ended.
    silence,
    /// Play this Opus packet.
    frame: []const u8,
    /// A gap the sender never sent. Ask the decoder to conceal `count`
    /// frames — Opus does this far better than inserting silence.
    conceal: u16,
};

const Slot = struct {
    seq: u16,
    len: u16,
    bytes: [frame_mod.max_payload]u8,
};

pub const Buffer = struct {
    config: Config,

    slots: []Slot,
    head: u16 = 0,
    count: u16 = 0,

    /// The press we are currently playing. Null between transmissions.
    stream_id: ?u32 = null,
    /// Sequence of the last frame accepted, to spot gaps.
    last_seq: u16 = 0,
    /// Whether `last_seq` means anything yet for the current stream. Gap
    /// detection has to stay off until a first frame has set the reference.
    started: bool = false,
    /// False until `target_ms` has accumulated; playback holds off until then.
    playing: bool = false,
    /// Concealment owed to the decoder before the next real frame.
    pending_conceal: u16 = 0,

    /// Counters, kept because the only honest way to tune `target_ms` is to
    /// look at what a real shift on a real network actually did.
    stats: Stats = .{},

    pub const Stats = struct {
        received: u32 = 0,
        played: u32 = 0,
        dropped_late: u32 = 0,
        dropped_full: u32 = 0,
        underruns: u32 = 0,
        concealed: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Buffer {
        return .{
            .config = config,
            .slots = try allocator.alloc(Slot, config.capacity),
        };
    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn bufferedMs(self: *const Buffer) u32 {
        return @as(u32, self.count) * frame_ms;
    }

    /// Accepts a frame off the wire.
    pub fn push(self: *Buffer, f: frame_mod.Frame) void {
        self.stats.received += 1;

        // A different press: whatever is queued belongs to the previous
        // talker and must not be played over the new one.
        if (self.stream_id) |current| {
            if (current != f.stream_id) self.resetTo(f.stream_id);
        } else {
            self.resetTo(f.stream_id);
        }

        if (self.started) {
            const gap = frame_mod.distance(self.last_seq, f.seq);
            // 0 is a duplicate; anything above 1 means the server dropped
            // frames in between — under its rate limit, typically.
            if (gap == 0) return;
            if (gap > 1) {
                const missing = gap - 1;
                // A very large gap is not a gap, it is a resynchronisation.
                // Concealing seconds of audio would just be noise.
                self.pending_conceal +|= if (missing > 10) 0 else missing;
            }
        }
        self.last_seq = f.seq;
        self.started = true;

        if (self.count == self.config.capacity) {
            self.dropOldest();
            self.stats.dropped_full += 1;
        }

        const slot = &self.slots[(self.head + self.count) % self.config.capacity];
        slot.seq = f.seq;
        slot.len = @intCast(f.payload.len);
        @memcpy(slot.bytes[0..f.payload.len], f.payload);
        self.count += 1;

        // The burst case. Drop from the *front*: those are the oldest words,
        // and on a live radio the newest ones are the ones worth keeping.
        while (self.bufferedMs() > self.config.max_ms) {
            self.dropOldest();
            self.stats.dropped_late += 1;
        }

        if (!self.playing and self.bufferedMs() >= self.config.target_ms) {
            self.playing = true;
        }
    }

    /// Asks for the next 20 ms to play. Called on the audio clock, so it must
    /// always answer immediately and never block.
    pub fn pull(self: *Buffer) PullResult {
        if (self.pending_conceal > 0) {
            const n = self.pending_conceal;
            self.pending_conceal = 0;
            self.stats.concealed += n;
            return .{ .conceal = n };
        }

        if (!self.playing) return .silence;

        if (self.count == 0) {
            // Underrun. Go back to filling rather than stuttering one frame at
            // a time — a single rebuffer is less unpleasant than a rattle.
            self.playing = false;
            self.stats.underruns += 1;
            return .silence;
        }

        const slot = &self.slots[self.head];
        self.head = (self.head + 1) % self.config.capacity;
        self.count -= 1;
        self.stats.played += 1;

        return .{ .frame = slot.bytes[0..slot.len] };
    }

    /// Ends the current transmission. Anything still queued is played out —
    /// the last word of a sentence is worth the few milliseconds.
    pub fn endStream(self: *Buffer) void {
        self.stream_id = null;
    }

    fn dropOldest(self: *Buffer) void {
        if (self.count == 0) return;
        self.head = (self.head + 1) % self.config.capacity;
        self.count -= 1;
    }

    fn resetTo(self: *Buffer, stream_id: u32) void {
        self.head = 0;
        self.count = 0;
        self.playing = false;
        self.pending_conceal = 0;
        self.stream_id = stream_id;
        // Not the stats: those count the whole session, and resetting them
        // per press would hide exactly the pattern worth seeing — a network
        // that drops audio on every third transmission.
        self.started = false;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────
//
// All of this runs on a desktop. That is the point of keeping the buffer free
// of any audio device: the awkward cases — a stall, a burst, a talker cut off
// mid-word — are reproducible here, in milliseconds, without a phone.

const testing = std.testing;

/// The payload carries its own sequence number so a test can ask *which*
/// frames came out, not merely how many. `push` copies immediately, so the
/// shared scratch buffer is safe.
fn frameOf(stream_id: u32, seq: u16, tag: u8) frame_mod.Frame {
    const scratch = struct {
        var buf: [4]u8 = undefined;
    };
    scratch.buf = .{ tag, @truncate(seq), @truncate(seq >> 8), 0 };
    return .{ .stream_id = stream_id, .seq = seq, .payload = &scratch.buf };
}

/// The sequence number a played frame was built with.
fn seqOf(payload: []const u8) u16 {
    return @as(u16, payload[1]) | (@as(u16, payload[2]) << 8);
}

test "playback holds off until the target is buffered" {
    var buf = try Buffer.init(testing.allocator, .{ .target_ms = 100, .max_ms = 400 });
    defer buf.deinit(testing.allocator);

    // Four frames is 80 ms — under target, so nothing plays yet.
    for (0..4) |i| buf.push(frameOf(1, @intCast(i), 0xAA));
    try testing.expectEqual(PullResult.silence, buf.pull());

    // The fifth crosses 100 ms and playback starts.
    buf.push(frameOf(1, 4, 0xAA));
    try testing.expect(buf.pull() == .frame);
}

test "a burst is dropped, never played fast" {
    var buf = try Buffer.init(testing.allocator, .{ .target_ms = 60, .max_ms = 200 });
    defer buf.deinit(testing.allocator);

    // Thirty frames land at once — 600 ms of backlog after a stall.
    for (0..30) |i| buf.push(frameOf(1, @intCast(i), 0xBB));

    // The buffer holds at most max_ms, so the excess was dropped rather than
    // queued for a sped-up catch-up.
    try testing.expect(buf.bufferedMs() <= 200);
    try testing.expect(buf.stats.dropped_late > 0);

    // And it is the *oldest* audio that went: what comes out next is the tail
    // of the burst, which is what "stay live" means. Ten frames fit in 200 ms,
    // so playback resumes at 20 and not at 0.
    const result = buf.pull();
    try testing.expect(result == .frame);
    try testing.expectEqual(@as(u16, 20), seqOf(result.frame));
}

test "an underrun rebuffers instead of stuttering" {
    var buf = try Buffer.init(testing.allocator, .{ .target_ms = 40, .max_ms = 200 });
    defer buf.deinit(testing.allocator);

    for (0..2) |i| buf.push(frameOf(1, @intCast(i), 0xCC));
    try testing.expect(buf.pull() == .frame);
    try testing.expect(buf.pull() == .frame);

    // Nothing left: silence, and playback goes back to filling.
    try testing.expectEqual(PullResult.silence, buf.pull());
    try testing.expectEqual(@as(u32, 1), buf.stats.underruns);
    try testing.expect(!buf.playing);
}

test "a gap in the sequence asks the decoder to conceal it" {
    var buf = try Buffer.init(testing.allocator, .{ .target_ms = 20, .max_ms = 200 });
    defer buf.deinit(testing.allocator);

    buf.push(frameOf(1, 0, 0xDD));
    try testing.expect(buf.pull() == .frame);

    // Frames 1 and 2 never arrived — the server dropped them.
    buf.push(frameOf(1, 3, 0xDD));

    const result = buf.pull();
    try testing.expect(result == .conceal);
    try testing.expectEqual(@as(u16, 2), result.conceal);
}

test "a huge gap resynchronises rather than concealing seconds of audio" {
    var buf = try Buffer.init(testing.allocator, .{ .target_ms = 20, .max_ms = 200 });
    defer buf.deinit(testing.allocator);

    buf.push(frameOf(1, 0, 0xEE));
    try testing.expect(buf.pull() == .frame);

    buf.push(frameOf(1, 500, 0xEE));
    try testing.expect(buf.pull() == .frame);
    try testing.expectEqual(@as(u16, 0), buf.pending_conceal);
}

test "a duplicate frame is ignored" {
    var buf = try Buffer.init(testing.allocator, .{ .target_ms = 20, .max_ms = 200 });
    defer buf.deinit(testing.allocator);

    buf.push(frameOf(1, 0, 0xF0));
    buf.push(frameOf(1, 0, 0xF0));
    try testing.expectEqual(@as(u16, 1), buf.count);
}

test "a new talker does not inherit the previous one's backlog" {
    var buf = try Buffer.init(testing.allocator, .{ .target_ms = 200, .max_ms = 400 });
    defer buf.deinit(testing.allocator);

    // Alice queues up audio that never got played.
    for (0..5) |i| buf.push(frameOf(1, @intCast(i), 0x01));
    try testing.expectEqual(@as(u16, 5), buf.count);

    // Bob presses. Alice's words must not come out of Bob's transmission.
    buf.push(frameOf(2, 0, 0x02));
    try testing.expectEqual(@as(u16, 1), buf.count);
    try testing.expectEqual(@as(u32, 2), buf.stream_id.?);
}

test "capacity is a hard ceiling whatever the millisecond budget says" {
    var buf = try Buffer.init(testing.allocator, .{
        .target_ms = 20,
        .max_ms = 100_000, // deliberately absurd
        .capacity = 8,
    });
    defer buf.deinit(testing.allocator);

    for (0..50) |i| buf.push(frameOf(1, @intCast(i), 0x07));
    try testing.expectEqual(@as(u16, 8), buf.count);
    try testing.expect(buf.stats.dropped_full > 0);
}

test "a steady stream plays every frame it receives" {
    var buf = try Buffer.init(testing.allocator, .{ .target_ms = 60, .max_ms = 200 });
    defer buf.deinit(testing.allocator);

    // Prime the buffer, then alternate push and pull as a real clock would.
    for (0..3) |i| buf.push(frameOf(1, @intCast(i), 0x11));

    var seq: u16 = 3;
    var played: u32 = 0;
    while (seq < 100) : (seq += 1) {
        buf.push(frameOf(1, seq, 0x11));
        if (buf.pull() == .frame) played += 1;
    }

    try testing.expectEqual(@as(u32, 0), buf.stats.dropped_late);
    try testing.expectEqual(@as(u32, 0), buf.stats.underruns);
    try testing.expectEqual(@as(u32, 97), played);
}
