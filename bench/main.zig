//! airlock's own benchmarks. `zig build bench` runs them in ReleaseFast and
//! writes one JSON line per row to stdout and to zig-out/bench/results.jsonl.
//!
//! Timings are taken by hand, on real disks, never in CI: CI disks are
//! virtual and their flush cost means nothing. CI only compiles this.
//!
//!     zig build bench -- [row prefix] [--dir <directory on the disk to measure>]
//!
//! Rows:
//! - `probe/...`: each level's sync of a 4 KiB write, and a directory sync,
//!   p50 and p99 over 1000 calls: what each level costs on this machine.
//! - `replace/<level>/<size>/<new|overwrite>`: `writeFile`, ops/s and
//!   latency.
//! - `batch/<n>/<size>/<renames|files>/p<parallel>`: files/s through a
//!   `Batch`.
//! - `ab/...`: the code airlock replaces (bench/baseline, copied from the
//!   packages before they adopted it) beside airlock on the same work.
//! - `counts/...`: the raw calls and barriers of one operation, from the
//!   test seam: W (writeout), B (barrier), F (device flush).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const airlock = @import("airlock");
const shakedown = @import("shakedown");
const strand = @import("baseline/strand.zig");
const relic = @import("baseline/relic.zig");
const lookout = @import("baseline/lookout.zig");
const chronicle = @import("baseline/chronicle.zig");

const is_linux = builtin.target.os.tag == .linux;

const Context = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// Where the files are written: a fresh directory on the disk measured.
    dir: Io.Dir,
    file: Io.File,
    page: [4096]u8 = @splat(0x5a),
    big: []u8,
    names: [1000][16]u8 = undefined,
    pendings: []airlock.Pending,
    slots: []airlock.Batch.Slot,
    files: []Io.File,
};

const Op = *const fn (ctx: *Context, row: *const Row, i: u64) anyerror!void;

const Row = struct {
    name: []const u8,
    /// Operations timed; each is one call of `op`.
    ops: u64,
    op: Op,
    level: airlock.Level = .data,
    size: usize = 4096,
    overwrite: bool = false,
    /// Files per batch.
    n: u32 = 1,
    renames: bool = true,
    parallel: u8 = 1,
    barrier: bool = true,
};

const rows = probe_rows ++ replace_rows ++ batch_rows ++ ab_rows;

const probe_rows = [_]Row{
    .{ .name = "probe/sync-ordered", .ops = 1000, .op = probeSync, .level = .ordered },
    .{ .name = "probe/sync-ordered-no-barrier", .ops = 1000, .op = probeSync, .level = .ordered, .barrier = false },
    .{ .name = "probe/sync-data", .ops = 1000, .op = probeSync, .level = .data },
    .{ .name = "probe/sync-full", .ops = 1000, .op = probeSync, .level = .full },
    .{ .name = "probe/dir-data", .ops = 1000, .op = probeDir },
};

const replace_rows = blk: {
    var out: []const Row = &.{};
    for ([_]airlock.Level{ .none, .ordered, .data, .full }) |level| {
        for ([_]usize{ 4096, 1 << 20 }) |size| {
            for ([_]bool{ false, true }) |overwrite| {
                out = out ++ [_]Row{.{
                    .name = "replace/" ++ @tagName(level) ++ (if (size == 4096) "/4k" else "/1m") ++ (if (overwrite) "/overwrite" else "/new"),
                    .ops = if (size == 4096) 200 else 50,
                    .op = replace,
                    .level = level,
                    .size = size,
                    .overwrite = overwrite,
                }};
            }
        }
    }
    break :blk out[0..out.len].*;
};

const batch_rows = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: []const Row = &.{};
    for ([_]u32{ 1, 10, 100, 1000 }) |n| {
        for ([_]usize{ 4096, 65536 }) |size| {
            for ([_]bool{ true, false }) |renames| {
                for ([_]u8{ 1, 4, 16, 64 }) |parallel| {
                    out = out ++ [_]Row{.{
                        .name = std.fmt.comptimePrint("batch/{d}/{s}/{s}/p{d}", .{ n, if (size == 4096) "4k" else "64k", if (renames) "renames" else "files", parallel }),
                        .ops = if (n >= 100) 3 else 20,
                        .op = batch,
                        .size = size,
                        .n = n,
                        .renames = renames,
                        .parallel = parallel,
                    }};
                }
            }
        }
    }
    break :blk out[0..out.len].*;
};

