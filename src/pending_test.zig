//! `Pending` and `writeFile`: the calls a publish makes per level and per
//! platform, each publish mode, and what every failure leaves behind.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const airlock = @import("airlock.zig");
const harness = @import("testing/harness.zig");
const Harness = harness.Harness;
const Call = harness.Call;
const expectCalls = harness.expectCalls;

const os = builtin.os.tag;
const is_windows = os == .windows;
const is_linux = os == .linux;
const is_darwin = os.isDarwin();
const is_tested_os = is_linux or is_darwin or is_windows;

const io_error: harness.Code = if (is_windows) .IO_DEVICE_ERROR else .IO;

/// The first call that syncs the temp at `data`.
const temp_sync: Call = if (is_darwin) .sync_barrier else if (is_linux) .sync_data else if (is_windows) .sync_data else .sync_plain;

fn expectContents(s: *harness.Scratch, name: []const u8, expected: ?[]const u8) !void {
    var buffer: [64]u8 = undefined;
    const got = s.read(name, &buffer);
    if (expected) |e| {
        try testing.expectEqualStrings(e, got orelse return error.TestExpectedFile);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), got);
    }
}

/// No temp is left: no entry starts with the default prefix.
fn expectNoTemps(s: *harness.Scratch) !void {
    try testing.expectEqual(@as(usize, 0), (try s.entries(".")).prefixed);
}

test "a replace at data: 2 F on Linux and Windows, 1 B + 1 F on Darwin" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("HEAD", "old");
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const done = try airlock.writeFile(h.io(), s.dir(), "HEAD", "new", .{});
    try testing.expect(!done.kept);
    try testing.expectEqual(if (is_darwin) airlock.Reached.full else airlock.Reached.data, done.reached);
    try expectContents(&s, "HEAD", "new");
    try expectNoTemps(&s);
    if (is_windows) {
        try expectCalls(h, &.{ .create_temp, .sync_data, .open_dir, .win_rename_ex, .sync_dir, .close, .close });
    } else {
        try expectCalls(h, &.{ .create_temp, temp_sync, .close, .rename, .sync_dir });
    }
}

test "a replace at ordered stops before the directory; at none it syncs nothing" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const ordered = try airlock.writeFile(h.io(), s.dir(), "a", "1", .{ .commit = .{ .level = .ordered } });
    try testing.expectEqual(airlock.Reached.ordered, ordered.reached);
    if (is_windows) {
        try expectCalls(h, &.{ .create_temp, .sync_data, .win_rename_ex, .close });
    } else {
        try expectCalls(h, &.{ .create_temp, temp_sync, .close, .rename });
    }
    h.reset();
    const none = try airlock.writeFile(h.io(), s.dir(), "b", "2", .{ .commit = .{ .level = .none } });
    try testing.expectEqual(airlock.Reached.none, none.reached);
    if (is_windows) {
        try expectCalls(h, &.{ .create_temp, .win_rename_ex, .close });
    } else {
        try expectCalls(h, &.{ .create_temp, .close, .rename });
    }
    try expectContents(&s, "a", "1");
    try expectContents(&s, "b", "2");
}

test "Darwin with barrier off: a full flush on the file and on the directory" {
    if (!is_darwin) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const done = try airlock.writeFile(h.io(), s.dir(), "a", "1", .{ .commit = .{ .barrier = false } });
    try testing.expectEqual(airlock.Reached.full, done.reached);
    try expectCalls(h, &.{ .create_temp, .sync_full, .close, .rename, .sync_dir });
}

test "a nested destination opens its directory once and syncs that one" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.dir().createDirPath(testing.io, "refs/heads");
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    _ = try airlock.writeFile(h.io(), s.dir(), "refs/heads/main", "abc", .{});
    try expectContents(&s, "refs/heads/main", "abc");
    var buffer: [16]Call = undefined;
    const got = h.calls(&buffer);
    try testing.expectEqual(Call.open_dir, got[0]);
    try testing.expectEqual(Call.close, got[got.len - 1]);
    // The directory synced is the one that received the name: it is
    // synced through the handle opened first.
    try testing.expectEqual(@as(u32, 1), h.count(.sync_dir));
}

test "create_new refuses a taken name and keep_existing keeps it" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("obj", "first");
    const io = testing.io;
    try testing.expectError(error.PathAlreadyExists, airlock.writeFile(io, s.dir(), "obj", "second", .{ .commit = .{ .publish = .create_new } }));
    try expectContents(&s, "obj", "first");
    try expectNoTemps(&s);
    const kept = try airlock.writeFile(io, s.dir(), "obj", "second", .{ .commit = .{ .publish = .keep_existing } });
    try testing.expect(kept.kept);
    // Nothing airlock did made the existing file durable.
    try testing.expectEqual(airlock.Reached.none, kept.reached);
    try expectContents(&s, "obj", "first");
    try expectNoTemps(&s);
    const fresh = try airlock.writeFile(io, s.dir(), "new", "x", .{ .commit = .{ .publish = .create_new } });
    try testing.expect(!fresh.kept);
    try expectContents(&s, "new", "x");
}

