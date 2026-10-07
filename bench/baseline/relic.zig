//! relic's durability paths as they stood before airlock replaced them,
//! ported to Zig 0.17: `Durability.syncFile` (`fsync`, then `F_FULLFSYNC` on
//! macOS), `syncPath`, the batch loop (a sync per file, then git's
//! throwaway-file barrier) and `atomicWrite`. The A/B baseline; deleted once
//! relic adopts airlock.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub fn syncFile(io: Io, file: Io.File) Io.File.SyncError!void {
    try file.sync(io);
    if (builtin.target.os.tag == .macos) {
        if (std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)) == -1) return error.InputOutput;
    }
}

pub fn syncPath(io: Io, dir: Io.Dir, path: []const u8) !void {
    const file = try dir.openFile(io, path, .{ .mode = if (builtin.target.os.tag == .windows) .read_write else .read_only });
    defer file.close(io);
    try syncFile(io, file);
}

pub fn syncDirectory(io: Io, dir: Io.Dir) !void {
    if (builtin.target.os.tag == .windows) return;
    const opened = try dir.openDir(io, ".", .{ .iterate = true });
    defer opened.close(io);
    try syncFile(io, .{ .handle = opened.handle, .flags = .{ .nonblocking = false } });
}

/// `Sync.batch`: each file's plain sync, then one barrier through a
/// throwaway file.
pub fn batch(io: Io, dir: Io.Dir, files: []const Io.File) !void {
    for (files) |f| try f.sync(io);
    const name = "relic_fsync_barrier";
    const file = try dir.createFile(io, name, .{ .exclusive = true });
    defer {
        file.close(io);
        dir.deleteFile(io, name) catch {};
    }
    try file.sync(io);
}

/// `atomicWrite` with `Sync.per_file`: a temp, its sync, a rename.
pub fn atomicWrite(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8) !void {
    var raw: [12]u8 = undefined;
    io.random(&raw);
    var name_buf: [64]u8 = undefined;
    const temp = try std.mem.print(&name_buf, "tmp_{x}", .{&raw});
    var file = try dir.createFile(io, temp, .{ .exclusive = true });
    errdefer {
        file.close(io);
        dir.deleteFile(io, temp) catch {};
    }
    try file.writePositionalAll(io, bytes, 0);
    try file.sync(io);
    file.close(io);
    try dir.rename(temp, dir, sub_path, io);
}
