//! The hooked `Io` airlock's tests run on: shakedown's `FaultIo`, seeded so
//! temp names repeat from run to run (by its `random_seed`, or by `Seed`
//! over one a sweep made), under the layer whose `fileSync` is
//! `sys.hookedSync`. Every raw call airlock makes is a foreign step of the
//! `FaultIo`, so plans, traces and the single-fault sweep see airlock's
//! calls and std's in one sequence. A test of a retry deadline puts
//! shakedown's `Clock` under the `FaultIo` and runs the call through
//! `drive`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const shakedown = @import("shakedown");
const sys = @import("../sys.zig");

pub const Call = sys.Call;
pub const Result = sys.Result;
pub const Code = sys.Code;
pub const RawPlan = shakedown.Plan(Call, Result);

pub const Hooked = shakedown.Layer(sys.HookedState, .{ .fileSync = sys.hookedSync });

/// `io.random` from a generator seeded per run, for a `FaultIo` someone
/// else made: shakedown's single-fault sweep makes one per run without a
/// `random_seed`, and its determinism check needs every run to draw the
/// same temp names. A harness of the test's own seeds its `FaultIo`
/// instead.
pub const Seed = struct {
    prng: std.Random.DefaultPrng,

    fn random(userdata: ?*anyopaque, buffer: []u8) void {
        Seeded.of(userdata).state.prng.random().bytes(buffer);
    }
};
pub const Seeded = shakedown.Layer(Seed, .{ .random = Seed.random });

pub const Options = struct {
    /// Faults by airlock call: the n-th `sync_full`, say.
    plan: []const RawPlan.Entry = &.{},
    trace: shakedown.IoTrace.Mode = .all,
    seed: u64 = 1,
    /// Put shakedown's `Clock` under the `FaultIo`: time moves only when
    /// `drive` moves it.
    clock: bool = false,
    /// POSIX: count this process's open descriptors at every raw call and
    /// keep the most seen in `peak_descriptors`.
    sample_descriptors: bool = false,
};

