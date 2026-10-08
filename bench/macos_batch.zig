//! macOS write-all-then-sync strategies, with individual syscall timings.
//! CI only compiles: --smoke returns before touching a filesystem.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const airlock = @import("airlock");
const primitives = @import("primitives.zig");
const seam = @import("airlock.testing");

const Strategy = enum {
    writes,
    reopened_full,
    reopened_write_full,
    writeout_full_each,
    full_each,
    full_reverse,
    first_full_then_plain,
    barrier_each,
    writeout_then_full,
    full_parallel,
    writeout_parallel,
    batch,
    paths,
    pending,
};
const Job = struct {
    io: Io,
    file: Io.File,
    kind: primitives.Kind,
    ns: u64 = 0,
    err: ?anyerror = null,

    fn run(job: *Job) void {
        const start = Io.Timestamp.now(job.io, .awake);
        primitives.sync(job.file.handle, job.kind) catch |err| {
            job.err = err;
        };
        job.ns = elapsed(job.io, start);
    }
};
const Config = struct {
    target: []const u8 = "scratch",
    other_target: ?[]const u8 = null,
    filter: []const u8 = "",
    rounds: usize = 9,
    n: usize = 100,
    size: usize = 4096,
    parallel: u8 = 16,
    audit: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config: Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--smoke")) return;
        if (std.mem.eql(u8, args[i], "--audit")) {
            config.audit = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgument;
        const option = args[i];
        i += 1;
        if (std.mem.eql(u8, option, "--dir")) config.target = args[i] else if (std.mem.eql(u8, option, "--other-dir")) config.other_target = args[i] else if (std.mem.eql(u8, option, "--filter")) config.filter = args[i] else if (std.mem.eql(u8, option, "--rounds")) config.rounds = try std.fmt.parseInt(usize, args[i], 10) else if (std.mem.eql(u8, option, "--n")) config.n = try std.fmt.parseInt(usize, args[i], 10) else if (std.mem.eql(u8, option, "--parallel")) config.parallel = try std.fmt.parseInt(u8, args[i], 10) else if (std.mem.eql(u8, option, "--size")) config.size = try std.fmt.parseInt(usize, args[i], 10) else return error.UnknownArgument;
    }
    if (!builtin.os.tag.isDarwin()) return;
    if (config.n == 0 or config.rounds == 0 or config.parallel == 0) return error.EmptyWorkload;
    const io = init.io;
    const a = init.gpa;
    var parent = try Io.Dir.cwd().createDirPathOpen(io, config.target, .{});
    defer parent.close(io);
    var random: [16]u8 = undefined;
    io.random(&random);
    var name_buffer: [64]u8 = undefined;
    const name = try std.mem.print(&name_buffer, "airlock-strategies-{x}", .{&random});
    try parent.createDir(io, name, .default_dir);
    defer parent.deleteTree(io, name) catch {};
    var root = try parent.openDir(io, name, .{});
    defer root.close(io);
    const other_parent: ?Io.Dir = if (config.other_target) |target| try Io.Dir.cwd().createDirPathOpen(io, target, .{}) else null;
    defer if (other_parent) |dir| dir.close(io);
    if (other_parent) |dir| try dir.createDir(io, name, .default_dir);
    defer if (other_parent) |dir| dir.deleteTree(io, name) catch {};
    const other_root: ?Io.Dir = if (other_parent) |dir| try dir.openDir(io, name, .{}) else null;
    defer if (other_root) |dir| dir.close(io);
    var output_buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writer(io, &output_buffer);
    const strategies = std.meta.tags(Strategy);
    for (0..config.rounds) |round| {
        for (0..strategies.len) |offset| {
            const strategy = strategies[(offset + round) % strategies.len];
            if (other_root != null and strategy != .batch and strategy != .pending and strategy != .paths) continue;
            if (config.filter.len > 0 and !std.mem.eql(u8, config.filter, @tagName(strategy))) continue;
            try root.createDir(io, "row", .default_dir);
            var dir = try root.openDir(io, "row", .{});
            if (other_root) |other| try other.createDir(io, "row", .default_dir);
            const other_dir: ?Io.Dir = if (other_root) |other| try other.openDir(io, "row", .{}) else null;
            {
                defer dir.close(io);
                defer if (other_dir) |other| other.close(io);
                // Flush setup outside all timers; measurements begin with a clean device queue.
                try primitives.sync(dir.handle, .full);
                if (other_dir) |other| {
                    const one = try airlock.FileId.of(io, .{ .handle = dir.handle, .flags = .{ .nonblocking = false } });
                    const two = try airlock.FileId.of(io, .{ .handle = other.handle, .flags = .{ .nonblocking = false } });
                    if (one.volume == two.volume) return error.SameVolume;
                    try primitives.sync(other.handle, .full);
                }
                if (config.audit and strategy == .batch and other_dir != null) {
                    const h = try seam.Seam.create(a, io, .{ .trace = .all });
                    defer h.destroy();
                    try measure(a, h.io(), dir, other_dir, strategy, config, round, &output.interface);

                    try output.interface.print("{{\"row\":\"audit/two-volumes\",\"W\":{d},\"F\":{d}}}\n", .{ h.count(.sync_writeout), h.count(.sync_full) });
                    try output.interface.flush();
                    if (h.count(.sync_full) != 2 or h.count(.sync_writeout) != config.n + 2) return error.BadVolumeCounts;
                } else try measure(a, io, dir, other_dir, strategy, config, round, &output.interface);
            }
            try root.deleteTree(io, "row");
            if (other_root) |other| try other.deleteTree(io, "row");
        }
    }
}

