//! strand's `sync.zig` as it stood before airlock replaced it, ported to Zig
//! 0.17 and otherwise unchanged: the A/B baseline for a single file's and a
//! directory's sync. Deleted once strand adopts airlock.
const std = @import("std");
const builtin = @import("builtin");

pub const SyncLevel = enum { data, all };

pub fn syncFile(io: std.Io, file: std.Io.File, level: SyncLevel) std.Io.File.SyncError!void {
    if (comptime builtin.os.tag.isDarwin()) {
        while (true) {
            switch (std.posix.errno(std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)))) {
                .SUCCESS => return,
                .INTR => continue,
                .OPNOTSUPP, .INVAL, .NOTTY, .PERM => break,
                else => return error.InputOutput,
            }
        }
    }
    if (comptime builtin.os.tag == .linux) {
        if (level == .data) while (true) {
            switch (std.os.linux.errno(std.os.linux.fdatasync(file.handle))) {
                .SUCCESS => return,
                .INTR => continue,
                .INVAL, .NOSYS => break,
                else => return error.InputOutput,
            }
        };
    }
    try file.sync(io);
}

pub fn syncDir(io: std.Io, dir: std.Io.Dir) std.Io.File.SyncError!void {
    if (comptime builtin.os.tag == .windows) return;
    try syncFile(io, .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }, .all);
}
