//! The hooked `Io` airlock's tests run on: shakedown's `FaultIo` under a
//! seeded random layer, under the layer whose `fileSync` is
//! `sys.hookedSync`. Every raw call airlock makes is a foreign step of the
//! `FaultIo`, so plans, traces and the single-fault sweep see airlock's
//! calls and std's in one sequence.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const shakedown = @import("shakedown");
const sys = @import("../sys.zig");

pub const Call = sys.Call;
pub const Result = sys.Result;
pub const Code = sys.Code;
pub const RawPlan = shakedown.Plan(Call, Result);

/// `io.random` from a generator the test seeds, so temp names repeat from
/// run to run.
pub const Seed = struct {
    prng: std.Random.DefaultPrng,

    fn random(userdata: ?*anyopaque, buffer: []u8) void {
        const layer = Seeded.of(userdata);
        layer.state.prng.random().bytes(buffer);
    }
};
pub const Seeded = shakedown.Layer(Seed, .{ .random = Seed.random });

pub const Hooked = shakedown.Layer(sys.HookedState, .{ .fileSync = sys.hookedSync });

/// Time that moves only when the code under test sleeps: a sleep returns
/// at once and moves the clock by its length. For retry loops with a
/// deadline, which then run to their deadline without waiting.
pub const Time = struct {
    nanoseconds: i96 = std.time.ns_per_s,
    sleeps: u32 = 0,

    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        _ = clock;
        return .fromNanoseconds(Timed.of(userdata).state.nanoseconds);
    }

    fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const t = &Timed.of(userdata).state;
        t.sleeps += 1;
        switch (timeout) {
            .none => {},
            .duration => |d| t.nanoseconds += d.raw.nanoseconds,
            .deadline => |d| t.nanoseconds = @max(t.nanoseconds, d.raw.nanoseconds),
        }
    }
};
pub const Timed = shakedown.Layer(Time, .{ .now = Time.now, .sleep = Time.sleep });

pub const Options = struct {
    /// Faults by airlock call: the n-th `sync_full`, say.
    plan: []const RawPlan.Entry = &.{},
    trace: shakedown.IoTrace.Mode = .all,
    seed: u64 = 1,
    /// Run on `Time` under the `FaultIo`: sleeps return at once.
    timed: bool = false,
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
    seeded: Seeded,
    hooked: Hooked,
    /// The time layer under `fio`, with `Options.timed`.
    timed: ?*Timed = null,

    pub fn create(gpa: std.mem.Allocator, base: Io, options: Options) !*Harness {
        var timed: ?*Timed = null;
        var under = base;
        if (options.timed) {
            const t = try gpa.create(Timed);
            t.* = .init(base, .{});
            timed = t;
            under = t.io();
        }
        errdefer if (timed) |t| gpa.destroy(t);
        const fio = try shakedown.FaultIo.init(gpa, under, .{ .trace = options.trace });
        errdefer fio.deinit();
        const h = try over(gpa, fio, options);
        h.owns_fio = true;
        h.timed = timed;
        return h;
    }

    /// A harness over a `FaultIo` someone else owns, as a sweep's `setUp`
    /// gets one.
    pub fn over(gpa: std.mem.Allocator, fio: *shakedown.FaultIo, options: Options) !*Harness {
        const h = try gpa.create(Harness);
        h.* = .{
            .gpa = gpa,
            .fio = fio,
            .owns_fio = false,
            .plan = undefined,
            .hook = undefined,
            .seeded = .init(fio.io(), .{ .prng = .init(options.seed) }),
            .hooked = undefined,
        };
        std.debug.assert(options.plan.len <= h.counters.len);
        h.plan = .init(options.plan, .{ .steps = fio.steps(), .counters = &h.counters, .fired = &h.fired });
        h.hook = .{ .ctx = h, .call = decide, .base = fio.io() };
        h.hooked = .init(h.seeded.io(), .{ .hook = &h.hook });
        return h;
    }

    pub fn destroy(h: *Harness) void {
        if (h.owns_fio) h.fio.deinit();
        if (h.timed) |t| h.gpa.destroy(t);
        h.gpa.destroy(h);
    }

    /// The `Io` to hand airlock.
    pub fn io(h: *Harness) Io {
        return h.hooked.io();
    }

    fn decide(ctx: *anyopaque, call: Call, path: ?[]const u8) ?Result {
        const h: *Harness = @ptrCast(@alignCast(ctx)); // safe: the hook's ctx is its harness
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

    /// Forgets the trace and the counts, keeping the plan.
    pub fn reset(h: *Harness) void {
        h.fio.reset();
        h.plan.reset();
    }
};

/// The error a fault names, as a code the hook returns: `error.IO` is
/// `EIO`, `error.SHARING_VIOLATION` is that NTSTATUS. `error.Canceled` is a
/// cancel landing on the call.
pub fn toResult(err: anyerror) Result {
    if (err == error.Canceled) return .canceled;
    @setEvalBranchQuota(100_000);
    if (std.meta.stringToEnum(Code, @errorName(err))) |code| return .{ .code = code };
    return .{ .code = if (builtin.os.tag == .windows) .IO_DEVICE_ERROR else .IO };
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
