//! airlock's own benchmarks. `zig build bench` runs every row in
//! ReleaseFast in a fresh directory and prints one JSON line per row.
//!
//! Timings are taken by hand, on real disks, never in CI: CI disks are
//! virtual and their flush cost means nothing. `zig build test` invokes
//! `--smoke`, which returns at startup without measuring rows.
//!
//!     zig-out/bench/airlock-bench [row prefix] [--dir <directory on the disk to measure>]
//!
//! Rows:
//! - `probe/...`: each level's sync of a 4 KiB write, and a directory sync,
//!   p50 and p99 over 1000 calls: what each level costs on this machine.
//! - `replace/<level>/<size>/<new|overwrite>`: `writeFile`, ops/s and
//!   latency.
//! - `batch/<n>/<size>/<renames|files|paths>/p<parallel>`: files/s
//!   through a `Batch`.
//! - `ops/...`: every other public operation at `data`: `syncPath`,
//!   `rename`, `remove`, `makePath` (three new directories), `symLink`,
//!   `writeFile` as create-new and keep-existing, and `pruneTemps` over
//!   `n` leftovers (per second counts the temps).
//! - `ab/...`: the code airlock replaces (bench/baseline, copied from relic,
//!   which has not adopted it yet) beside airlock on the same work.
//! - `counts/...`: the raw calls and barriers of one operation, from
//!   `airlock.testing`'s seam: W (writeout), B (barrier), F (device flush).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const airlock = @import("airlock");
const seam = @import("airlock.testing");
const primitives = @import("primitives.zig");
const relic = @import("baseline/relic.zig");

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
    /// Files per batch, or temps per prune.
    n: u32 = 1,
    renames: bool = true,
    /// A batch of `addPath` files rather than open ones.
    paths: bool = false,
    parallel: u8 = 1,
    barrier: bool = true,
    primitive: ?primitives.Kind = null,
    directory: bool = false,
    include_dir: bool = false,
    append: bool = false,
    offload: bool = false,
};

const hook_rows = [_]Row{
    .{ .name = "hook/sync-data/inline", .ops = 1000, .op = probeSync },
    .{ .name = "hook/sync-data/offloaded", .ops = 1000, .op = probeSync, .offload = true },
    .{ .name = "hook/replace/inline", .ops = 200, .op = replace, .overwrite = true },
    .{ .name = "hook/replace/offloaded", .ops = 200, .op = replace, .overwrite = true, .offload = true },
    .{ .name = "hook/batch-100/inline", .ops = 5, .op = batch, .n = 100, .renames = false, .include_dir = true, .parallel = 16 },
    .{ .name = "hook/batch-100/offloaded", .ops = 5, .op = batch, .n = 100, .renames = false, .include_dir = true, .parallel = 16, .offload = true },
};

const rows = hook_rows ++ probe_rows ++ replace_rows ++ batch_rows ++ op_rows ++ ab_rows;

const primitive_rows = if (builtin.os.tag == .windows) [_]Row{
    .{ .name = "probe/raw/nt-full", .ops = 1000, .op = probeRaw, .primitive = .nt_full },
    .{ .name = "probe/raw/nt-data", .ops = 1000, .op = probeRaw, .primitive = .nt_data },
    .{ .name = "probe/raw/nt-write-data", .ops = 1000, .op = probeRaw, .primitive = .nt_write_data },
    .{ .name = "probe/raw/nt-writeout", .ops = 1000, .op = probeRaw, .primitive = .nt_writeout },
} else if (builtin.os.tag.isDarwin()) [_]Row{
    .{ .name = "probe/raw/fsync", .ops = 1000, .op = probeRaw, .primitive = .fsync },
    .{ .name = "probe/raw/fdatasync", .ops = 1000, .op = probeRaw, .primitive = .fdatasync },
    .{ .name = "probe/raw/full", .ops = 1000, .op = probeRaw, .primitive = .full },
    .{ .name = "probe/raw/barrier", .ops = 1000, .op = probeRaw, .primitive = .barrier },
} else [_]Row{
    .{ .name = "probe/raw/fsync", .ops = 1000, .op = probeRaw, .primitive = .fsync },
    .{ .name = "probe/raw/fdatasync", .ops = 1000, .op = probeRaw, .primitive = .fdatasync },
};