/// One test's hooked `Io` over a `FaultIo`. Must not move after `io()`;
/// `create` allocates it.
pub const Harness = struct {
    gpa: std.mem.Allocator,
    fio: *shakedown.FaultIo,
    /// Whether `fio` is the harness's own (a sweep hands one in).
    owns_fio: bool,
    plan: RawPlan,
    counters: [16]u32 = undefined,
    fired: [32]RawPlan.Fired = undefined,
    mutex: std.atomic.Mutex = .unlocked,
    hook: sys.Hook,
    /// The seeded layer over a `FaultIo` someone else made (see `Seed`).
    seeded: ?Seeded = null,
    hooked: Hooked,
    /// The clock under `fio`, with `Options.clock`.
    clock: ?*shakedown.Clock = null,
    /// With `Options.sample_descriptors`: the most descriptors open at any
    /// raw call since the last `reset`.
    peak_descriptors: ?usize = null,

    pub fn create(gpa: std.mem.Allocator, base: Io, options: Options) !*Harness {
        var clock: ?*shakedown.Clock = null;
        var under = base;
        if (options.clock) {
            const c = try gpa.create(shakedown.Clock);
            c.* = .init(base, .{});
            clock = c;
            under = c.io();
        }
        errdefer if (clock) |c| gpa.destroy(c);
        const fio = try shakedown.FaultIo.init(gpa, under, .{ .trace = options.trace, .random_seed = options.seed });
        errdefer fio.deinit();
        const h = try build(gpa, fio, options);
        h.owns_fio = true;
        h.clock = clock;
        return h;
    }

    /// A harness over a `FaultIo` someone else owns, as a sweep's `setUp`
    /// gets one, its `io.random` seeded here.
    pub fn over(gpa: std.mem.Allocator, fio: *shakedown.FaultIo, options: Options) !*Harness {
        const h = try build(gpa, fio, options);
        h.seeded = .init(fio.io(), .{ .prng = .init(options.seed) });
        h.hooked = .init(h.seeded.?.io(), .{ .hook = &h.hook });
        return h;
    }

    fn build(gpa: std.mem.Allocator, fio: *shakedown.FaultIo, options: Options) !*Harness {
        const h = try gpa.create(Harness);
        h.* = .{
            .gpa = gpa,
            .fio = fio,
            .owns_fio = false,
            .plan = undefined,
            .hook = undefined,
            .hooked = undefined,
        };
        std.debug.assert(options.plan.len <= h.counters.len);
        if (options.sample_descriptors) h.peak_descriptors = 0;
        h.plan = .init(options.plan, .{ .steps = fio.steps(), .counters = &h.counters, .fired = &h.fired });
        h.hook = .{ .ctx = h, .call = decide, .base = fio.io() };
        h.hooked = .init(fio.io(), .{ .hook = &h.hook });
        return h;
    }

    pub fn destroy(h: *Harness) void {
        if (h.owns_fio) h.fio.deinit();
        if (h.clock) |c| h.gpa.destroy(c);
        h.gpa.destroy(h);
    }

    /// Runs `task.run()` on another task of `base`, moving the clock to
    /// each timer it arms until it returns, so a retry loop with a deadline
    /// runs to that deadline without waiting for it. Needs `Options.clock`.
    pub fn drive(h: *Harness, base: Io, task: anytype) !void {
        const clock = h.clock.?;
        const Task = @TypeOf(task.*);
        var done: std.atomic.Value(bool) = .init(false);
        const Wrapped = struct {
            fn go(t: *Task, finished: *std.atomic.Value(bool)) void {
                t.run();
                finished.store(true, .release);
            }
        };
        var future = try base.concurrent(Wrapped.go, .{ task, &done });
        defer future.await(base);
        while (!done.load(.acquire)) {
            clock.awaitArmed(1, .fromMilliseconds(5)) catch |err| switch (err) {
                // Not sleeping now: running, or done.
                error.Timeout => continue,
                error.Canceled => return err,
            };
            _ = clock.advanceToNext();
        }
    }

    /// The `Io` to hand airlock.
    pub fn io(h: *Harness) Io {
        return h.hooked.io();
    }

    fn decide(ctx: *anyopaque, call: Call, path: ?[]const u8) ?Result {
        const h: *Harness = @ptrCast(@alignCast(ctx)); // safe: the hook's ctx is its harness
        if (h.peak_descriptors) |peak| h.peak_descriptors = @max(peak, openDescriptors());
        const begun = h.fio.beginForeign(Call, call, path);
        var result: ?Result = null;
        if (begun.fault) |fault| switch (fault) {
            .fail => |err| result = toResult(err),
            else => {},
        } else {
            while (!h.mutex.tryLock()) std.atomic.spinLoopHint();
            defer h.mutex.unlock();
            result = h.plan.decideAt(begun.step, call, path);
        }
        const outcome: shakedown.IoEvent.Outcome = if (result) |r| switch (r) {
            .code => |c| .{ .err = codeError(c) },
            .canceled => .{ .err = error.Canceled },
            .value => |v| .{ .ok = v },
        } else .{ .ok = 0 };
        h.fio.endForeign(begun, outcome);
        return result;
    }

    /// How many times airlock made `call` in this harness's trace.
    pub fn count(h: *Harness, call: Call) u32 {
        var n: u32 = 0;
        for (h.fio.trace().records()) |r| {
            const f = r.event.foreign orelse continue;
            if (f.call == @backingInt(call)) n += 1;
        }
        return n;
    }

    /// airlock's calls in order, at most `out.len` of them.
    pub fn calls(h: *Harness, out: []Call) []Call {
        var n: usize = 0;
        for (h.fio.trace().records()) |r| {
            const f = r.event.foreign orelse continue;
            if (n == out.len) break;
            out[n] = @fromBackingInt(@as(u8, @intCast(f.call)));
            n += 1;
        }
        return out[0..n];
    }

    /// Drops the plan: every call from here on is real.
    pub fn clearPlan(h: *Harness) void {
        h.plan = .init(&.{}, .{ .steps = h.fio.steps(), .counters = &h.counters, .fired = &h.fired });
    }

    /// Forgets the trace, the counts and the descriptor peak, keeping the
    /// plan.
    pub fn reset(h: *Harness) void {
        h.fio.reset();
        h.plan.reset();
        if (h.peak_descriptors != null) h.peak_descriptors = 0;
    }
};