test "no-replace without the rename falls back to a link, then to a check without links" {
    if (is_windows or !is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const refusal: harness.Code = .INVAL;
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.rename_noreplace, refusal)} });
    defer h.destroy();
    _ = try airlock.writeFile(h.io(), s.dir(), "a", "1", .{ .commit = .{ .publish = .create_new } });
    try expectContents(&s, "a", "1");
    try expectNoTemps(&s);
    try testing.expectEqual(@as(u32, 1), h.count(.link));
    try testing.expectEqual(@as(u32, 1), h.count(.unlink));

    const nolink = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{
        harness.always(.rename_noreplace, refusal),
        harness.always(.link, .PERM),
    } });
    defer nolink.destroy();
    try testing.expectError(error.OperationUnsupported, airlock.writeFile(nolink.io(), s.dir(), "b", "2", .{ .commit = .{ .publish = .create_new } }));
    try expectNoTemps(&s);
    const kept = try airlock.writeFile(nolink.io(), s.dir(), "a", "other", .{ .commit = .{ .publish = .keep_existing } });
    try testing.expect(kept.kept);
    _ = try airlock.writeFile(nolink.io(), s.dir(), "c", "3", .{ .commit = .{ .publish = .keep_existing } });
    try expectContents(&s, "a", "1");
    try expectContents(&s, "c", "3");
    try expectNoTemps(&s);
}

test "a failed sync poisons: the temp is gone, the destination untouched, no rename" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("HEAD", "old");
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(temp_sync, io_error)} });
    defer h.destroy();
    var p = try airlock.create(h.io(), s.dir(), "HEAD", .{});
    defer p.discard(h.io());
    try p.file.writePositionalAll(h.io(), "new", 0);
    try testing.expectError(error.InputOutput, p.commit(h.io(), .{}));
    try testing.expectEqual(airlock.Pending.State.poisoned, p.state);
    try testing.expectEqual(@as(?anyerror, error.InputOutput), p.cause);
    try testing.expectError(error.Poisoned, p.commit(h.io(), .{}));
    try expectContents(&s, "HEAD", "old");
    try expectNoTemps(&s);
    try testing.expectEqual(@as(u32, 0), h.count(.rename) + h.count(.win_rename_ex));
    // EIO is answered by nothing: no second sync of that file, anywhere.
    try testing.expectEqual(@as(u32, 1), h.count(temp_sync));
}

test "EIO from close is a failed sync, and EINTR from close is closed" {
    if (is_windows or !is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.fail(.close, 1, .IO)} });
    defer h.destroy();
    try testing.expectError(error.InputOutput, airlock.writeFile(h.io(), s.dir(), "a", "1", .{}));
    try expectContents(&s, "a", null);
    try expectNoTemps(&s);

    const intr = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.fail(.close, 1, .INTR)} });
    defer intr.destroy();
    _ = try airlock.writeFile(intr.io(), s.dir(), "b", "2", .{});
    try testing.expectEqual(@as(u32, 1), intr.count(.close));
    try expectContents(&s, "b", "2");
}

test "a directory sync that fails after the rename is PublishedNotDurable, with its cause" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.sync_dir, io_error)} });
    defer h.destroy();
    var p = try airlock.create(h.io(), s.dir(), "a", .{});
    defer p.discard(h.io());
    try p.file.writePositionalAll(h.io(), "new", 0);
    try testing.expectError(error.PublishedNotDurable, p.commit(h.io(), .{}));
    try testing.expectEqual(@as(?anyerror, error.InputOutput), p.cause);
    try testing.expectEqual(airlock.Pending.State.published, p.state);
    try expectContents(&s, "a", "new");
    try expectNoTemps(&s);
}

test "a cancel before the rename publishes nothing; after it, PublishedNotDurable" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const rename_call: Call = if (is_windows) .win_rename_ex else .rename;
    const before = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = rename_call, .n = 1 } }, .fault = .canceled }} });
    defer before.destroy();
    var p = try airlock.create(before.io(), s.dir(), "a", .{});
    defer p.discard(before.io());
    try testing.expectError(error.Canceled, p.commit(before.io(), .{}));
    try testing.expectEqual(airlock.Pending.State.synced, p.state);
    try expectContents(&s, "a", null);
    // The retry renames without a second sync.
    _ = try p.commit(before.io(), .{});
    try testing.expectEqual(@as(u32, 1), before.count(temp_sync));
    try expectContents(&s, "a", "");

    const after = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .sync_dir, .n = 1 } }, .fault = .canceled }} });
    defer after.destroy();
    var q = try airlock.create(after.io(), s.dir(), "b", .{});
    defer q.discard(after.io());
    try testing.expectError(error.PublishedNotDurable, q.commit(after.io(), .{}));
    try testing.expectEqual(@as(?anyerror, error.Canceled), q.cause);
}