const probe_rows = primitive_rows ++ [_]Row{
    .{ .name = "probe/sync-ordered", .ops = 1000, .op = probeSync, .level = .ordered },
    .{ .name = "probe/sync-ordered-no-barrier", .ops = 1000, .op = probeSync, .level = .ordered, .barrier = false },
    .{ .name = "probe/sync-data", .ops = 1000, .op = probeSync, .level = .data },
    .{ .name = "probe/sync-full", .ops = 1000, .op = probeSync, .level = .full },
    .{ .name = "probe/dir-data", .ops = 1000, .op = probeDir, .directory = true },
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
            for ([_][]const u8{ "renames", "files", "paths" }) |kind| {
                for ([_]u8{ 1, 4, 16, 64 }) |parallel| {
                    out = out ++ [_]Row{.{
                        .name = std.fmt.comptimePrint("batch/{d}/{s}/{s}/p{d}", .{ n, if (size == 4096) "4k" else "64k", kind, parallel }),
                        .ops = if (n >= 100) 3 else 20,
                        .op = batch,
                        .size = size,
                        .n = n,
                        .renames = std.mem.eql(u8, kind, "renames"),
                        .paths = std.mem.eql(u8, kind, "paths"),
                        .parallel = parallel,
                    }};
                }
            }
        }
    }
    break :blk out[0..out.len].*;
};

const op_rows = [_]Row{
    .{ .name = "ops/sync-path", .ops = 500, .op = syncPathRow },
    .{ .name = "ops/rename", .ops = 200, .op = renameRow },
    .{ .name = "ops/remove", .ops = 200, .op = removeRow },
    .{ .name = "ops/make-path", .ops = 100, .op = makePathRow },
    .{ .name = "ops/sym-link", .ops = 200, .op = symLinkRow },
    .{ .name = "ops/create-new", .ops = 200, .op = createNewRow },
    .{ .name = "ops/keep-existing", .ops = 200, .op = keepExistingRow },
    .{ .name = "ops/prune/100", .ops = 10, .op = pruneRow, .n = 100 },
};

