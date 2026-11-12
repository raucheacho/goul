//! Le cœur audio, sans dépendance à une plateforme.
//!
//! Nothing here touches an audio device, a socket or a clock: bytes in, bytes
//! out. That is what makes `zig build test` meaningful — a stall, a burst, a
//! talker cut off mid-word are all reproducible on a laptop in milliseconds,
//! with no phone and no network.
//!
//! The C ABI that Kotlin, Swift and JavaScript actually call lives one layer
//! up, in abi.zig.

pub const frame = @import("frame.zig");
pub const jitter = @import("jitter.zig");
pub const codec = @import("codec.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
