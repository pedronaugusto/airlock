//! chronicle's `writeAtomic` and its backup copy loop as they stood before
//! airlock replaced them, ported to Zig 0.17: each over strand's syncs. The
//! A/B baseline; deleted once chronicle adopts airlock.
const std = @import("std");
const Io = std.Io;
const strand = @import("strand.zig");

pub fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var buf: [64]u8 = undefined;
    const temporary = try std.mem.print(&buf, "{s}.tmp", .{name});
    errdefer dir.deleteFile(io, temporary) catch {};
    {
        const file = try dir.createFile(io, temporary, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, bytes, 0);
        try strand.syncFile(io, file, .all);
    }
    try dir.rename(temporary, dir, name, io);
    try strand.syncDir(io, dir);
}

/// The backup loop with cloning off: each copy written and synced in full,
/// then the directory.
pub fn backup(io: Io, dir: Io.Dir, names: []const []const u8, bytes: []const u8) !void {
    for (names) |name| {
        const file = try dir.createFile(io, name, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, bytes, 0);
        try strand.syncFile(io, file, .all);
    }
    try strand.syncDir(io, dir);
}