test "a rename refused for access stays synced, and the retry makes no second sync" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const rename_call: Call = if (is_windows) .win_rename_ex else .rename;
    const denied: harness.Code = if (is_windows) .ACCESS_DENIED else .ACCES;
    // Windows retries a denial until the deadline: the time layer makes
    // that instant.
    const h = try Harness.create(testing.allocator, testing.io, .{
        .plan = &.{.{ .at = .{ .nth = .{ .call = rename_call, .n = 1 } }, .fault = .{ .code = denied }, .times = if (is_windows) 0 else 1 }},
        .timed = true,
    });
    defer h.destroy();
    var p = try airlock.create(h.io(), s.dir(), "a", .{});
    defer p.discard(h.io());
    try testing.expectError(error.AccessDenied, p.commit(h.io(), .{ .busy_deadline = .fromMilliseconds(50) }));
    try testing.expectEqual(airlock.Pending.State.synced, p.state);
    h.clearPlan();
    _ = try p.commit(h.io(), .{});
    try testing.expectEqual(@as(u32, 1), h.count(temp_sync));
    try expectContents(&s, "a", "");
}

test "Windows retries a busy rename with backoff until the deadline" {
    if (!is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.win_rename_ex, .SHARING_VIOLATION)}, .timed = true });
    defer h.destroy();
    var p = try airlock.create(h.io(), s.dir(), "a", .{});
    defer p.discard(h.io());
    try testing.expectError(error.FileBusy, p.commit(h.io(), .{ .busy_deadline = .fromMilliseconds(2000) }));
    const t = h.timed.?.state;
    // Doubling from 1 ms, capped at 100 ms, with jitter in [0.5, 1.5):
    // about 25 sleeps fill 2 s, and the last one stops at the deadline.
    try testing.expect(t.sleeps >= 15 and t.sleeps <= 45);
    try testing.expectEqual(t.sleeps + 1, h.count(.win_rename_ex));
    try testing.expectEqual(airlock.Pending.State.synced, p.state);
}

test "refuse on Darwin decides before the rename: a refused flush publishes nothing" {
    if (!is_darwin) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("a", "old");
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{
        harness.always(.sync_barrier, .NOTTY),
        harness.always(.sync_full, .NOTTY),
    } });
    defer h.destroy();
    var p = try airlock.create(h.io(), s.dir(), "a", .{});
    defer p.discard(h.io());
    try p.file.writePositionalAll(h.io(), "new", 0);
    try testing.expectError(error.LevelUnavailable, p.commit(h.io(), .{ .fallback = .refuse }));
    try testing.expectEqual(@as(u32, 0), h.count(.rename));
    p.discard(h.io());
    try expectContents(&s, "a", "old");
    try expectNoTemps(&s);
}

test "refuse on Linux learns of a refused directory sync after the rename" {
    if (!is_linux) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.sync_dir, .INVAL)} });
    defer h.destroy();
    var p = try airlock.create(h.io(), s.dir(), "a", .{});
    defer p.discard(h.io());
    try testing.expectError(error.PublishedNotDurable, p.commit(h.io(), .{ .fallback = .refuse }));
    try testing.expectEqual(@as(?anyerror, error.LevelUnavailable), p.cause);
    // Reported, a refused directory sync leaves the publish ordered.
    const reported = try airlock.writeFile(h.io(), s.dir(), "b", "2", .{});
    try testing.expectEqual(airlock.Reached.ordered, reported.reached);
}

test "an exact name is a lock: taken is PathAlreadyExists, and it publishes" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.dir().createDirPath(testing.io, "refs/heads");
    const io = testing.io;
    var lock = try airlock.create(io, s.dir(), "refs/heads/main", .{ .temp = .{ .exact = "main.lock" } });
    defer lock.discard(io);
    try testing.expectError(error.PathAlreadyExists, airlock.create(io, s.dir(), "refs/heads/main", .{ .temp = .{ .exact = "main.lock" } }));
    try testing.expectError(error.BadPathName, airlock.create(io, s.dir(), "refs/heads/main", .{ .temp = .{ .exact = "a/main.lock" } }));
    try lock.file.writePositionalAll(io, "0123", 0);
    // relic's lock commit at ordered: one file sync, no directory sync.
    const h = try Harness.create(testing.allocator, io, .{});
    defer h.destroy();
    _ = try lock.commit(h.io(), .{ .level = .ordered });
    try testing.expectEqual(@as(u32, 1), h.count(temp_sync));
    try testing.expectEqual(@as(u32, 0), h.count(.sync_dir));
    try expectContents(&s, "refs/heads/main", "0123");
    try expectContents(&s, "refs/heads/main.lock", null);
}