const ab_rows = [_]Row{
    .{ .name = "ab/file-data/strand", .ops = 500, .op = abStrandFile },
    .{ .name = "ab/file-data/relic", .ops = 500, .op = abRelicFile },
    .{ .name = "ab/file-data/airlock", .ops = 500, .op = probeSync, .level = .data },
    .{ .name = "ab/replace/relic-atomic-write", .ops = 200, .op = abRelicAtomic },
    .{ .name = "ab/replace/lookout-durable-save", .ops = 200, .op = abLookout },
    .{ .name = "ab/replace/chronicle-write-atomic", .ops = 200, .op = abChronicle },
    .{ .name = "ab/replace/airlock", .ops = 200, .op = replace, .overwrite = true },
    .{ .name = "ab/batch-100/relic", .ops = 5, .op = abRelicBatch, .n = 100 },
    .{ .name = "ab/batch-100/relic-durability", .ops = 5, .op = abRelicDurability, .n = 100 },
    .{ .name = "ab/batch-100/chronicle-backup", .ops = 5, .op = abChronicleBackup, .n = 100 },
    .{ .name = "ab/batch-100/airlock", .ops = 5, .op = batch, .n = 100, .renames = false },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var prefix: []const u8 = "";
    var target: []const u8 = "zig-out/bench/scratch";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir") and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else prefix = args[i];
    }

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out/bench");
    var out_file = try cwd.createFile(io, "zig-out/bench/results.jsonl", .{});
    defer out_file.close(io);
    var out_buffer: [4096]u8 = undefined;
    var out = out_file.writer(io, &out_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);

    cwd.deleteTree(io, target) catch {};
    var dir = try cwd.createDirPathOpen(io, target, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "probe", .data = "" });
    const file = try dir.openFile(io, "probe", .{ .mode = .read_write });
    defer file.close(io);

    var ctx: Context = .{
        .io = io,
        .gpa = gpa,
        .dir = dir,
        .file = file,
        .big = try gpa.alloc(u8, 1 << 20),
        .pendings = try gpa.alloc(airlock.Pending, 1000),
        .slots = try gpa.alloc(airlock.Batch.Slot, 1000),
        .files = try gpa.alloc(Io.File, 1000),
    };
    defer gpa.free(ctx.big);
    defer gpa.free(ctx.pendings);
    defer gpa.free(ctx.slots);
    defer gpa.free(ctx.files);
    @memset(ctx.big, 0xa5);
    for (&ctx.names, 0..) |*name, n| _ = try std.mem.print(name, "f{d:0>6}", .{n});

    for (rows) |row| {
        if (!std.mem.startsWith(u8, row.name, prefix)) continue;
        if (row.parallel > 1 and !is_linux and !std.mem.endsWith(u8, row.name, "p16")) continue;
        const samples = try gpa.alloc(u64, row.ops);
        defer gpa.free(samples);
        for (samples, 0..) |*sample, n| {
            const start = Io.Timestamp.now(io, .awake);
            try row.op(&ctx, &row, n);
            sample.* = @intCast(start.durationTo(.now(io, .awake)).nanoseconds);
        }
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        var total: u64 = 0;
        for (samples) |s| total += s;
        const per_second = @as(f64, @floatFromInt(row.ops * @max(row.n, 1))) * std.time.ns_per_s / @as(f64, @floatFromInt(@max(total, 1)));
        const fmt = "{{\"row\":\"{s}\",\"ops\":{d},\"p50_us\":{d:.1},\"p99_us\":{d:.1},\"per_second\":{d:.1}}}\n";
        const values = .{ row.name, row.ops, micros(samples[samples.len / 2]), micros(samples[(samples.len * 99) / 100]), per_second };
        try out.interface.print(fmt, values);
        try stdout.interface.print(fmt, values);
        try stdout.interface.flush();
    }
    if (std.mem.startsWith(u8, "counts", prefix[0..@min(prefix.len, 6)])) try counts(&ctx, &out.interface, &stdout.interface);
    try out.interface.flush();
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}

// Rows.

fn probeSync(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    try ctx.file.writePositionalAll(ctx.io, &ctx.page, (i % 256) * 4096);
    _ = try airlock.syncFile(ctx.io, ctx.file, .{ .level = row.level, .barrier = row.barrier });
}

fn probeDir(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    const name = ctx.names[i % ctx.names.len][0..7];
    try ctx.dir.writeFile(ctx.io, .{ .sub_path = name, .data = "" });
    _ = try airlock.syncDir(ctx.io, ctx.dir, .{});
    try ctx.dir.deleteFile(ctx.io, name);
}

fn replace(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    const name = if (row.overwrite) "replaced" else ctx.names[i % ctx.names.len][0..7];
    const bytes = if (row.size == 4096) &ctx.page else ctx.big[0..row.size];
    _ = try airlock.writeFile(ctx.io, ctx.dir, name, bytes, .{ .commit = .{ .level = row.level } });
}

fn batch(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    const io = ctx.io;
    const bytes = if (row.size == 4096) &ctx.page else ctx.big[0..row.size];
    var b: airlock.Batch = .init(ctx.slots[0..row.n]);
    defer b.reset(io);
    if (row.renames) {
        for (ctx.pendings[0..row.n], 0..) |*p, n| {
            p.* = try airlock.create(io, ctx.dir, ctx.names[n][0..7], .{});
            try p.file().writePositionalAll(io, bytes, 0);
            try b.addPending(io, p, .replace);
        }
    } else {
        for (ctx.files[0..row.n], 0..) |*f, n| {
            f.* = try ctx.dir.createFile(io, ctx.names[n][0..7], .{ .read = true });
            try f.writePositionalAll(io, bytes, 0);
            try b.addFile(f.*);
        }
    }
    defer if (!row.renames) for (ctx.files[0..row.n]) |f| f.close(io);
    _ = try b.commit(io, .{ .level = .data, .parallel = row.parallel });
}

