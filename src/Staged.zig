//! The state behind a `Pending`: a temp file in its destination's
//! directory, and every step from its create to its publish. `Pending` is
//! the public face of it; `Batch` drives the same steps for many at once.
//! airlock's root does not export this type, so the steps a batch takes
//! one by one (a sync recorded, a parent swapped, a rename alone) are not
//! a caller's to take.
const Blocking = @import("Blocking.zig");
const std = @import("std");
const assert = @import("aegis.assert");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("sys.zig");
const platform = @import("platform.zig");
const level_mod = @import("level.zig");
const Level = level_mod.Level;
const Reached = level_mod.Reached;
const Fallback = level_mod.Fallback;

const Staged = @This();

const native_os = builtin.target.os.tag;
const is_windows = native_os == .windows;
const is_darwin = native_os.isDarwin();

/// The temp file.
file: Io.File,
/// The error behind `error.PublishedNotDurable` or a poisoned state.
cause: ?anyerror = null,
/// The directory the destination is in, held from create to the end. Not
/// valid after a batch took it and closed it.
parent: Io.Dir,
/// Whether airlock opened `parent` and closes it.
owns_parent: bool,
/// Whether `parent` is open.
parent_open: bool,
/// The directory the caller named the destination relative to.
root: Io.Dir,
/// The destination as the caller named it, borrowed.
dest: []const u8,
/// Where the base name starts in `dest`.
base_start: usize,
/// A random temp name, inline.
temp_buffer: [64]u8,
/// The temp name's length in `temp_buffer`; 0 for an exact name.
temp_len: u8,
/// An exact temp name, borrowed.
exact: []const u8,
/// Where the temp is (see `State`).
state: State = .open,
/// Whether `file`'s handle is open.
file_open: bool = true,
/// What the temp's sync reached, for a retried commit too.
file_reached: Reached = .none,
/// The writer `writer` hands out, and whether it is in use.
writer_state: Writer = undefined,
writer_active: bool = false,

pub const State = enum {
    /// Created, written to, not yet synced.
    open,
    /// Synced, not yet renamed: a commit that failed at the rename may be
    /// retried.
    synced,
    /// The name is visible.
    published,
    /// `keep_existing` found the name taken and left it alone.
    kept,
    /// A sync or a write failed: the contents are unknown, the temp is
    /// gone, and only `discard` is valid.
    poisoned,
    /// Nothing is left: discarded, or a create that found the name taken.
    discarded,

    /// Whether a staged file may go from `from` to `to`. A pending never goes
    /// back, only a synced temp is renamed, and `discard` follows any state.
    fn moves(from: State, to: State) bool {
        return switch (to) {
            .open => false,
            .synced => from == .open,
            .published, .kept => from == .synced,
            .poisoned => from == .open or from == .synced,
            .discarded => true,
        };
    }
};

/// Moves the staged file to `to`. A move `State.moves` does not allow is a
/// bug in airlock, not in a caller, so it stops in every build.
fn moveTo(p: *Staged, to: State) void {
    assert.invariant(p.state.moves(to), "Staged: illegal state move");
    p.state = to;
}

/// The name of the temp file in the destination's directory.
pub const Temp = union(enum) {
    /// A prefix (at most 32 bytes, no separator) followed by 26 lowercase
    /// base32 characters (128 bits from `io.random`). Lowercase base32 is
    /// safe on case-insensitive filesystems. A leading `.` hides it.
    /// `pruneTemps` removes old ones a crash left behind.
    random: []const u8,
    /// This exact base name in the destination's directory, such as a git
    /// lock file ("main.lock" for "refs/heads/main"). Taken means
    /// `error.PathAlreadyExists`. Borrowed until commit or discard.
    exact: []const u8,
};

pub const Mode = union(enum) {
    /// The destination's current permissions, or the platform default for
    /// a new file (umask applies) if it does not exist. A replace never
    /// widens who can read the file.
    inherit,
    /// The platform default for a new file; umask applies.
    default,
    /// Set on the open handle right after the create; umask does not apply.
    exact: Io.File.Permissions,
};

pub const CreateOptions = struct {
    temp: Temp = .{ .random = "." },
    mode: Mode = .inherit,
    /// Open the temp for reading as well.
    read: bool = false,
    /// Linux only: start writeback (`sync_file_range`) every this many
    /// bytes written through `writer`, so the final sync has little left to
    /// do. 0 = off.
    writeback_bytes: u32 = 0,
};

