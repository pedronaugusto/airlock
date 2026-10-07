//! lookout's durable baseline save as it stood before airlock replaced it,
//! ported to Zig 0.17: `createFileAtomic`, a plain sync, the replace, a
//! plain sync of the directory. The A/B baseline; deleted once lookout
//! adopts airlock.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub fn saveDurable(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) anyerror!void {
    if (builtin.target.os.tag == .windows) return error.UnsupportedBaselineDurability;
    const parent = try dir.openDir(io, ".", .{ .iterate = true });
    defer parent.close(io);
    var file = try parent.createFileAtomic(io, name, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writePositionalAll(io, bytes, 0);
    try file.file.sync(io);
    try file.replace(io);
    const directory: Io.File = .{ .handle = parent.handle, .flags = .{ .nonblocking = false } };
    try directory.sync(io);
}
