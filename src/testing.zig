//! airlock's test seam, for airlock's tests and for the tests of the code
//! that calls it: the module `airlock.testing`, on shakedown.
//!
//! airlock's syncs, renames and identity calls are raw: they go past the
//! `Io` they are given, so a hand-written `Io` double never sees them. A
//! `Seam` is the `Io` that does. It is shakedown's `FaultIo` under a layer
//! that carries airlock's hook, so every raw call airlock makes is a step
//! of the `FaultIo`, beside std's own calls: traced, counted, failed by a
//! `Plan` of airlock calls, and reached by shakedown's `everyFault`.
//!
//!     const seam = try airlock.testing.Seam.create(gpa, io, .{
//!         .plan = &.{airlock.testing.fail(airlock.testing.data_sync, 2, airlock.testing.io_error)},
//!     });
//!     defer seam.destroy();
//!     try code.under(seam.io());
//!     try std.testing.expectEqual(1, seam.syncs());
//!
//! A project's build gets this module from `airlock`'s build.zig:
//! `@import("airlock").testing(airlock_dependency)`. Only a build that asks
//! for it fetches shakedown.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const shakedown = @import("shakedown");
const seam = @import("seam");
const assert = @import("aegis.assert");

const os = builtin.target.os.tag;

/// Every raw call airlock makes, one value each.
pub const Call = seam.Call;
/// An errno on POSIX, an NTSTATUS on Windows.
pub const Code = seam.Code;
/// What a plan makes of a call instead of the system.
pub const Result = seam.Result;
/// Faults by airlock call: the n-th `sync_data`, say.
pub const Plan = shakedown.Plan(Call, Result);

const Hooked = shakedown.Layer(seam.HookedState, .{ .fileSync = seam.hookedSync });

/// The platform's I/O error, as the code a raw call returns.
pub const io_error: Code = if (os == .windows) .IO_DEVICE_ERROR else .IO;

/// The code a filesystem that cannot be asked for a sync returns.
pub const refused: Code = if (os == .windows) .NOT_SUPPORTED else .INVAL;

/// The call a data-level `airlock.syncFile` makes first on this platform.
pub const data_sync: Call = if (os.isDarwin()) .sync_full else if (os == .linux or os == .windows) .sync_data else .sync_plain;

/// The plan entry that answers the `n`-th `call` with `code`.
pub fn fail(call: Call, n: u32, code: Code) Plan.Entry {
    return .{ .at = .{ .nth = .{ .call = call, .n = n } }, .fault = .{ .code = code } };
}

/// The plan entry that answers every `call` with `code`.
pub fn always(call: Call, code: Code) Plan.Entry {
    return .{ .at = .{ .nth = .{ .call = call, .n = 1 } }, .fault = .{ .code = code }, .times = 0 };
}

pub const Options = struct {
    /// Faults by airlock call. Borrowed for the seam's life; at most 16
    /// entries.
    plan: []const Plan.Entry = &.{},
    trace: shakedown.IoTrace.Mode = .all,
    /// The seed of `io.random`, so temp names repeat from run to run.
    seed: u64 = 1,
    /// Put shakedown's `Clock` under the `FaultIo`: time moves only when
    /// `drive` moves it.
    clock: bool = false,
    /// POSIX: count this process's open descriptors at every raw call and
    /// keep the most seen in `peak_descriptors`.
    sample_descriptors: bool = false,
};