pub const CreateError = Io.File.OpenError || Io.File.SetPermissionsError || Io.Dir.StatFileError || error{
    /// Windows: the exact name lingers while another process holds the
    /// file it named, deleted.
    Busy,
};

/// How many random names a create draws before it believes the filesystem
/// is lying about `O_EXCL`.
const max_draws = 4;

/// Creates the temp for `dest_sub_path`, relative to `dir`, as
/// `Pending.create` documents.
pub fn create(io: Io, dir: Io.Dir, dest_sub_path: []const u8, options: CreateOptions) CreateError!Staged {
    const base_start = baseStart(dest_sub_path);
    const base = dest_sub_path[base_start..];
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.BadPathName;
    var p: Staged = .{
        .file = undefined,
        .parent = dir,
        .owns_parent = false,
        .parent_open = true,
        .root = dir,
        .dest = dest_sub_path,
        .base_start = base_start,
        .temp_buffer = undefined,
        .temp_len = 0,
        .exact = &.{},
        .writer_state = undefined,
    };
    if (base_start != 0) {
        p.parent = .{ .handle = try sys.openDir(io, dir.handle, parentPath(dest_sub_path, base_start)) };
        p.owns_parent = true;
    }
    errdefer if (p.owns_parent) sys.release(io, p.parent.handle);
    const create_mode: Io.File.Permissions = switch (options.mode) {
        .exact => |perm| perm,
        else => .default_file,
    };
    p.file = .{ .handle = try p.createTemp(io, options, create_mode), .flags = .{ .nonblocking = false } };
    errdefer p.removeTemp(io);
    try p.applyMode(io, options.mode);
    p.writer_state = .{ .interface = undefined, .io = io, .threshold = options.writeback_bytes };
    return p;
}

/// Where the base name of `path` starts: after its last separator.
pub fn baseStart(path: []const u8) usize {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or (is_windows and c == '\\')) return i;
    }
    return 0;
}

/// The directory part of `path`, given where its base starts: "/" for a
/// name at the root.
pub fn parentPath(path: []const u8, base_start: usize) []const u8 {
    return if (base_start == 1) path[0..1] else path[0 .. base_start - 1];
}

fn createTemp(p: *Staged, io: Io, options: CreateOptions, mode: Io.File.Permissions) CreateError!sys.Handle {
    switch (options.temp) {
        .exact => |name| {
            if (name.len == 0 or baseStart(name) != 0) return error.BadPathName;
            p.exact = name;
            return sys.createTemp(io, p.parent.handle, name, mode, options.read);
        },
        .random => |prefix| {
            if (prefix.len > max_prefix or baseStart(prefix) != 0) return error.BadPathName;
            var draws: u32 = 0;
            while (true) {
                p.temp_len = drawName(io, prefix, &p.temp_buffer);
                return sys.createTemp(io, p.parent.handle, p.tempName(), mode, options.read) catch |err| switch (err) {
                    error.PathAlreadyExists, error.Busy => {
                        draws += 1;
                        if (draws < max_draws) continue;
                        return err;
                    },
                    else => |e| return e,
                };
            }
        },
    }
}

/// The longest prefix a random temp name takes.
pub const max_prefix = 32;
/// How many base32 characters follow the prefix.
pub const random_len = 26;

/// Writes the prefix, then 26 lowercase base32 characters of 128 random
/// bits, into `out`, and returns the name's length.
pub fn drawName(io: Io, prefix: []const u8, out: *[64]u8) u8 {
    assert.pre(prefix.len <= max_prefix, "drawName: the prefix is longer than max_prefix");
    var random: [16]u8 = undefined;
    io.random(&random);
    @memcpy(out[0..prefix.len], prefix);
    encodeBase32(&random, out[prefix.len..][0..random_len]);
    return @intCast(prefix.len + random_len); // safe: the contract above bounds the prefix, so the name is at most 58 bytes
}

const base32 = "abcdefghijklmnopqrstuvwxyz234567";

fn encodeBase32(bytes: *const [16]u8, out: *[random_len]u8) void {
    var bits = std.mem.readInt(u128, bytes, .big);
    var i: usize = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = base32[@as(u5, @truncate(bits))];
        bits >>= 5;
    }
}

