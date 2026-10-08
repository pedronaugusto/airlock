//! Executor integration through shakedown's real-Io seam: publication,
//! cancellation, fallbacks, fences, kept names, and concurrent batches.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const airlock = @import("airlock.zig");
const seam = @import("airlock.testing");
const harness = @import("testing/harness.zig");

const Executor = struct {
    calls: std.atomic.Value(u32) = .init(0),
    workers: std.atomic.Value(u32) = .init(0),
    cancel_at: u32 = 0,

    fn hook(e: *Executor) airlock.Blocking {
        return .{ .context = e, .run = run };
    }

    fn run(io: Io, context: ?*anyopaque, function: *const fn (*anyopaque) void, argument: *anyopaque) Io.Cancelable!void {
        const e: *Executor = @ptrCast(@alignCast(context.?)); // safe: hook() gives this Executor as context
        try io.checkCancel();
        const n = e.calls.fetchAdd(1, .monotonic) + 1;
        if (n == e.cancel_at) return error.Canceled;
        const thread = std.Thread.spawn(.{}, work, .{ e, std.Thread.getCurrentId(), function, argument }) catch @panic("test worker unavailable");
        thread.join();
    }

    fn work(e: *Executor, caller: std.Thread.Id, function: *const fn (*anyopaque) void, argument: *anyopaque) void {
        std.debug.assert(caller != std.Thread.getCurrentId());
        function(argument);
        _ = e.workers.fetchAdd(1, .monotonic);
    }
};

test "blocking hook runs file and directory syncs elsewhere and none makes no job" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try seam.Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    var e: Executor = .{};
    const io = h.io();
    const file = try s.dir().createFile(io, "file", .{});
    defer file.close(io);
    try file.writePositionalAll(io, "contents", 0);
    _ = try airlock.syncFile(io, file, .{ .level = .none, .blocking = e.hook() });
    _ = try airlock.syncDir(io, s.dir(), .{ .level = .ordered, .blocking = e.hook() });
    try testing.expectEqual(0, e.calls.load(.monotonic));
    _ = try airlock.syncFile(io, file, .{ .blocking = e.hook() });
    _ = try airlock.syncDir(io, s.dir(), .{ .blocking = e.hook() });
    _ = try airlock.syncPath(io, s.dir(), "file", .{ .blocking = e.hook() });
    try testing.expectEqual(h.syncs(), e.workers.load(.monotonic));
    try testing.expectEqual(3, e.calls.load(.monotonic));
}

test "blocking hook cancellation preserves prepublish and postpublish states" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try seam.Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var e: Executor = .{ .cancel_at = 1 };
    var p = try airlock.create(io, s.dir(), "dest", .{});
    defer p.discard(io);
    try p.file().writePositionalAll(io, "new", 0);
    try testing.expectError(error.Canceled, p.commit(io, .{ .blocking = e.hook() }));
    try testing.expectEqual(airlock.Pending.State.open, p.state());
    var buffer: [16]u8 = undefined;
    try testing.expect(s.read("dest", &buffer) == null);
    e.calls.store(0, .monotonic);
    e.cancel_at = 2;
    try testing.expectError(error.PublishedNotDurable, p.commit(io, .{ .blocking = e.hook() }));
    try testing.expectEqual(airlock.Pending.State.published, p.state());
    try testing.expectEqual(error.Canceled, p.cause().?);
    try testing.expectEqualStrings("new", s.read("dest", &buffer).?);
}

test "blocking hook leaves shakedown refusal retries and final sync failures intact" {
    const first: seam.Call = if (builtin.os.tag.isDarwin()) .sync_full else .sync_data;
    const refused: seam.Code = if (builtin.os.tag == .windows) .INVALID_PARAMETER else .INVAL;
    const interrupted: seam.Code = if (builtin.os.tag == .windows) .CANCELLED else .INTR;
    const failed: seam.Code = if (builtin.os.tag == .windows) .IO_DEVICE_ERROR else .IO;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try seam.Seam.create(testing.allocator, testing.io, .{
        .plan = &.{ seam.fail(first, 1, interrupted), seam.fail(first, 2, refused) },
    });
    defer h.destroy();
    const file = try s.dir().createFile(h.io(), "file", .{});
    defer file.close(h.io());
    var e: Executor = .{};
    const reached = try airlock.syncFile(h.io(), file, .{ .blocking = e.hook() });
    try testing.expectEqual(if (builtin.os.tag.isDarwin()) airlock.Reached.written else airlock.Reached.full, reached);
    try testing.expectEqual(1, e.calls.load(.monotonic));
    try testing.expectEqual(3, h.syncs());
    h.setPlan(&.{seam.always(first, failed)});
    try testing.expectError(error.InputOutput, airlock.syncFile(h.io(), file, .{ .blocking = e.hook() }));
    try testing.expectEqual(1, e.calls.load(.monotonic));
}

test "blocking hook reaches batch fences kept files and all name operations" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try seam.Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var e: Executor = .{};
    try s.write("kept", "same");
    var slots: [4]airlock.Batch.Slot = undefined;
    var b: airlock.Batch = .init(&slots);
    defer b.reset(io);
    var kept = try airlock.create(io, s.dir(), "kept", .{});
    defer kept.discard(io);
    try kept.file().writePositionalAll(io, "same", 0);
    try b.addPending(io, &kept, .keep_existing);
    try b.fence();
    var p = try airlock.create(io, s.dir(), "published", .{});
    defer p.discard(io);
    try p.file().writePositionalAll(io, "new", 0);
    try b.addPending(io, &p, .replace);
    try testing.expect((try b.commitOrRefuse(io, .{ .blocking = e.hook() })).atLeast(.data));
    const sync: airlock.SyncOptions = .{ .blocking = e.hook() };
    _ = try airlock.rename(io, s.dir(), "published", s.dir(), "renamed", .{ .sync = sync });
    _ = try airlock.remove(io, s.dir(), "renamed", .{ .sync = sync });
    _ = try airlock.makePath(io, s.dir(), "a/b", .{ .sync = sync });
    if (builtin.os.tag != .windows) _ = try airlock.symLinkOrRefuse(io, s.dir(), "kept", "link", .{ .sync = sync });
    try testing.expectEqual(h.syncs(), e.workers.load(.monotonic));
    try testing.expectEqual(e.calls.load(.monotonic), e.workers.load(.monotonic));
}

test "blocking hook permits concurrent batch jobs and reads errno on the worker" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try seam.Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var e: Executor = .{};
    var files: [16]Io.File = undefined;
    var opened: usize = 0;
    defer for (files[0..opened]) |f| f.close(io);
    var slots: [16]airlock.Batch.Slot = undefined;
    var b: airlock.Batch = .init(&slots);
    defer b.reset(io);
    for (&files, 0..) |*f, i| {
        var name: [16]u8 = undefined;
        f.* = try s.dir().createFile(io, try std.mem.print(&name, "f{d}", .{i}), .{});
        opened += 1;
        try f.writePositionalAll(io, "dirty", 0);
        try b.addFile(f.*);
    }
    try testing.expect((try b.commit(io, .{ .parallel = 16, .blocking = e.hook() })).atLeast(.data));
    try testing.expectEqual(h.syncs(), e.workers.load(.monotonic));
    if (builtin.os.tag == .linux) {
        const sys = @import("sys.zig");
        try testing.expectError(error.BadHandle, sys.linuxFsync(io, e.hook(), -1, .sync_full, null));
    }
}
