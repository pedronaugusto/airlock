//! `lock`: git's lock-file protocol, its contention and backoff, the holder
//! file byte for byte as git writes and reads it, and `Temp.suffix` under it.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const airlock = @import("airlock.zig");
const sys = @import("sys.zig");

fn contents(io: Io, dir: Io.Dir, path: []const u8, buffer: []u8) ?[]const u8 {
    return dir.readFile(io, path, buffer) catch null;
}

test "a lock is committed as the new file, and leaves nothing beside it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = "old\n" });
    var lock = try airlock.lock(io, tmp.dir, "refs/heads/main", .{ .holder = .pid_file });
    defer lock.release(io);
    var buffer: [64]u8 = undefined;
    // git's names: `<path>.lock`, and `<path>~pid.lock` beside it.
    try testing.expect(contents(io, tmp.dir, "refs/heads/main.lock", &buffer) != null);
    try testing.expect(contents(io, tmp.dir, "refs/heads/main~pid.lock", &buffer) != null);
    try lock.file().get().writePositionalAll(io, "new\n", 0);
    _ = try lock.commit(io, .{ .level = .data });
    try testing.expectEqualStrings("new\n", contents(io, tmp.dir, "refs/heads/main", &buffer).?);
    try testing.expect(contents(io, tmp.dir, "refs/heads/main.lock", &buffer) == null);
    try testing.expect(contents(io, tmp.dir, "refs/heads/main~pid.lock", &buffer) == null);
}

test "a released lock leaves the file as it was" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "old\n" });
    var lock = try airlock.lock(io, tmp.dir, "config", .{});
    try lock.file().get().writePositionalAll(io, "half", 0);
    lock.release(io);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("old\n", contents(io, tmp.dir, "config", &buffer).?);
    try testing.expect(contents(io, tmp.dir, "config.lock", &buffer) == null);
}

test "a held lock is LockHeld, at once or after waiting, and taken once released" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try airlock.lock(io, tmp.dir, "index", .{});
    try testing.expectError(error.LockHeld, airlock.lock(io, tmp.dir, "index", .{}));
    try testing.expectError(error.LockHeld, airlock.lock(io, tmp.dir, "index", .{ .contention = .{ .wait = .fromMilliseconds(20) } }));
    // Nothing a refused taker did touched the holder's lock.
    try first.file().get().writePositionalAll(io, "mine", 0);
    first.release(io);
    var second = try airlock.lock(io, tmp.dir, "index", .{});
    second.release(io);
}

test "a waiting lock is taken when its holder lets go" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try airlock.lock(io, tmp.dir, "packed-refs", .{});
    const releaser = try std.Thread.spawn(.{}, struct {
        fn run(l: *airlock.Lock, i: Io) void {
            Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(30), .clock = .awake } }, i) catch {};
            l.release(i);
        }
    }.run, .{ &first, io });
    var second = try airlock.lock(io, tmp.dir, "packed-refs", .{ .contention = .{ .wait = .fromSeconds(10) } });
    releaser.join();
    second.release(io);
}

test "the holder file is git's, and a lock git holds names its holder" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(null, try airlock.lockHolder(io, tmp.dir, "HEAD"));
    var lock = try airlock.lock(io, tmp.dir, "HEAD", .{ .holder = .pid_file });
    var buffer: [64]u8 = undefined;
    var expected: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&expected, "pid {d}\n", .{sys.processId()}), contents(io, tmp.dir, "HEAD~pid.lock", &buffer).?);
    try testing.expectEqual(sys.processId(), (try airlock.lockHolder(io, tmp.dir, "HEAD")).?.pid.?);
    lock.release(io);
    try testing.expectEqual(null, try airlock.lockHolder(io, tmp.dir, "HEAD"));
    // A lock as git leaves it: `HEAD.lock`, and `HEAD~pid.lock` with git's
    // line. It is reported, never removed.
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD.lock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD~pid.lock", .data = "pid 12345\n" });
    try testing.expectEqual(12345, (try airlock.lockHolder(io, tmp.dir, "HEAD")).?.pid.?);
    try testing.expectError(error.LockHeld, airlock.lock(io, tmp.dir, "HEAD", .{}));
    try testing.expect(contents(io, tmp.dir, "HEAD.lock", &buffer) != null);
    // A holder file that is not git's line names no one.
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD~pid.lock", .data = "pid -1\n" });
    try testing.expectEqual(null, (try airlock.lockHolder(io, tmp.dir, "HEAD")).?.pid);
    try tmp.dir.deleteFile(io, "HEAD~pid.lock");
    try testing.expectEqual(null, (try airlock.lockHolder(io, tmp.dir, "HEAD")).?.pid);
}

test "a holder file a crash left is this lock's to replace or remove" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ORIG_HEAD~pid.lock", .data = "pid 99999999\n" });
    var none = try airlock.lock(io, tmp.dir, "ORIG_HEAD", .{});
    var buffer: [64]u8 = undefined;
    try testing.expect(contents(io, tmp.dir, "ORIG_HEAD~pid.lock", &buffer) == null);
    none.release(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "ORIG_HEAD~pid.lock", .data = "pid 99999999 and more\n" });
    var mine = try airlock.lock(io, tmp.dir, "ORIG_HEAD", .{ .holder = .pid_file });
    defer mine.release(io);
    try testing.expectEqual(sys.processId(), (try airlock.lockHolder(io, tmp.dir, "ORIG_HEAD")).?.pid.?);
}

test "the backoff is git's: squares to a second, a quarter either way" {
    const backoff = airlock.Lock.backoff;
    try testing.expectEqual(1, backoff(0, 0));
    try testing.expectEqual(1, backoff(0, 499));
    try testing.expectEqual(3, backoff(1, 0));
    try testing.expectEqual(4, backoff(1, 499));
    try testing.expectEqual(75, backoff(9, 0));
    try testing.expectEqual(124, backoff(9, 499));
    // Capped at a thousand from the 32nd attempt on.
    try testing.expectEqual(750, backoff(31, 0));
    try testing.expectEqual(1249, backoff(31, 499));
    try testing.expectEqual(750, backoff(std.math.maxInt(u32), 500));
}

test "a suffixed temp is refused a separator, and a name past the longest" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.BadPathName, airlock.create(io, tmp.dir, "x", .{ .temp = .{ .suffix = "/lock" } }));
    const long: [std.fs.max_name_bytes]u8 = @splat('n');
    try testing.expectError(error.NameTooLong, airlock.create(io, tmp.dir, &long, .{ .temp = .{ .suffix = ".lock" } }));
}