/// Whether `name` is `prefix` followed by exactly the characters
/// `drawName` writes: a name only a random temp can have.
pub fn isRandomName(name: []const u8, prefix: []const u8) bool {
    if (name.len != prefix.len + random_len or !std.mem.startsWith(u8, name, prefix)) return false;
    // The first character carries 3 of the 128 bits: 'a' to 'h'.
    const first = name[prefix.len];
    if (first < 'a' or first > 'h') return false;
    for (name[prefix.len + 1 ..]) |c| {
        if (std.mem.findScalar(u8, base32, c) == null) return false;
    }
    return true;
}

fn applyMode(p: *Staged, io: Io, mode: Mode) CreateError!void {
    switch (mode) {
        .default => {},
        .exact => |perm| try sys.setMode(io, p.file.handle, perm),
        .inherit => {
            const stat = p.parent.statFile(io, p.baseName(), .{}) catch |err| switch (err) {
                error.FileNotFound => return,
                else => |e| return e,
            };
            try sys.setMode(io, p.file.handle, stat.permissions);
        },
    }
}

/// The temp's name in the destination's directory.
pub fn tempName(p: *const Staged) []const u8 {
    if (p.temp_len == 0) return p.exact;
    return p.temp_buffer[0..p.temp_len];
}

/// The destination's base name.
pub fn baseName(p: *const Staged) []const u8 {
    return p.dest[p.base_start..];
}

/// The destination's directory relative to the caller's `dir`, or null
/// for a destination directly in it.
pub fn parentSubPath(p: *const Staged) ?[]const u8 {
    if (p.base_start == 0) return null;
    return parentPath(p.dest, p.base_start);
}

// ---------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------

/// The writer `writer` hands out. Its `interface` is an `Io.Writer`;
/// `commit` flushes it.
pub const Writer = struct {
    interface: Io.Writer,
    /// The `Io` the writes go through (a writer adapter keeps it).
    io: Io,
    /// `CreateOptions.writeback_bytes`.
    threshold: u32,
    /// Bytes written since the last writeback.
    since: u64 = 0,
    /// Bytes written in all.
    offset: u64 = 0,
    /// The error behind the last `error.WriteFailed`.
    err: ?anyerror = null,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    fn staged(w: *Writer) *Staged {
        return @alignCast(@fieldParentPtr("writer_state", w)); // safe: every Writer lives in a Staged
    }

    /// One vectored write of what is buffered and the slices in `data`; a
    /// pattern repeated `splat` times is copied into the buffer instead,
    /// so a long run costs a buffer's worth per write.
    fn drain(iw: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", iw)); // safe: this vtable is only installed on a Writer
        const pattern = data[data.len - 1];
        if (splat <= 1 or pattern.len == 0 or pattern.len > iw.buffer.len) {
            return iw.consume(try w.write(iw.buffered(), data, splat));
        }
        if (iw.end != 0 or data.len > 1) {
            // What comes before the pattern goes first.
            return iw.consume(try w.write(iw.buffered(), data[0 .. data.len - 1], 1));
        }
        const copies = @min(splat, iw.buffer.len / pattern.len);
        for (0..copies) |i| @memcpy(iw.buffer[i * pattern.len ..][0..pattern.len], pattern);
        iw.end = copies * pattern.len;
        return iw.end;
    }

    fn write(w: *Writer, header: []const u8, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const p = w.staged();
        const vector: []const []const u8 = if (data.len == 0) &.{""} else data;
        const n = p.file.writeStreaming(w.io, header, vector, splat) catch |err| {
            // What reached the file is unknown: a failed write poisons the
            // commit as a failed sync does.
            w.err = err;
            p.cause = err;
            return error.WriteFailed;
        };
        w.offset += n;
        w.since += n;
        if (w.threshold == 0 or w.since < w.threshold) return n;
        sys.writeback(w.io, p.file.handle, w.offset - w.since, w.since) catch |err| {
            // A writeback error is a failed sync: the commit poisons.
            w.err = err;
            p.cause = err;
            return error.WriteFailed;
        };
        w.since = 0;
        return n;
    }
};

/// A buffered writer onto the temp, as `Pending.writer` documents.
pub fn writer(p: *Staged, io: Io, buffer: []u8) *Io.Writer {
    assert.pre(p.state == .open, "Pending.writer: the temp is no longer open for writing");
    p.writer_state.io = io;
    p.writer_state.interface = .{ .vtable = &Writer.vtable, .buffer = buffer };
    p.writer_active = true;
    return &p.writer_state.interface;
}