fn elapsed(io: Io, start: Io.Timestamp) u64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds);
}

fn measure(a: std.mem.Allocator, io: Io, dir: Io.Dir, other: ?Io.Dir, strategy: Strategy, config: Config, round: usize, out: *Io.Writer) !void {
    const files = try a.alloc(Io.File, config.n);
    defer a.free(files);
    const ps = try a.alloc(airlock.Pending, config.n);
    defer a.free(ps);
    const slots = try a.alloc(airlock.Batch.Slot, config.n + 2);
    defer a.free(slots);
    const jobs = try a.alloc(Job, config.n);
    defer a.free(jobs);
    const data = try a.alloc(u8, config.size);
    defer a.free(data);
    @memset(data, 0x5a);
    const names = try a.alloc([24]u8, config.n);
    defer a.free(names);
    var batch: airlock.Batch = .init(slots);
    defer batch.reset(io);
    var made: usize = 0;
    defer for (0..made) |j| {
        if (strategy == .pending) ps[j].discard(io) else files[j].close(io);
    };
    const start = Io.Timestamp.now(io, .awake);
    for (files, names, 0..) |*file, *buf, j| {
        const name = try std.mem.print(buf, "f{d:0>8}", .{j});
        const target_dir = if (other != null and j % 2 == 1) other.? else dir;
        if (strategy == .pending) {
            ps[j] = try airlock.create(io, target_dir, name, .{});
            made += 1;
            try ps[j].file().writePositionalAll(io, data, 0);
            try batch.addPending(io, &ps[j], .replace);
        } else {
            file.* = try target_dir.createFile(io, name, .{});
            made += 1;
            try file.writePositionalAll(io, data, 0);
        }
    }
    const write_ns = elapsed(io, start);
    const sync_start = Io.Timestamp.now(io, .awake);
    var volume: ?u64 = null;
    // Every contract baseline identifies each writing handle's volume.
    if (strategy != .batch and strategy != .paths and strategy != .pending and strategy != .writes) for (files, 0..) |file, j| {
        const id = try airlock.FileId.of(io, if (strategy == .pending) ps[j].file() else file);
        if (volume) |v| {
            if (v != id.volume) return error.MixedVolume;
        } else volume = id.volume;
    };
    if (strategy == .reopened_full or strategy == .reopened_write_full) {
        for (files) |file| file.close(io);
        made = 0;
    }
    var dir_ns: u64 = 0;
    if (strategy == .batch or strategy == .paths or strategy == .pending) {
        if (strategy != .pending) for (files, names, 0..) |file, *buf, j| {
            if (strategy == .batch) try batch.addFile(file) else try batch.addPath(if (other != null and j % 2 == 1) other.? else dir, buf[0..9]);
        };
        try batch.addDir(dir);
        if (other) |d| try batch.addDir(d);
        if (try batch.commit(io, .{ .level = .full, .parallel = config.parallel }) != .full) return error.NotDurable;
        @memset(jobs, .{ .io = io, .file = undefined, .kind = .full });
    } else {
        if (strategy == .writeout_full_each) for (files) |file| try primitives.sync(file.handle, .fsync);
        var group: Io.Group = .init;
        for (0..config.n) |j| {
            const k = if (strategy == .full_reverse) config.n - j - 1 else j;
            const kind: primitives.Kind = switch (strategy) {
                .writeout_then_full, .writeout_parallel => .fsync,
                .first_full_then_plain => if (j == 0) .full else .fsync,
                .barrier_each => .barrier,
                else => .full,
            };
            jobs[j] = .{ .io = io, .file = files[k], .kind = kind };
            if (strategy == .writes) continue;
            if (strategy == .reopened_full or strategy == .reopened_write_full) {
                // Reference only: opening afresh loses the writing-handle error guarantee.
                const fresh = try dir.openFile(io, names[k][0..9], .{ .mode = if (strategy == .reopened_write_full) .read_write else .read_only });
                jobs[j].file = fresh;
                Job.run(&jobs[j]);
                fresh.close(io);
            } else if (strategy == .full_parallel or strategy == .writeout_parallel) {
                group.concurrent(io, Job.run, .{&jobs[j]}) catch Job.run(&jobs[j]);
                if ((j + 1) % config.parallel == 0) try group.await(io);
            } else Job.run(&jobs[j]);
        }
        try group.await(io);
        for (jobs) |job| if (job.err) |err| return err;
        if (strategy != .writes) {
            const dstart = Io.Timestamp.now(io, .awake);
            try primitives.sync(dir.handle, .full);
            dir_ns = elapsed(io, dstart);
        }
    }
    const sync_ns = elapsed(io, sync_start);
    const close_start = Io.Timestamp.now(io, .awake);
    for (0..made) |j| {
        if (strategy == .pending) ps[j].discard(io) else files[j].close(io);
    }
    made = 0;
    const close_ns = elapsed(io, close_start);
    try out.print("{{\"row\":\"macos-strategy/{s}\",\"round\":{d},\"n\":{d},\"size\":{d},\"parallel\":{d},\"volumes\":{d},\"write_ns\":{d},\"sync_ns\":{d},\"close_ns\":{d},\"total_ns\":{d},\"directory_ns\":{d},\"calls_ns\":[", .{ @tagName(strategy), round, config.n, config.size, config.parallel, @as(u8, if (other == null) 1 else 2), write_ns, sync_ns, close_ns, write_ns + sync_ns + close_ns, dir_ns });
    for (jobs, 0..) |job, j| try out.print("{s}{d}", .{ if (j == 0) "" else ",", job.ns });
    try out.writeAll("]}\n");
    try out.flush();
}