fn abStrandFile(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    try ctx.file.writePositionalAll(ctx.io, &ctx.page, (i % 256) * 4096);
    try strand.syncFile(ctx.io, ctx.file, .data);
}

fn abRelicFile(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    try ctx.file.writePositionalAll(ctx.io, &ctx.page, (i % 256) * 4096);
    try relic.syncFile(ctx.io, ctx.file);
}

fn abRelicAtomic(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    _ = i;
    try relic.atomicWrite(ctx.io, ctx.dir, "replaced", &ctx.page);
}

fn abLookout(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    _ = i;
    lookout.saveDurable(ctx.io, ctx.dir, "replaced", &ctx.page) catch |err| switch (err) {
        error.UnsupportedBaselineDurability => {},
        else => |e| return e,
    };
}

fn abChronicle(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    _ = i;
    try chronicle.writeAtomic(ctx.io, ctx.dir, "replaced", &ctx.page);
}

fn writeFiles(ctx: *Context, n: u32) !void {
    for (ctx.files[0..n], 0..) |*f, k| {
        f.* = try ctx.dir.createFile(ctx.io, ctx.names[k][0..7], .{ .read = true });
        try f.writePositionalAll(ctx.io, &ctx.page, 0);
    }
}

fn abRelicBatch(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    try writeFiles(ctx, row.n);
    defer for (ctx.files[0..row.n]) |f| f.close(ctx.io);
    try relic.batch(ctx.io, ctx.dir, ctx.files[0..row.n]);
}

fn abRelicDurability(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    try writeFiles(ctx, row.n);
    for (ctx.files[0..row.n]) |f| f.close(ctx.io);
    for (ctx.names[0..row.n]) |*name| try relic.syncPath(ctx.io, ctx.dir, name[0..7]);
    try relic.syncDirectory(ctx.io, ctx.dir);
}

fn abChronicleBackup(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    var names: [100][]const u8 = undefined;
    for (names[0..row.n], 0..) |*name, k| name.* = ctx.names[k][0..7];
    try chronicle.backup(ctx.io, ctx.dir, names[0..row.n], &ctx.page);
}

// Counts: the raw calls of one operation, through the test seam.

const Counter = struct {
    calls: [@typeInfo(airlock.sys.Call).@"enum".field_names.len]u32 = @splat(0),

    fn call(ctx: *anyopaque, c: airlock.sys.Call, path: ?[]const u8) ?airlock.sys.Result {
        _ = path;
        const self: *Counter = @ptrCast(@alignCast(ctx)); // safe: the hook's ctx is its counter
        self.calls[@backingInt(c)] += 1;
        return null;
    }
};

const Hooked = shakedown.Layer(airlock.sys.HookedState, .{ .fileSync = airlock.sys.hookedSync });

fn counts(ctx: *Context, out: *Io.Writer, stdout: *Io.Writer) !void {
    const cases = [_]Row{
        .{ .name = "counts/replace-ordered", .ops = 1, .op = replace, .level = .ordered, .overwrite = true },
        .{ .name = "counts/replace-data", .ops = 1, .op = replace, .level = .data, .overwrite = true },
        .{ .name = "counts/replace-data-no-barrier", .ops = 1, .op = countReplaceNoBarrier, .overwrite = true },
        .{ .name = "counts/batch-100-renames", .ops = 1, .op = batch, .n = 100 },
        .{ .name = "counts/batch-100-files", .ops = 1, .op = batch, .n = 100, .renames = false },
    };
    for (cases) |row| {
        var counter: Counter = .{};
        const hook: airlock.sys.Hook = .{ .ctx = &counter, .call = Counter.call, .base = ctx.io };
        var hooked: Hooked = .init(ctx.io, .{ .hook = &hook });
        var counted = ctx.*;
        counted.io = hooked.io();
        try row.op(&counted, &row, 0);
        const c = counter.calls;
        const C = airlock.sys.Call;
        const w = c[@backingInt(C.sync_writeout)] + c[@backingInt(C.sync_plain)];
        const b = c[@backingInt(C.sync_barrier)];
        const f = c[@backingInt(C.sync_full)] + c[@backingInt(C.sync_dir)] + c[@backingInt(C.sync_data)];
        const fmt = "{{\"row\":\"{s}\",\"W\":{d},\"B\":{d},\"F\":{d},\"calls\":{d}}}\n";
        var total: u32 = 0;
        for (c) |n| total += n;
        try out.print(fmt, .{ row.name, w, b, f, total });
        try stdout.print(fmt, .{ row.name, w, b, f, total });
        try stdout.flush();
    }
}

fn countReplaceNoBarrier(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    _ = i;
    _ = try airlock.writeFile(ctx.io, ctx.dir, "replaced", &ctx.page, .{ .commit = .{ .barrier = false } });
}