// ---------------------------------------------------------------------
// Commit
// ---------------------------------------------------------------------

pub const Publish = enum {
    /// Replace the destination if it exists.
    replace,
    /// Fail with `error.PathAlreadyExists` if the destination exists.
    create_new,
    /// Leave an existing destination alone and report `kept`.
    keep_existing,
};

pub const CommitOptions = struct {
    level: Level = .data,
    publish: Publish = .replace,
    /// Windows: how long to retry a rename a scanner or indexer is
    /// blocking. 0 = once.
    busy_deadline: Io.Duration = .fromMilliseconds(2000),
    /// As `SyncOptions.barrier`: Darwin orders the temp with a barrier and
    /// flushes the device once, at the directory.
    barrier: bool = true,
    /// Optional executor for raw syncs; null runs inline. Borrowed for this call.
    blocking: ?Blocking = null,
};

/// `kept`: the name already existed and was left alone. `reached` is then
/// `.none`, because nothing airlock did made the existing file durable; a
/// `Batch` syncs it.
pub const Committed = struct { reached: Reached, kept: bool };

pub const CommitError = platform.DirSyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError || Io.File.Writer.Error || error{
    /// `create_new`, and the name is taken. The temp is removed.
    PathAlreadyExists,
    /// The new name is visible; its directory sync failed or was
    /// canceled. The cause is in `cause`.
    PublishedNotDurable,
    /// An earlier sync or write failed; only `discard` is valid.
    Poisoned,
    /// `create_new` on a filesystem with no atomic no-replace rename and no
    /// hard links.
    OperationUnsupported,
};

/// `CommitError`, and a filesystem that cannot keep the level.
pub const CommitOrRefuseError = CommitError || error{
    /// The filesystem refused a call the level needs. Darwin and Windows
    /// know before the rename, and nothing is published; the pending stays
    /// as it was, to commit at a lower level or discard. Linux learns of a
    /// refused directory sync only after it: that is `PublishedNotDurable`
    /// with `cause` `LevelUnavailable`.
    LevelUnavailable,
};

/// What `commit` can fail with, as `fallback` decides.
fn CommitErrorOf(comptime fallback: Fallback) type {
    return if (fallback == .refuse) CommitOrRefuseError else CommitError;
}

/// Syncs the temp, publishes it and syncs its directory, as
/// `Pending.commit` and `Pending.commitOrRefuse` document.
pub fn commit(p: *Staged, comptime fallback: Fallback, io: Io, options: CommitOptions) CommitErrorOf(fallback)!Committed {
    assert.pre(p.state != .published and p.state != .kept and p.state != .discarded, "Pending.commit: the pending already ended");
    switch (p.state) {
        .poisoned => return error.Poisoned,
        .published, .kept, .discarded => unreachable, // unreachable: the contract above stops a pending that ended
        .synced => {
            // The temp was synced once; on POSIX it is closed, so nothing
            // can make it stronger now: what it reached is what it has.
            if (fallback == .refuse and !fileMeets(p.file_reached, options)) return error.LevelUnavailable;
            return p.publishSynced(fallback, io, options);
        },
        .open => {},
    }
    try p.flushWriter(io);
    try p.syncTemp(fallback, io, options);
    return p.publishSynced(fallback, io, options);
}

/// Flushes a writer in use. Any failure, a write's or a writeback's, is a
/// failed sync.
pub fn flushWriter(p: *Staged, io: Io) CommitError!void {
    if (p.cause) |cause| return p.poison(io, cause);
    if (!p.writer_active) return;
    p.writer_state.interface.flush() catch {
        const cause = p.writer_state.err orelse error.InputOutput;
        return p.poison(io, cause);
    };
}

/// The level the temp is synced at: Darwin orders it with a barrier and
/// leaves the device flush to the directory sync.
fn fileLevel(options: CommitOptions) Level {
    if (is_darwin and options.barrier and @backingInt(options.level) >= @backingInt(Level.ordered)) return .ordered;
    return options.level;
}

/// Whether what the temp's sync reached lets the commit keep its promise:
/// on Darwin a barrier proves the directory's full flush is available.
fn fileMeets(reached: Reached, options: CommitOptions) bool {
    if (reached.atLeast(options.level)) return true;
    return is_darwin and reached == .ordered and options.barrier;
}