/// One test's hooked `Io`. Must not move once `io` is called; `create`
/// and `over` allocate it.
pub const Seam = struct {
    gpa: std.mem.Allocator,
    fio: *shakedown.FaultIo,
    /// Whether `fio` is the seam's own (`everyFault` hands one in).
    owns_fio: bool,
    plan: Plan,
    counters: [16]u32 = undefined,
    fired: [32]Plan.Fired = undefined,
    /// Raw calls run on several tasks at once (a batch's concurrent
    /// syncs); the plan is decided under this.
    mutex: std.atomic.Mutex = .unlocked,
    hook: seam.Hook,
    hooked: Hooked,
    /// The clock under `fio`, with `Options.clock`.
    clock: ?*shakedown.Clock = null,
    /// With `Options.sample_descriptors`: the most descriptors open at any
    /// raw call since the last `reset`.
    peak_descriptors: ?usize = null,

    /// A seam over a `FaultIo` of its own, on `base`.
    pub fn create(gpa: std.mem.Allocator, base: Io, options: Options) !*Seam {
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
        const s = try over(gpa, fio, options);
        s.owns_fio = true;
        s.clock = clock;
        return s;
    }

    /// A seam over a `FaultIo` someone else owns, as an `everyFault`
    /// `setUp` gets one; its `io.random` is that `FaultIo`'s, and
    /// `Options.seed` and `Options.clock` are not read.
    pub fn over(gpa: std.mem.Allocator, fio: *shakedown.FaultIo, options: Options) !*Seam {
        const s = try gpa.create(Seam);
        s.* = .{
            .gpa = gpa,
            .fio = fio,
            .owns_fio = false,
            .plan = undefined,
            .hook = undefined,
            .hooked = undefined,
        };
        if (options.sample_descriptors) s.peak_descriptors = 0;
        s.setPlan(options.plan);
        s.hook = .{ .ctx = s, .call = decide, .base = fio.io() };
        s.hooked = .init(fio.io(), .{ .hook = &s.hook });
        return s;
    }

    pub fn destroy(s: *Seam) void {
        if (s.owns_fio) s.fio.deinit();
        if (s.clock) |c| s.gpa.destroy(c);
        s.gpa.destroy(s);
    }

    /// The `Io` to hand the code under test.
    pub fn io(s: *Seam) Io {
        return s.hooked.io();
    }

    /// Replaces the plan, its counts starting again: for faults planned
    /// once a fixture is set up. Not while calls are in flight.
    pub fn setPlan(s: *Seam, entries: []const Plan.Entry) void {
        assert.pre(entries.len <= s.counters.len, "Seam.setPlan: a plan holds at most 16 entries");
        s.plan = .init(entries, .{ .steps = s.fio.steps(), .counters = &s.counters, .fired = &s.fired });
    }

    /// Forgets the trace, the counts and the descriptor peak, keeping the
    /// plan, which starts again.
    pub fn reset(s: *Seam) void {
        s.fio.reset();
        s.plan.reset();
        if (s.peak_descriptors != null) s.peak_descriptors = 0;
    }

    /// How many times airlock made `call`.
    pub fn count(s: *Seam, call: Call) u32 {
        var n: u32 = 0;
        for (s.fio.trace().records()) |record| {
            const foreign = record.event.foreign orelse continue;
            if (foreign.call == @backingInt(call)) n += 1;
        }
        return n;
    }

    /// How many syncs airlock made, of a file or a directory: full,
    /// barrier, data, plain, writeout and directory syncs alike.
    pub fn syncs(s: *Seam) u32 {
        var n: u32 = 0;
        inline for (.{ .sync_full, .sync_barrier, .sync_data, .sync_plain, .sync_writeout, .sync_dir }) |call| n += s.count(call);
        return n;
    }

    /// airlock's calls in order, at most `out.len` of them.
    pub fn calls(s: *Seam, out: []Call) []Call {
        var n: usize = 0;
        for (s.fio.trace().records()) |record| {
            const foreign = record.event.foreign orelse continue;
            if (n == out.len) break;
            out[n] = @fromBackingInt(@as(u8, @intCast(foreign.call)));
            n += 1;
        }
        return out[0..n];
    }

    /// Runs `task.run()` on another task of `base`, moving the clock to
    /// each timer it arms until it returns, so a retry loop with a deadline
    /// runs to that deadline without waiting for it. Needs `Options.clock`.
    pub fn drive(s: *Seam, base: Io, task: anytype) !void {
        const clock = s.clock.?;
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
            clock.awaitArmed(1, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch |err| switch (err) {
                // Not sleeping now: running, or done.
                error.Timeout => continue,
                error.Canceled => return err,
            };
            _ = clock.advanceToNext();
        }
    }

    /// Each raw call is a foreign step of the `FaultIo`: a fault the
    /// `FaultIo`'s own plan puts there (an `everyFault` run) wins, and the
    /// seam's plan decides the rest.
    fn decide(ctx: *anyopaque, call: Call, path: ?[]const u8) ?Result {
        const s: *Seam = @ptrCast(@alignCast(ctx)); // safe: `over` makes the hook with its own seam as ctx
        if (s.peak_descriptors) |peak| s.peak_descriptors = @max(peak, openDescriptors());
        const begun = s.fio.beginForeign(Call, call, path);
        var result: ?Result = null;
        if (begun.fault) |fault| switch (fault) {
            .fail => |err| result = toResult(err),
            else => {},
        } else {
            while (!s.mutex.tryLock()) std.atomic.spinLoopHint();
            defer s.mutex.unlock();
            result = s.plan.decideAt(begun.step, call, path);
        }
        const outcome: shakedown.IoEvent.Outcome = if (result) |r| switch (r) {
            .code => |c| .{ .err = codeError(c) },
            .canceled => .{ .err = error.Canceled },
            .value => |v| .{ .ok = v },
        } else .{ .ok = 0 };
        s.fio.endForeign(begun, outcome);
        return result;
    }
};

/// How many descriptors this process has open (POSIX; 0 elsewhere).
pub fn openDescriptors() usize {
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

/// The error a fault names, as the code a raw call returns: `error.IO` is
/// `EIO`, `error.SHARING_VIOLATION` is that NTSTATUS, any other the
/// platform's I/O error. `error.Canceled` is a cancel landing on the call.
fn toResult(err: anyerror) Result {
    if (err == error.Canceled) return .canceled;
    @setEvalBranchQuota(100_000);
    if (std.meta.stringToEnum(Code, @errorName(err))) |code| return .{ .code = code };
    return .{ .code = io_error };
}

/// A code as the error name `toResult` reads back.
fn codeError(code: Code) anyerror {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(Code).@"enum".field_names) |name| {
        if (code == @field(Code, name)) return @field(anyerror, name);
    }
    return error.Unexpected;
}
