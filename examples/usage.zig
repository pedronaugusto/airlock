//! Replace a file durably, create directories durably, stream a new object
//! in and publish it only if it is new, then make many files durable under
//! one barrier per volume.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- usage`
//! extracts the region between the usage markers into README.md, so the
//! snippet a reader copies is code CI executes.

const std = @import("std");
const Io = std.Io;
const airlock = @import("airlock");

pub fn main(init: std.process.Init) !void {
    const cwd = Io.Dir.cwd();
    const dir = try cwd.createDirPathOpen(init.io, ".zig-cache/airlock-example", .{});
    defer dir.close(init.io);

    // --- README:usage ---
    const io = init.io;

    // Replace a file: readers see the old contents or the new ones, and
    // once this returns the new ones survive a power cut.
    const config = try airlock.writeFile(io, dir, "config.json", "{\"v\":2}\n", .{});
    std.debug.assert(config.reached.atLeast(.data));

    // Create the directories an object goes into, each new one's entry
    // synced in the directory that received it.
    _ = try airlock.makePath(io, dir, "objects/ab", .{});

    // Stream into a temp next to the destination, and publish it only if
    // the name is free: an object that already exists is kept as it is.
    var object = try airlock.create(io, dir, "objects/ab/cdef", .{ .temp = .{ .random = "tmp_obj_" } });
    defer object.discard(io);
    var buffer: [4096]u8 = undefined;
    const w = object.writer(io, &buffer);
    try w.writeAll("blob 5\x00hello");

    // A batch syncs each file cheaply, flushes each volume once, renames
    // in the order the files were added, then syncs each directory once.
    var slots: [8]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addPending(io, &object, .keep_existing);
    const reached = try batch.commit(io, .{ .level = .data });
    std.debug.assert(reached.atLeast(.data));

    // Identity, not spelling: two paths to one file are one file.
    const a = try airlock.FileId.ofPath(io, dir, "objects/ab/cdef", .{});
    const b = try airlock.FileId.ofPath(io, cwd, ".zig-cache/airlock-example/objects/ab/cdef", .{});
    std.debug.assert(a.eql(b));
    // --- README:usage ---
}