/// How many descriptors this process has open (POSIX; 0 elsewhere).
pub fn openDescriptors() usize {
    const os = builtin.target.os.tag;
    if (os == .windows) return 0;
    var n: usize = 0;
    var fd: i32 = 0;
    while (fd < 4096) : (fd += 1) {
        const open = if (os == .linux)
            std.os.linux.errno(std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0)) == .SUCCESS
        else
            std.c.fcntl(fd, std.c.F.GETFD) != -1;
        if (open) n += 1;
    }
    return n;
}

/// The error a fault names, as a code the hook returns: `error.IO` is
/// `EIO`, `error.SHARING_VIOLATION` is that NTSTATUS. `error.Canceled` is a
/// cancel landing on the call.
pub fn toResult(err: anyerror) Result {
    if (err == error.Canceled) return .canceled;
    @setEvalBranchQuota(100_000);
    if (std.meta.stringToEnum(Code, @errorName(err))) |code| return .{ .code = code };
    return .{ .code = if (builtin.target.os.tag == .windows) .IO_DEVICE_ERROR else .IO };
}

/// A code as the error name `toResult` reads back.
pub fn codeError(code: Code) anyerror {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(Code).@"enum".field_names) |name| {
        if (code == @field(Code, name)) return @field(anyerror, name);
    }
    return error.Unexpected;
}

/// The plan entry that fails the `n`-th `call` with `code`, `times` times.
pub fn fail(call: Call, n: u32, code: Code) RawPlan.Entry {
    return .{ .at = .{ .nth = .{ .call = call, .n = n } }, .fault = .{ .code = code } };
}

/// The plan entry that fails every `call` with `code`.
pub fn always(call: Call, code: Code) RawPlan.Entry {
    return .{ .at = .{ .nth = .{ .call = call, .n = 1 } }, .fault = .{ .code = code }, .times = 0 };
}

/// A scratch directory for one test, removed by `cleanup`.
pub const Scratch = struct {
    tmp: std.testing.TmpDir,

    pub fn init() Scratch {
        return .{ .tmp = std.testing.tmpDir(.{ .iterate = true }) };
    }

    pub fn dir(s: *Scratch) Io.Dir {
        return s.tmp.dir;
    }

    pub fn cleanup(s: *Scratch) void {
        s.tmp.cleanup();
    }

    /// The contents of `name`, or null if it does not exist.
    pub fn read(s: *Scratch, name: []const u8, buffer: []u8) ?[]const u8 {
        return s.tmp.dir.readFile(std.testing.io, name, buffer) catch null;
    }

    pub fn write(s: *Scratch, name: []const u8, bytes: []const u8) !void {
        try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    }

    /// How many entries the directory holds, and whether any starts with
    /// `prefix`.
    pub fn entries(s: *Scratch, prefix: []const u8) !struct { count: usize, prefixed: usize } {
        var it = s.tmp.dir.iterate();
        var count: usize = 0;
        var prefixed: usize = 0;
        while (try it.next(std.testing.io)) |e| {
            count += 1;
            if (std.mem.startsWith(u8, e.name, prefix)) prefixed += 1;
        }
        return .{ .count = count, .prefixed = prefixed };
    }
};

/// Asserts that airlock made exactly `expected`, in order.
pub fn expectCalls(h: *Harness, expected: []const Call) !void {
    var buffer: [64]Call = undefined;
    const got = h.calls(&buffer);
    std.testing.expectEqualSlices(Call, expected, got) catch |err| {
        std.debug.print("calls: {any}\n", .{got});
        return err;
    };
}