fn syncTemp(p: *Staged, comptime fallback: Fallback, io: Io, options: CommitOptions) CommitErrorOf(fallback)!void {
    const reached = platform.syncChain(io, options.blocking, p.file.handle, fileLevel(options), options.barrier, p.tempName()) catch |err| switch (err) {
        // EINTR and a cancel are not a failed sync: the kernel kept its state.
        error.Canceled => return error.Canceled,
        else => |e| return p.poison(io, e),
    };
    if (fallback == .refuse and !fileMeets(reached, options)) return error.LevelUnavailable;
    try p.markSynced(io, reached);
}

/// Records what the temp's sync reached. POSIX closes the temp, checking
/// `close` once: an NFS deferred write fails there.
pub fn markSynced(p: *Staged, io: Io, reached: Reached) CommitError!void {
    p.file_reached = reached;
    p.moveTo(.synced);
    if (!is_windows) {
        p.file_open = false;
        sys.close(io, p.file.handle, p.tempName()) catch |err| return p.poison(io, err);
    }
}

/// Marks the temp poisoned, removes it, and returns `cause`.
fn poison(p: *Staged, io: Io, cause: anyerror) CommitError {
    p.markFailed(io, cause);
    return @errorCast(cause);
}

/// A failed sync or write: the temp is removed and only `discard` is valid.
pub fn markFailed(p: *Staged, io: Io, cause: anyerror) void {
    p.cause = cause;
    p.removeTemp(io);
    p.releaseParent(io);
    p.moveTo(.poisoned);
}

/// Closes the temp if it is open and removes its name. On Windows by
/// handle, so the name goes even while a scanner holds the file.
fn removeTemp(p: *Staged, io: Io) void {
    if (is_windows and p.file_open) {
        // glint-ignore: Z026 -- cleanup after a failure the caller already gets
        sys.dispose(io, p.file.handle, p.tempName()) catch {};
        sys.release(io, p.file.handle);
        p.file_open = false;
        return;
    }
    if (p.file_open) {
        sys.release(io, p.file.handle);
        p.file_open = false;
    }
    if (p.parent_open) {
        // glint-ignore: Z026 -- cleanup after a failure the caller already gets
        sys.unlink(io, p.parent.handle, p.tempName()) catch {};
        return;
    }
    // A batch closed the parent: name the temp from the caller's directory.
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const parent = p.parentSubPath() orelse "";
    const path = if (parent.len == 0) p.tempName() else std.mem.print(&buffer, "{s}/{s}", .{ parent, p.tempName() }) catch return;
    // glint-ignore: Z026 -- cleanup after a failure the caller already gets
    sys.unlink(io, p.root.handle, path) catch {};
}

fn releaseParent(p: *Staged, io: Io) void {
    if (p.owns_parent and p.parent_open) sys.release(io, p.parent.handle);
    p.parent_open = false;
}

/// Steps 4 to 8 of a commit, from a synced temp.
fn publishSynced(p: *Staged, comptime fallback: Fallback, io: Io, options: CommitOptions) CommitErrorOf(fallback)!Committed {
    var flush: ?sys.Handle = null;
    defer if (flush) |h| sys.release(io, h);
    var dir_refused = false;
    if (is_windows and @backingInt(options.level) >= @backingInt(Level.data)) {
        flush = platform.openDirFlush(io, p.parent.handle, options.busy_deadline) catch |err| switch (err) {
            error.NoDevice => blk: {
                if (fallback == .refuse) return error.LevelUnavailable;
                dir_refused = true;
                break :blk null;
            },
            else => |e| return e,
        };
    }
    try io.checkCancel();
    switch (try p.rename(io, options)) {
        .renamed => {},
        .taken => return p.taken(io, options.publish),
    }
    p.moveTo(.published);
    const reached = p.syncParent(fallback, io, options, flush, dir_refused) catch |err| {
        p.cause = err;
        p.finish(io);
        return error.PublishedNotDurable;
    };
    p.finish(io);
    return .{ .reached = reached, .kept = false };
}