const ab_rows = [_]Row{
    .{ .name = "ab/file-data/relic", .ops = 500, .op = abRelicFile },
    .{ .name = "ab/file-data/airlock", .ops = 500, .op = probeSync, .level = .full },
    .{ .name = "ab/append/flush-each", .ops = 500, .op = abRelicFile, .append = true },
    .{ .name = "ab/append/airlock", .ops = 500, .op = probeSync, .level = .full, .append = true },
    .{ .name = "ab/replace/relic-atomic-write", .ops = 200, .op = abRelicAtomic },
    .{ .name = "ab/replace/airlock", .ops = 200, .op = replace, .overwrite = true },
    .{ .name = "ab/batch-100/relic", .ops = 5, .op = abRelicBatch, .n = 100 },
    .{ .name = "ab/batch-100/relic-durability", .ops = 5, .op = abRelicDurability, .n = 100 },
    .{ .name = "ab/batch-100/flush-each", .ops = 5, .op = abFlushEach, .n = 100 },
    .{ .name = "ab/batch-100/airlock-sequential", .ops = 5, .op = batch, .n = 100, .renames = false, .include_dir = true, .level = .full },
    .{ .name = "ab/batch-100/airlock", .ops = 5, .op = batch, .n = 100, .renames = false, .include_dir = true, .level = .full, .parallel = 16 },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var prefix: []const u8 = "";
    var target: []const u8 = "scratch";
    var smoke = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir") and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else if (std.mem.eql(u8, args[i], "--smoke")) {
            smoke = true;
        } else prefix = args[i];
    }

    // Hosted CI compiles all rows but records no virtual-disk measurements.
    if (smoke) return;

    const cwd = Io.Dir.cwd();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);

    // --dir is a disk selection, never a tree to delete. Own only a fresh child.
    var parent = try cwd.createDirPathOpen(io, target, .{});
    defer parent.close(io);
    var random: [16]u8 = undefined;
    io.random(&random);
    var scratch_buffer: [64]u8 = undefined;
    const scratch = try std.mem.print(&scratch_buffer, "airlock-bench-{x}", .{&random});
    try parent.createDir(io, scratch, .default_dir);
    defer parent.deleteTree(io, scratch) catch {};
    var root = try parent.openDir(io, scratch, .{});
    defer root.close(io);

    var ctx: Context = .{
        .io = io,
        .gpa = gpa,
        .dir = undefined,
        .file = undefined,
        .big = try gpa.alloc(u8, 1 << 20),
        .pendings = try gpa.alloc(airlock.Pending, 1000),
        .slots = try gpa.alloc(airlock.Batch.Slot, 1001),
        .files = try gpa.alloc(Io.File, 1000),
    };
    defer gpa.free(ctx.big);
    defer gpa.free(ctx.pendings);
    defer gpa.free(ctx.slots);
    defer gpa.free(ctx.files);
    @memset(ctx.big, 0xa5);
    for (&ctx.names, 0..) |*name, n| _ = try std.mem.print(name, "f{d:0>6}", .{n});

    for (rows) |full| {
        if (!std.mem.startsWith(u8, full.name, prefix)) continue;
        if (std.mem.startsWith(u8, full.name, "batch/") and full.parallel > 1 and !is_linux and !std.mem.endsWith(u8, full.name, "p16")) continue;
        const row = full;
        try root.createDir(io, "row", .default_dir);
        ctx.dir = try root.openDir(io, "row", .{ .iterate = true });
        defer root.deleteTree(io, "row") catch {};
        defer ctx.dir.close(io);
        ctx.file = try ctx.dir.createFile(io, "probe", .{ .read = true });
        defer ctx.file.close(io);
        if (row.overwrite) try ctx.dir.writeFile(io, .{ .sub_path = "replaced", .data = ctx.big[0..row.size] });
        const samples = try gpa.alloc(u64, row.ops);
        defer gpa.free(samples);
        var refused = false;
        for (samples, 0..) |*sample, n| {
            if (std.mem.startsWith(u8, row.name, "probe/") or std.mem.startsWith(u8, row.name, "hook/sync-data/") or std.mem.startsWith(u8, row.name, "ab/file-data/") or row.append) {
                if (row.directory) {
                    try ctx.dir.writeFile(io, .{ .sub_path = "entry", .data = &ctx.page });
                } else try ctx.file.writePositionalAll(io, &ctx.page, (if (row.append) n else n % 256) * 4096);
            }
            const start = Io.Timestamp.now(io, .awake);
            row.op(&ctx, &row, n) catch |err| {
                if (err != error.Refused) return err;
                refused = true;
                break;
            };
            sample.* = @intCast(start.durationTo(.now(io, .awake)).nanoseconds);
            if (row.directory) try ctx.dir.deleteFile(io, "entry");
        }
        if (refused) {
            try stdout.interface.print("{{\"row\":\"{s}\",\"refused\":true}}\n", .{row.name});
            try stdout.interface.flush();
            continue;
        }
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        var total: u64 = 0;
        for (samples) |s| total += s;
        const per_second = @as(f64, @floatFromInt(row.ops * @max(row.n, 1))) * std.time.ns_per_s / @as(f64, @floatFromInt(@max(total, 1)));
        const tally = if (row.primitive != null) switch (row.primitive.?) {
            .barrier => Tally{ .b = 1, .raw_calls = 1 },
            .fsync, .fdatasync => if (builtin.os.tag.isDarwin()) Tally{ .w = 1, .raw_calls = 1 } else Tally{ .f = 1, .raw_calls = 1 },
            .nt_writeout, .nt_write_data => Tally{ .w = 1, .raw_calls = 1 },
            else => Tally{ .f = 1, .raw_calls = 1 },
        } else try tallyRow(&ctx, &row);
        const fmt = "{{\"row\":\"{s}\",\"ops\":{d},\"p50_us\":{d:.1},\"p99_us\":{d:.1},\"per_second\":{d:.1},\"W\":{d},\"B\":{d},\"F\":{d},\"raw_calls\":{d},\"counts_available\":{s}}}\n";
        try stdout.interface.print(fmt, .{ row.name, row.ops, micros(samples[samples.len / 2]), micros(samples[(samples.len * 99) / 100]), per_second, tally.w, tally.b, tally.f, tally.raw_calls, if (std.mem.indexOf(u8, row.name, "relic") != null or std.mem.eql(u8, row.name, "ab/append/flush-each")) "false" else "true" });
        try stdout.interface.flush();
    }
    if (std.mem.startsWith(u8, "counts/", prefix) or std.mem.startsWith(u8, prefix, "counts/")) {
        try root.createDir(io, "counts", .default_dir);
        ctx.dir = try root.openDir(io, "counts", .{ .iterate = true });
        defer ctx.dir.close(io);
        try counts(&ctx, &stdout.interface);
    }
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}

