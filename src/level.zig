//! Durability levels: what a caller asks for, and what a call reached.
const builtin = @import("builtin");

const native_os = builtin.target.os.tag;

/// What a caller asks a call to make durable.
pub const Level = enum {
    /// No sync at all. A replace stays atomic for the name (old or new),
    /// but after a power cut the new contents may be empty or torn.
    none,
    /// After a power cut readers see the old file or the complete new one,
    /// never a torn one; possibly the old one even after the call returned.
    ordered,
    /// Contents and length are durable, and so is any name a publish,
    /// rename, remove, batch or directory sync created, renamed or removed.
    data,
    /// As `data`, plus all metadata, timestamps included.
    full,
};

/// What an operation achieved, weakest first. Comparable:
/// `reached.atLeast(.data)`.
pub const Reached = enum(u3) {
    /// No sync call was made.
    none,
    /// Handed to the device: survives an OS crash, not a power cut. Darwin
    /// `fsync`, or a flush the filesystem refused.
    written,
    /// After a power cut: old or new, never torn; possibly not the latest.
    ordered,
    /// Durable: contents and what it takes to read them (the length).
    data,
    /// Durable: everything, timestamps included.
    full,

    /// Whether this meets the promise `level` makes.
    pub fn atLeast(r: Reached, level: Level) bool {
        return @backingInt(r) >= @backingInt(minimum(level));
    }

    /// The weakest `Reached` that keeps `level`'s promise.
    pub fn minimum(level: Level) Reached {
        return switch (level) {
            .none => .none,
            .ordered => .ordered,
            .data => .data,
            .full => .full,
        };
    }

    /// The weaker of two.
    pub fn min(a: Reached, b: Reached) Reached {
        return if (@backingInt(a) <= @backingInt(b)) a else b;
    }

    /// The stronger of two.
    pub fn max(a: Reached, b: Reached) Reached {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }

    /// What `syncFile` reaches at `level` on this platform when no
    /// filesystem refuses: the table in `platform.zig`. Callers pin their
    /// own documentation against it.
    pub fn expected(comptime level: Level) Reached {
        if (level == .none) return .none;
        if (comptime native_os.isDarwin()) return if (level == .ordered) .ordered else .full;
        return switch (native_os) {
            .linux, .windows => if (level == .full) .full else .data,
            else => .full,
        };
    }
};

/// What a publish does when the filesystem refuses the call a level needs.
/// Not a runtime option: each public call is one or the other by its name
/// (`commit` reports, `commitOrRefuse` refuses), so `error.LevelUnavailable`
/// is in the error set of exactly the calls that can return it.
pub const Fallback = enum {
    /// Degrade to the strongest call the filesystem accepts and say so in
    /// the `Reached` returned.
    report,
    /// Return `error.LevelUnavailable` instead, before anything is
    /// published, except where a platform only learns it from the
    /// directory sync (Linux; see `Pending.commitOrRefuse`).
    refuse,
};

/// The level of one sync, and the Darwin barrier choice. A sync never
/// refuses: what it reached is its answer, and a caller that wants less
/// to be an error compares it with `Reached.atLeast`.
pub const SyncOptions = struct {
    level: Level = .data,
    /// Darwin: order with `F_BARRIERFSYNC` where a barrier is enough
    /// (1 barrier and 1 flush per replace). False: a full flush instead
    /// (2 flushes), for drives whose barrier support is unknown. fcntl(2):
    /// barriers need hardware support "which Apple SSDs are guaranteed to
    /// provide".
    barrier: bool = true,
};

test "levels compare by their promise" {
    const std = @import("std");
    try std.testing.expect(Reached.full.atLeast(.data));
    try std.testing.expect(Reached.data.atLeast(.ordered));
    try std.testing.expect(!Reached.written.atLeast(.ordered));
    try std.testing.expect(Reached.none.atLeast(.none));
    try std.testing.expect(!Reached.ordered.atLeast(.data));
    try std.testing.expectEqual(Reached.written, Reached.min(.written, .full));
    try std.testing.expectEqual(Reached.full, Reached.max(.ordered, .full));
    inline for (.{ Level.none, Level.ordered, Level.data, Level.full }) |level| {
        try std.testing.expect(Reached.expected(level).atLeast(level));
    }
}
