//! Darwin batch scheduling: writes stay on their writing handles; raw
//! writeouts run in bounded groups and volume ownership stays serial.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const airlock = @import("airlock.zig");
const seam = @import("airlock.testing");
const harness = @import("testing/harness.zig");

test "Darwin batch schedules each writeout and falls back when concurrency is unavailable" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    for ([_]bool{ false, true }) |unavailable| {
        var scratch: harness.Scratch = .init();
        defer scratch.cleanup();
        const h = try seam.Seam.create(testing.allocator, testing.io, .{});
        defer h.destroy();
        if (unavailable) try h.fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .groupConcurrent, .n = 1 } }, .fault = .{ .fail = error.ConcurrencyUnavailable }, .times = 0 }});
        const io = h.io();
        var ps: [9]airlock.Pending = undefined;
        var names: [9][8]u8 = undefined;
        var made: usize = 0;
        defer for (ps[0..made]) |*p| p.discard(io);
        var slots: [10]airlock.Batch.Slot = undefined;
        var batch: airlock.Batch = .init(&slots);
        defer batch.reset(io);
        for (&ps, &names, 0..) |*p, *buf, i| {
            const name = try std.mem.print(buf, "f{d}", .{i});
            p.* = try airlock.create(io, scratch.dir(), name, .{});
            made += 1;
            try p.file().writePositionalAll(io, "data", 0);
            try batch.addPending(io, p, .replace);
        }
        try testing.expectEqual(airlock.Reached.full, try batch.commit(io, .{ .parallel = 4 }));
        try testing.expectEqual(@as(u64, 9), h.fio.count(.groupConcurrent));
        try testing.expectEqual(@as(u32, 10), h.count(.sync_writeout));
        try testing.expectEqual(@as(u32, 1), h.count(.sync_barrier));
        try testing.expectEqual(@as(u32, 1), h.count(.sync_full));
    }
}

test "Darwin concurrent writeout failures belong to the first slot and publish nothing" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    for ([_]bool{ false, true }) |cancel| {
        var scratch: harness.Scratch = .init();
        defer scratch.cleanup();
        const h = try seam.Seam.create(testing.allocator, testing.io, .{ .plan = &.{
            .{ .at = .{ .nth = .{ .call = .sync_writeout, .n = 1, .path = .{ .exact = "b.tmp" } } }, .fault = if (cancel) .canceled else .{ .code = .IO } },
            .{ .at = .{ .nth = .{ .call = .sync_writeout, .n = 1, .path = .{ .exact = "c.tmp" } } }, .fault = .{ .code = .IO } },
        } });
        defer h.destroy();
        const io = h.io();
        var ps: [3]airlock.Pending = undefined;
        var made: usize = 0;
        defer for (ps[0..made]) |*p| p.discard(io);
        var slots: [4]airlock.Batch.Slot = undefined;
        var batch: airlock.Batch = .init(&slots);
        defer batch.reset(io);
        for (&ps, [_][]const u8{ "a", "b", "c" }, [_][]const u8{ "a.tmp", "b.tmp", "c.tmp" }) |*p, name, temp| {
            p.* = try airlock.create(io, scratch.dir(), name, .{ .temp = .{ .exact = temp } });
            made += 1;
            try p.file().writePositionalAll(io, "data", 0);
            try batch.addPending(io, p, .replace);
        }
        if (cancel) try testing.expectError(error.Canceled, batch.commit(io, .{ .parallel = 4 })) else try testing.expectError(error.InputOutput, batch.commit(io, .{ .parallel = 4 }));
        try testing.expectEqual(try airlock.Batch.SlotIndex.from(1, slots.len), batch.failure().?.slot);
        try testing.expectEqual(@as(u32, 3), h.count(.sync_writeout));
        try testing.expectEqual(@as(u32, 0), h.count(.rename));
        try testing.expectEqual(@as(u32, 0), h.count(.sync_full));
        try testing.expectEqual(@as(usize, 0), (try scratch.entries(".")).count);
    }
}

test "Darwin concurrent writeout refusal never upgrades an unsynced file" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var scratch: harness.Scratch = .init();
    defer scratch.cleanup();
    const h = try seam.Seam.create(testing.allocator, testing.io, .{ .plan = &.{seam.fail(.sync_writeout, 1, .INVAL)} });
    defer h.destroy();
    const io = h.io();
    var p = try airlock.create(io, scratch.dir(), "file", .{});
    defer p.discard(io);
    try p.file().writePositionalAll(io, "data", 0);
    var slots: [2]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addPending(io, &p, .replace);
    try testing.expectEqual(airlock.Reached.none, try batch.commit(io, .{ .parallel = 4 }));
    try testing.expectEqual(airlock.Pending.State.published, p.state());
}