// Rows.

fn rowBlocking(row: *const Row) ?airlock.Blocking {
    return if (row.offload) .{ .run = execute } else null;
}

/// A benchmark adapter over Threaded's pool, not a runtime supplied by airlock.
fn perform(function: *const fn (*anyopaque) void, argument: *anyopaque) void {
    function(argument);
}

fn execute(io: Io, context: ?*anyopaque, function: *const fn (*anyopaque) void, argument: *anyopaque) Io.Cancelable!void {
    _ = context;
    try io.checkCancel();
    var job = io.concurrent(perform, .{ function, argument }) catch {
        function(argument);
        return;
    };
    job.await(io);
}

fn probeSync(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    _ = try airlock.syncFile(ctx.io, ctx.file, .{ .level = row.level, .barrier = row.barrier, .blocking = rowBlocking(row) });
}

fn probeRaw(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    try primitives.sync(ctx.file.handle, row.primitive.?);
}

fn probeDir(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    _ = i;
    _ = try airlock.syncDir(ctx.io, ctx.dir, .{});
}

fn replace(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    const name = if (row.overwrite) "replaced" else ctx.names[i % ctx.names.len][0..7];
    const bytes = if (row.size == 4096) &ctx.page else ctx.big[0..row.size];
    _ = try airlock.writeFile(ctx.io, ctx.dir, name, bytes, .{ .commit = .{ .level = row.level, .blocking = rowBlocking(row) } });
}

fn batch(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    const io = ctx.io;
    const bytes = if (row.size == 4096) &ctx.page else ctx.big[0..row.size];
    var b: airlock.Batch = .init(ctx.slots[0 .. row.n + @intFromBool(row.include_dir)]);
    defer b.reset(io);
    if (row.renames) {
        for (ctx.pendings[0..row.n], 0..) |*p, n| {
            p.* = try airlock.create(io, ctx.dir, ctx.names[n][0..7], .{});
            try p.file().writePositionalAll(io, bytes, 0);
            try b.addPending(io, p, .replace);
        }
    } else if (row.paths) {
        for (ctx.names[0..row.n]) |*name| {
            try ctx.dir.writeFile(io, .{ .sub_path = name[0..7], .data = bytes });
            try b.addPath(ctx.dir, name[0..7]);
        }
    } else {
        for (ctx.files[0..row.n], 0..) |*f, n| {
            f.* = try ctx.dir.createFile(io, ctx.names[n][0..7], .{ .read = true });
            try f.writePositionalAll(io, bytes, 0);
            try b.addFile(f.*);
        }
    }
    defer if (!row.renames and !row.paths) for (ctx.files[0..row.n]) |f| f.close(io);
    if (row.include_dir) try b.addDir(ctx.dir);
    _ = try b.commit(io, .{ .level = row.level, .parallel = row.parallel, .blocking = rowBlocking(row) });
}