/// After the rename: the directory sync, and what the commit reached.
fn syncParent(p: *Staged, comptime fallback: Fallback, io: Io, options: CommitOptions, flush: ?sys.Handle, refused_before: bool) anyerror!Reached {
    const cut: Reached = Reached.min(p.file_reached, .ordered);
    if (@backingInt(options.level) < @backingInt(Level.data)) return cut;
    try io.checkCancel();
    const outcome: platform.DirOutcome = if (is_windows)
        (if (flush) |h| try platform.flushDir(io, options.blocking, h, p.baseName()) else .{ .reached = .none, .refused = refused_before })
    else
        try platform.dirSync(io, options.blocking, p.parent.handle, options.busy_deadline, p.baseName());
    if (outcome.refused) {
        if (fallback == .refuse) return error.LevelUnavailable;
        // The data was ordered before the name; the name may be lost.
        return cut;
    }
    return combine(p.file_reached, outcome.reached);
}

/// What a file sync followed by a successful directory sync reached. On
/// Darwin the directory's `F_FULLFSYNC` persists everything handed to the
/// device before it, so it upgrades a file that was handed to it; a file
/// no sync reached is still only in the page cache.
fn combine(file: Reached, dir: Reached) Reached {
    if (is_darwin and dir == .full and file != .none) return .full;
    return Reached.min(file, dir);
}

const Renamed = enum { renamed, taken };

/// Step 6: the rename, as `options.publish` asks.
fn rename(p: *Staged, io: Io, options: CommitOptions) CommitError!Renamed {
    if (is_windows) return p.renameWindows(io, options);
    const parent = p.parent.handle;
    if (options.publish == .replace) {
        try sys.rename(io, parent, p.tempName(), parent, p.baseName());
        return .renamed;
    }
    sys.renameNoReplace(io, parent, p.tempName(), parent, p.baseName()) catch |err| switch (err) {
        error.AlreadyExists => return .taken,
        error.Refused => return p.linkFallback(io, options.publish),
        else => |e| return e,
    };
    return .renamed;
}

/// A no-replace publish where the filesystem has no such rename: a hard
/// link, then the temp's name removed. A crash between them leaves the temp
/// as a second name for the same file, which `pruneTemps` removes. Without
/// hard links, `keep_existing` checks then renames (safe, since equal names
/// hold equal contents) and `create_new` cannot be done.
fn linkFallback(p: *Staged, io: Io, publish: Publish) CommitError!Renamed {
    const parent = p.parent.handle;
    sys.link(io, parent, p.tempName(), parent, p.baseName()) catch |err| switch (err) {
        error.AlreadyExists => return .taken,
        error.Refused => {
            if (publish == .create_new) return error.OperationUnsupported;
            const present = sys.exists(io, parent, p.baseName()) catch |stat_err| switch (stat_err) {
                error.FileLocksUnsupported, error.Streaming => return error.Unexpected,
                else => |e| return e,
            };
            if (present) return .taken;
            try sys.rename(io, parent, p.tempName(), parent, p.baseName());
            return .renamed;
        },
        else => |e| return e,
    };
    // The new name holds the file; the temp's name is a leftover
    // `pruneTemps` removes if this fails.
    // glint-ignore: Z026 -- the published name holds the file; a leftover temp name is prunable by its prefix
    sys.unlink(io, parent, p.tempName()) catch {};
    return .renamed;
}

fn renameWindows(p: *Staged, io: Io, options: CommitOptions) CommitError!Renamed {
    var backoff: platform.Backoff = .start(io, options.busy_deadline);
    while (true) {
        const outcome = try sys.renameByHandle(io, p.file.handle, p.parent.handle, p.baseName(), options.publish == .replace);
        switch (outcome) {
            .renamed => return .renamed,
            .collision => return .taken,
            .denied, .sharing => {
                if (try backoff.wait(io)) continue;
                return if (outcome == .denied) error.AccessDenied else error.FileBusy;
            },
        }
    }
}

/// The name was taken: remove the temp, then report as `publish` says.
fn taken(p: *Staged, io: Io, publish: Publish) CommitError!Committed {
    const failure = p.removeTakenTemp(io);
    p.finish(io);
    if (publish == .create_new) {
        p.moveTo(.discarded);
        try failure;
        return error.PathAlreadyExists;
    }
    p.moveTo(.kept);
    try failure;
    return .{ .reached = .none, .kept = true };
}

fn removeTakenTemp(p: *Staged, io: Io) Io.Dir.DeleteFileError!void {
    if (is_windows) {
        try sys.dispose(io, p.file.handle, p.tempName());
        return;
    }
    try sys.unlink(io, p.parent.handle, p.tempName());
}

