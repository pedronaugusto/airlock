//! git's lock-file protocol (`lockfile.c`) on `Temp.suffix`: `<path>.lock`,
//! created exclusively and waited for with git's backoff, optionally named by
//! a holder file (`core.lockfilePid`'s `<path>~pid.lock`), and ended by a
//! commit that replaces `<path>` with what was written to the lock, or by a
//! release that leaves `<path>` as it was. A lock this process did not take
//! is never removed: `heldBy` says what it names, and whether that holder
//! still runs is the caller's to ask (pids are reused, and a lock on a
//! network filesystem may be another host's).
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const Io = std.Io;
const Pending = @import("Pending.zig");
const Staged = @import("Staged.zig");
const sys = @import("sys.zig");

const Lock = @This();

/// The lock file, which is also the new contents of `<path>`.
pending: Pending,

/// What a lock does when it is taken.
pub const Contention = union(enum) {
    /// `error.LockHeld` at once.
    fail,
    /// Try again with git's backoff (`lock_file_timeout`): the attempt
    /// number squared in milliseconds, capped at a thousand, each wait a
    /// quarter either way at random, for up to this long in all, counted in
    /// whole milliseconds as git counts it. Each wait is a cancellation
    /// point.
    wait: Io.Duration,
};

/// Whether a lock names the process holding it.
pub const Holder = enum {
    /// No holder file; one a crash left is removed.
    none,
    /// git's `core.lockfilePid`: `<path>~pid.lock` says `pid <n>` while the
    /// lock is held, byte for byte as git writes it, and goes with the lock.
    pid_file,
};

pub const Options = struct {
    contention: Contention = .fail,
    holder: Holder = .none,
    /// The lock's permissions, and so the new file's.
    mode: Pending.Mode = .default,
    /// Open the lock for reading as well.
    read: bool = false,
};

/// Taking a lock failed.
pub const Error = Pending.CreateError || Io.Cancelable || HolderError || error{
    /// `<path>~pid.lock` would be longer than a name may be.
    NameTooLong,
    /// `<path>.lock` is there: another writer holds it. It is never removed
    /// here; `heldBy` says what it names.
    LockHeld,
};

/// Writing or removing the holder file failed; the lock was given up.
pub const HolderError = Io.File.OpenError || Io.File.WritePositionalError || Io.Dir.DeleteFileError;

/// Takes `<path>.lock` in `dir`. `path` is borrowed until the lock ends.
pub fn take(io: Io, dir: Io.Dir, path: []const u8, options: Options) Error!Lock {
    var lock: Lock = .{ .pending = try create(io, dir, path, options) };
    errdefer lock.pending.discard(io);
    try lock.mark(io, options.holder);
    return lock;
}

/// The lock, written to while it is held, as `Pending.file` says.
pub fn file(l: *Lock) Io.File {
    return l.pending.file();
}

/// A writer over the lock, as `Pending.writer` says.
pub fn writer(l: *Lock, io: Io, buffer: []u8) *Io.Writer {
    return l.pending.writer(io, buffer);
}

/// Replaces `<path>` with what was written to the lock, at `options.level`,
/// as `Pending.commit` does: git's `commit_lock_file`. The lock ends.
pub fn commit(l: *Lock, io: Io, options: Pending.CommitOptions) Pending.CommitError!Pending.Committed {
    // While the lock still holds the directory open: the commit closes it.
    l.unmark(io);
    return l.pending.commit(io, options);
}

/// Gives the lock up, `<path>` as it was: git's `rollback_lock_file`. Safe
/// after `commit`, so `defer lock.release(io)` is the shape.
pub fn release(l: *Lock, io: Io) void {
    const held = switch (l.pending.state()) {
        .open, .synced, .poisoned => true,
        .published, .kept, .discarded => false,
    };
    if (held) l.unmark(io);
    l.pending.discard(io);
}

const Span = aegis.units.Duration(.nanosecond, i96);

fn create(io: Io, dir: Io.Dir, path: []const u8, options: Options) Error!Pending {
    const deadline: Span = switch (options.contention) {
        .fail => .fromRaw(0),
        .wait => |d| .fromIoDuration(d, .exact),
    };
    var waited: Span = .fromRaw(0);
    var attempt: u32 = 0;
    while (true) {
        if (Pending.create(io, dir, path, .{ .temp = .{ .suffix = ".lock" }, .mode = options.mode, .read = options.read })) |pending| {
            return pending;
        } else |err| switch (err) {
            // Windows keeps the name of a deleted file while another process
            // holds it open: a lock as good as held.
            error.PathAlreadyExists, error.Busy => {},
            // Windows reports a scanner holding the file between a write and
            // a rename as access denied: tried again, as git's own Windows
            // port does. Elsewhere it is final.
            error.AccessDenied, error.PermissionDenied => if (builtin.target.os.tag != .windows) return err,
            else => |e| return e,
        }
        if (waited.compare(deadline) != .lt) return error.LockHeld;
        var jitter: [2]u8 = undefined;
        io.random(&jitter);
        const delay = backoff(attempt, std.mem.readInt(u16, &jitter, .little));
        try Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(@intCast(delay)), .clock = .awake } }, io); // safe: a backoff is at most 1249 ms
        const step = aegis.units.Duration(.millisecond, i64).fromRaw(@intCast(delay)).convert(.nanosecond, i96, .exact); // safe: a backoff is at most 1249 ms
        waited = waited.add(step) catch return error.LockHeld;
        attempt +|= 1;
    }
}