test "a random name that collides is drawn again" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const exists: harness.Code = if (is_windows) .OBJECT_NAME_COLLISION else .EXIST;
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.fail(.create_temp, 1, exists)} });
    defer h.destroy();
    _ = try airlock.writeFile(h.io(), s.dir(), "a", "1", .{ .create = .{ .temp = .{ .random = "tmp_obj_" } } });
    try testing.expectEqual(@as(u32, 2), h.count(.create_temp));
    try testing.expectEqual(@as(usize, 0), (try s.entries("tmp_obj_")).prefixed);
    try testing.expectError(error.BadPathName, airlock.create(h.io(), s.dir(), "a", .{ .temp = .{ .random = "x/" } }));
}

test "permissions: exact ignores umask, inherit copies the destination's" {
    if (is_windows or !is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const io = testing.io;
    const exact: Io.File.Permissions = .fromMode(0o640);
    _ = try airlock.writeFile(io, s.dir(), "a", "1", .{ .create = .{ .mode = .{ .exact = exact } } });
    try testing.expectEqual(@as(std.posix.mode_t, 0o640), (try s.dir().statFile(io, "a", .{})).permissions.toMode() & 0o777);
    try s.write("b", "old");
    try s.dir().setFilePermissions(io, "b", .fromMode(0o604), .{});
    _ = try airlock.writeFile(io, s.dir(), "b", "new", .{ .create = .{ .mode = .inherit } });
    try testing.expectEqual(@as(std.posix.mode_t, 0o604), (try s.dir().statFile(io, "b", .{})).permissions.toMode() & 0o777);
}

test "the writer is flushed by commit, with writeback along the way on Linux" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    var p = try airlock.create(h.io(), s.dir(), "log", .{ .writeback_bytes = 8 });
    defer p.discard(h.io());
    var buffer: [4]u8 = undefined;
    const w = p.writer(h.io(), &buffer);
    try w.writeAll("0123456789");
    try w.writeAll("abc");
    _ = try p.commit(h.io(), .{});
    try expectContents(&s, "log", "0123456789abc");
    try testing.expectEqual(@as(u32, if (is_linux) 1 else 0), h.count(.writeback));
}

test "a writeback error is a failed sync at commit" {
    if (!is_linux) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.writeback, .IO)} });
    defer h.destroy();
    var p = try airlock.create(h.io(), s.dir(), "log", .{ .writeback_bytes = 4 });
    defer p.discard(h.io());
    var buffer: [2]u8 = undefined;
    const w = p.writer(h.io(), &buffer);
    try testing.expectError(error.WriteFailed, w.writeAll("0123456789"));
    try testing.expectError(error.InputOutput, p.commit(h.io(), .{}));
    try testing.expectEqual(airlock.Pending.State.poisoned, p.state);
    try expectNoTemps(&s);
}

test "discard is idempotent and never unlinks after the publish" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const io = testing.io;
    var p = try airlock.create(io, s.dir(), "a", .{});
    p.discard(io);
    p.discard(io);
    try expectNoTemps(&s);
    try expectContents(&s, "a", null);
    var q = try airlock.create(io, s.dir(), "b", .{});
    _ = try q.commit(io, .{});
    const h = try Harness.create(testing.allocator, io, .{});
    defer h.destroy();
    q.discard(h.io());
    q.discard(h.io());
    try expectCalls(h, &.{});
    try expectContents(&s, "b", "");
}

test "Windows: a pending delete on the lock name is Busy, a real denial is not" {
    if (!is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.fail(.create_temp, 1, .DELETE_PENDING)} });
    defer h.destroy();
    try testing.expectError(error.Busy, airlock.create(h.io(), s.dir(), "HEAD", .{ .temp = .{ .exact = "HEAD.lock" } }));
    const denied = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.fail(.create_temp, 1, .ACCESS_DENIED)} });
    defer denied.destroy();
    try testing.expectError(error.AccessDenied, airlock.create(denied.io(), s.dir(), "HEAD", .{ .temp = .{ .exact = "HEAD.lock" } }));
}

test "Windows: a replace succeeds while a reader holds the target with delete sharing" {
    if (!is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("a", "old");
    // std opens with read, write and delete sharing, as a polite scanner does.
    const reader = try s.dir().openFile(testing.io, "a", .{});
    defer reader.close(testing.io);
    _ = try airlock.writeFile(testing.io, s.dir(), "a", "new", .{});
    try expectContents(&s, "a", "new");
}