/// Closes what is still open once the temp's part has ended: the temp
/// itself, and a parent airlock opened.
pub fn finish(p: *Staged, io: Io) void {
    if (p.file_open) {
        sys.release(io, p.file.handle);
        p.file_open = false;
    }
    p.releaseParent(io);
}

/// Idempotent, as `Pending.discard` documents.
pub fn discard(p: *Staged, io: Io) void {
    switch (p.state) {
        .open, .synced => p.removeTemp(io),
        // A poisoned temp was removed when the sync failed.
        .poisoned, .published, .kept, .discarded => {},
    }
    p.finish(io);
    p.moveTo(.discarded);
}

// ---------------------------------------------------------------------
// The steps a batch takes
// ---------------------------------------------------------------------

/// Closes a parent airlock opened, so a batch of many holds one handle
/// each. The batch opens each distinct parent once, when it renames.
pub fn dropParent(p: *Staged, io: Io) void {
    if (p.owns_parent and p.parent_open) {
        sys.release(io, p.parent.handle);
        p.parent_open = false;
    }
}

/// The batch's handle on the parent from here on.
pub fn adoptParent(p: *Staged, parent: Io.Dir) void {
    p.parent = parent;
    p.owns_parent = false;
    p.parent_open = true;
}

/// Renames a synced temp as `publish` says: true if renamed, false if
/// `keep_existing` found the name taken.
pub fn renameSynced(p: *Staged, io: Io, publish: Publish, busy: Io.Duration) CommitError!bool {
    const options: CommitOptions = .{ .publish = publish, .busy_deadline = busy };
    switch (try p.rename(io, options)) {
        .renamed => {
            p.moveTo(.published);
            return true;
        },
        .taken => {
            _ = p.taken(io, publish) catch |err| switch (err) {
                error.PathAlreadyExists => return error.PathAlreadyExists,
                else => |e| return e,
            };
            return false;
        },
    }
}

test "a staged file moves forward only: a synced temp publishes or is kept, and discard follows anything" {
    const tags = std.meta.tags(State);
    for (tags) |from| {
        try std.testing.expect(!from.moves(.open));
        try std.testing.expect(from.moves(.discarded));
    }
    try std.testing.expect(State.open.moves(.synced));
    try std.testing.expect(State.open.moves(.poisoned));
    try std.testing.expect(State.synced.moves(.poisoned));
    try std.testing.expect(State.synced.moves(.published));
    try std.testing.expect(State.synced.moves(.kept));
    // Nothing is published or kept without a sync, and nothing leaves an end.
    try std.testing.expect(!State.open.moves(.published));
    try std.testing.expect(!State.open.moves(.kept));
    try std.testing.expect(!State.synced.moves(.synced));
    for ([_]State{ .published, .kept, .poisoned, .discarded }) |from| {
        for ([_]State{ .synced, .published, .kept, .poisoned }) |to| try std.testing.expect(!from.moves(to));
    }
}

test "base32 names are 26 lowercase characters" {
    var out: [26]u8 = undefined;
    encodeBase32(&@splat(0xff), &out);
    try std.testing.expectEqualStrings("h7777777777777777777777777", &out);
    encodeBase32(&@splat(0), &out);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaa", &out);
}

test "a random name is the prefix and 26 base32 characters, nothing else" {
    try std.testing.expect(isRandomName(".h7777777777777777777777777", "."));
    try std.testing.expect(isRandomName("tmp_obj_aaaaaaaaaaaaaaaaaaaaaaaaaa", "tmp_obj_"));
    // 'i' cannot lead: the first character carries three bits.
    try std.testing.expect(!isRandomName(".i7777777777777777777777777", "."));
    try std.testing.expect(!isRandomName(".h777777777777777777777777", "."));
    try std.testing.expect(!isRandomName(".h77777777777777777777777778", "."));
    try std.testing.expect(!isRandomName(".h777777777777777777777777A", "."));
    try std.testing.expect(!isRandomName("main.lock", "."));
}

test "a destination splits into its directory and its base" {
    try std.testing.expectEqual(@as(usize, 0), baseStart("HEAD"));
    try std.testing.expectEqual(@as(usize, 11), baseStart("refs/heads/main"));
    try std.testing.expectEqualStrings("refs/heads", parentPath("refs/heads/main", 11));
    try std.testing.expectEqualStrings("/", parentPath("/x", 1));
}