/// git's backoff, from `lock_file_timeout`: the attempt number squared, in
/// milliseconds, capped at a thousand, and each wait between three quarters
/// and five quarters of that, so that two waiters do not retry in step.
/// `random` picks where.
pub fn backoff(attempt: u32, random: u16) u64 {
    // Past 32 the square is past the cap: held there, it cannot overflow.
    const n: u64 = @min(@as(u64, attempt) + 1, 32);
    const multiplier: u64 = @min(n * n, 1000);
    const spread: u64 = 750 + @as(u64, random % 500);
    return @max(1, spread * multiplier / 1000);
}

/// The holder file's name, `<base>~pid.lock`, in `out`.
fn holderName(base: []const u8, out: []u8) error{NameTooLong}![]const u8 {
    const suffix = "~pid.lock";
    if (suffix.len > out.len - base.len) return error.NameTooLong;
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..][0..suffix.len], suffix);
    return out[0 .. base.len + suffix.len];
}

/// Writes the holder file, or removes one a crash left: while this lock is
/// held, any holder file beside it is this lock's to keep or drop.
fn mark(l: *Lock, io: Io, holder: Holder) (HolderError || error{NameTooLong})!void {
    const staged = &l.pending.staged;
    // Named from the caller's directory by the destination's path, beside it as in its
    // parent: the parent the pending owns is lent only once `take` has returned the lock,
    // whose owners bind their address at their first use.
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const name = try holderName(staged.dest, &buffer);
    switch (holder) {
        .none => staged.root.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        },
        .pid_file => {
            const f = try staged.root.createFile(io, name, .{ .truncate = true });
            defer f.close(io);
            var text: [32]u8 = undefined;
            const line = std.mem.print(&text, "pid {d}\n", .{sys.processId()}) catch unreachable; // safe: "pid " and ten digits fit
            try f.writePositionalAll(io, line, 0);
        },
    }
}

/// Removes the holder file as the lock ends, before the lock goes. One left
/// behind is harmless:
/// `heldBy` reads it only while `<path>.lock` is there, and the next lock
/// writes or removes it.
fn unmark(l: *Lock, io: Io) void {
    const staged = &l.pending.staged;
    var buffer: [Staged.max_temp_name]u8 = undefined;
    const name = holderName(staged.baseName(), &buffer) catch return;
    // glint-ignore: Z026 -- a holder file left behind is read only beside a held lock, and the next lock writes or removes it
    staged.parentDir().deleteFile(io, name) catch {};
}

/// What a held lock says of its holder.
pub const Held = struct {
    /// The process id its holder file names; null when it has none, or one
    /// that does not read as git's `pid <n>`.
    pid: ?u32,
};

/// The holder of `<path>.lock` in `dir`, or null when the lock is not held.
/// git's `read_lock_pid`: `<path>~pid.lock`, at most 32 bytes, `pid <n>`.
pub fn heldBy(io: Io, dir: Io.Dir, path: []const u8) (Io.Dir.AccessError || error{NameTooLong})!?Held {
    var lock_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_name = std.mem.print(&lock_buffer, "{s}.lock", .{path}) catch return error.NameTooLong;
    dir.access(io, lock_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    var pid_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const pid_name = std.mem.print(&pid_buffer, "{s}~pid.lock", .{path}) catch return error.NameTooLong;
    var contents: [32]u8 = undefined;
    const text = dir.readFile(io, pid_name, &contents) catch return .{ .pid = null };
    const read = aegis.input.Untrusted([]const u8).init(text).parse({}, parsePid) catch return .{ .pid = null };
    return .{ .pid = read.pid };
}

const Pid = struct { pid: u32 };

fn parsePid(_: void, text: []const u8) error{NotAPid}!Pid {
    const line = std.mem.trimEnd(u8, text, " \t\n\r");
    if (!std.mem.startsWith(u8, line, "pid ")) return error.NotAPid;
    const pid = std.fmt.parseInt(u32, line[4..], 10) catch return error.NotAPid;
    if (pid == 0) return error.NotAPid;
    return .{ .pid = pid };
}