fn syncPathRow(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    try ctx.file.writePositionalAll(ctx.io, &ctx.page, (i % 256) * 4096);
    _ = try airlock.syncPath(ctx.io, ctx.dir, "probe", .{});
}

/// One rename of a pair of names back and forth, at `data`.
fn renameRow(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    if (i == 0) try ctx.dir.writeFile(ctx.io, .{ .sub_path = "ping", .data = &ctx.page });
    const from, const to = if (i % 2 == 0) .{ "ping", "pong" } else .{ "pong", "ping" };
    _ = try airlock.rename(ctx.io, ctx.dir, from, ctx.dir, to, .{});
}

/// A file made by std, then removed by airlock at `data`.
fn removeRow(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    const name = ctx.names[i % ctx.names.len][0..7];
    try ctx.dir.writeFile(ctx.io, .{ .sub_path = name, .data = "" });
    _ = try airlock.remove(ctx.io, ctx.dir, name, .{});
}

/// Three new directories under a new top one.
fn makePathRow(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    var buffer: [32]u8 = undefined;
    const path = try std.mem.print(&buffer, "tree{d}/a/b", .{i});
    _ = try airlock.makePath(ctx.io, ctx.dir, path, .{});
}

/// A link swapped between two targets (not on Windows, where airlock
/// makes no links).
fn symLinkRow(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    if (builtin.target.os.tag == .windows) return;
    _ = try airlock.symLink(ctx.io, ctx.dir, if (i % 2 == 0) "release-a" else "release-b", "current", .{});
}

fn createNewRow(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    const name = ctx.names[i % ctx.names.len][0..7];
    ctx.dir.deleteFile(ctx.io, name) catch {};
    _ = try airlock.writeFile(ctx.io, ctx.dir, name, &ctx.page, .{ .commit = .{ .publish = .create_new } });
}

/// A name that is always taken: the temp is synced, then removed.
fn keepExistingRow(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    if (i == 0) try ctx.dir.writeFile(ctx.io, .{ .sub_path = "kept", .data = &ctx.page });
    _ = try airlock.writeFile(ctx.io, ctx.dir, "kept", &ctx.page, .{ .commit = .{ .publish = .keep_existing } });
}

/// `n` leftovers with a random temp's name, then one prune of them all.
fn pruneRow(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    var dir = try ctx.dir.createDirPathOpen(ctx.io, "leftovers", .{ .open_options = .{ .iterate = true } });
    defer dir.close(ctx.io);
    for (0..row.n) |k| {
        var name: [27]u8 = undefined;
        name[0] = '.';
        for (name[1..], 0..) |*c, j| c.* = "abcdefgh"[(k >> @intCast((j % 8) * 3)) & 7];
        try dir.writeFile(ctx.io, .{ .sub_path = &name, .data = "" });
    }
    const removed = try airlock.pruneTemps(ctx.io, dir, ".", .{ .older_than = .fromNanoseconds(0) });
    std.debug.assert(removed == row.n);
}

fn abRelicFile(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    _ = i;
    try relic.syncFile(ctx.io, ctx.file);
}

fn abRelicAtomic(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    _ = i;
    try relic.atomicWrite(ctx.io, ctx.dir, "replaced", &ctx.page);
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

/// The copy/write-and-sync-each shape, cloning disabled: every file is
/// still dirty when its full sync runs, then the directory is synced.
fn abFlushEach(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = i;
    for (ctx.names[0..row.n]) |*name| {
        const f = try ctx.dir.createFile(ctx.io, name[0..7], .{});
        defer f.close(ctx.io);
        try f.writePositionalAll(ctx.io, &ctx.page, 0);
        _ = try airlock.syncFile(ctx.io, f, .{ .level = .full });
    }
    _ = try airlock.syncDir(ctx.io, ctx.dir, .{});
}

const Tally = struct { w: u32 = 0, b: u32 = 0, f: u32 = 0, raw_calls: u32 = 0 };

/// Count separately from the timer; fault instrumentation is never timed.
fn tallyRow(ctx: *Context, row: *const Row) !Tally {
    if (std.mem.indexOf(u8, row.name, "relic") != null or std.mem.eql(u8, row.name, "ab/append/flush-each")) return .{};
    const h = try seam.Seam.create(ctx.gpa, ctx.io, .{});
    defer h.destroy();
    var counted = ctx.*;
    counted.io = h.io();
    try row.op(&counted, row, row.ops);
    var tally: Tally = .{
        .w = h.count(.sync_writeout) + (if (builtin.os.tag.isDarwin()) h.count(.sync_plain) else 0),
        .b = h.count(.sync_barrier),
        .f = h.count(.sync_full) + h.count(.sync_dir) + h.count(.sync_data) + (if (builtin.os.tag.isDarwin()) 0 else h.count(.sync_plain)),
    };
    for (std.meta.tags(seam.Call)) |call| tally.raw_calls += h.count(call);
    return tally;
}

// Counts: the raw calls of one operation, through `airlock.testing`.

fn counts(ctx: *Context, stdout: *Io.Writer) !void {
    const cases = [_]Row{
        .{ .name = "counts/replace-ordered", .ops = 1, .op = replace, .level = .ordered, .overwrite = true },
        .{ .name = "counts/replace-data", .ops = 1, .op = replace, .level = .data, .overwrite = true },
        .{ .name = "counts/replace-data-no-barrier", .ops = 1, .op = countReplaceNoBarrier, .overwrite = true },
        .{ .name = "counts/batch-100-renames", .ops = 1, .op = batch, .n = 100 },
        .{ .name = "counts/batch-100-files", .ops = 1, .op = batch, .n = 100, .renames = false, .include_dir = true },
        .{ .name = "counts/batch-100-paths", .ops = 1, .op = batch, .n = 100, .renames = false, .paths = true },
        .{ .name = "counts/rename", .ops = 1, .op = renameRow },
        .{ .name = "counts/remove", .ops = 1, .op = removeRow },
        .{ .name = "counts/make-path-3", .ops = 1, .op = makePathRow },
        .{ .name = "counts/sym-link", .ops = 1, .op = symLinkRow },
        .{ .name = "counts/keep-existing", .ops = 1, .op = keepExistingRow },
    };
    for (cases) |row| {
        const counted_io = try seam.Seam.create(ctx.gpa, ctx.io, .{ .trace = .all });
        defer counted_io.destroy();
        var counted = ctx.*;
        counted.io = counted_io.io();
        try row.op(&counted, &row, 0);
        const w = counted_io.count(.sync_writeout) + counted_io.count(.sync_plain);
        const b = counted_io.count(.sync_barrier);
        const f = counted_io.count(.sync_full) + counted_io.count(.sync_dir) + counted_io.count(.sync_data);
        var total: u32 = 0;
        for (std.meta.tags(seam.Call)) |call| total += counted_io.count(call);
        try stdout.print("{{\"row\":\"{s}\",\"W\":{d},\"B\":{d},\"F\":{d},\"raw_calls\":{d}}}\n", .{ row.name, w, b, f, total });
        try stdout.flush();
    }
}

fn countReplaceNoBarrier(ctx: *Context, row: *const Row, i: u64) anyerror!void {
    _ = row;
    _ = i;
    _ = try airlock.writeFile(ctx.io, ctx.dir, "replaced", &ctx.page, .{ .commit = .{ .barrier = false } });
}
