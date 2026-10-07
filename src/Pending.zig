//! A file being written under a temporary name in its destination's
//! directory, published by `commit` as a replace, a create or a keep.
//!
//! The temp is created exclusively next to the destination, never in a
//! system temp directory: a rename across filesystems is a copy, and tmp
//! cleaners remove what they do not know. Writes go to `file` directly or
//! through `writer`. `commit` syncs the temp through the handle that wrote
//! it, publishes it, then syncs the directory that received the name.
//! `discard` removes the temp; it is idempotent and meant for `defer`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("sys.zig");
const platform = @import("platform.zig");
const level_mod = @import("level.zig");
const Level = level_mod.Level;
const Reached = level_mod.Reached;
const Fallback = level_mod.Fallback;

const Pending = @This();

const native_os = builtin.os.tag;
const is_windows = native_os == .windows;
const is_darwin = native_os.isDarwin();

/// The temp file. Write to it directly, or through `writer`.
file: Io.File,
/// The error behind `error.PublishedNotDurable` or a poisoned state.
cause: ?anyerror = null,
/// Private: the directory the destination is in, held from create to the
/// end. Not valid after a batch took the pending and closed it.
parent: Io.Dir,
/// Private: whether airlock opened `parent` and closes it.
owns_parent: bool,
/// Private: whether `parent` is open.
parent_open: bool,
/// Private: the directory the caller named the destination relative to.
root: Io.Dir,
/// Private: the destination as the caller named it, borrowed.
dest: []const u8,
/// Private: where the base name starts in `dest`.
base_start: usize,
/// Private: a random temp name, inline.
temp_buffer: [64]u8,
/// Private: the temp name's length in `temp_buffer`; 0 for an exact name.
temp_len: u8,
/// Private: an exact temp name, borrowed.
exact: []const u8,
/// Private: where the pending is (see `State`).
state: State = .open,
/// Private: whether `file`'s handle is open.
file_open: bool = true,
/// Private: the level the temp was synced at, for a retried commit.
synced_level: Level = .none,
/// Private: what the temp's sync reached.
file_reached: Reached = .none,
/// Private: the writer `writer` hands out, and whether it is in use.
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
    /// A sync failed: the contents are unknown, the temp is gone, and only
    /// `discard` is valid.
    poisoned,
    /// Nothing is left: discarded, or a create that found the name taken.
    discarded,
};

/// The name of the temp file in the destination's directory.
pub const Temp = union(enum) {
    /// A prefix (at most 32 bytes, no separator) followed by 26 lowercase
    /// base32 characters (128 bits from `io.random`). Lowercase base32 is
    /// safe on case-insensitive filesystems. A leading `.` hides it.
    random: []const u8,
    /// This exact base name in the destination's directory, such as a git
    /// lock file ("main.lock" for "refs/heads/main"). Taken means
    /// `error.PathAlreadyExists`. Borrowed until commit or discard.
    exact: []const u8,
};

pub const Mode = union(enum) {
    /// The platform default for a new file; umask applies.
    default,
    /// Set on the open handle right after the create; umask does not apply.
    exact: Io.File.Permissions,
    /// The destination's current permissions, or the default if it does
    /// not exist.
    inherit,
};

pub const CreateOptions = struct {
    temp: Temp = .{ .random = "." },
    mode: Mode = .default,
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

/// Creates the temp for `dest_sub_path`, relative to `dir`. A nested
/// destination ("refs/heads/main") has its directory opened once here and
/// held, so the create, the rename and the directory sync all work relative
/// to one handle. `dest_sub_path` is borrowed until commit or discard.
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn create(io: Io, dir: Io.Dir, dest_sub_path: []const u8, options: CreateOptions) CreateError!Pending {
    const base_start = baseStart(dest_sub_path);
    const base = dest_sub_path[base_start..];
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.BadPathName;
    var p: Pending = .{
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
fn baseStart(path: []const u8) usize {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or (is_windows and c == '\\')) return i;
    }
    return 0;
}

/// The directory part of `path`, given where its base starts: "/" for a
/// name at the root.
fn parentPath(path: []const u8, base_start: usize) []const u8 {
    return if (base_start == 1) path[0..1] else path[0 .. base_start - 1];
}

fn createTemp(p: *Pending, io: Io, options: CreateOptions, mode: Io.File.Permissions) CreateError!sys.Handle {
    switch (options.temp) {
        .exact => |name| {
            if (name.len == 0 or baseStart(name) != 0) return error.BadPathName;
            p.exact = name;
            return sys.createTemp(io, p.parent.handle, name, mode, options.read);
        },
        .random => |prefix| {
            if (prefix.len > 32 or baseStart(prefix) != 0) return error.BadPathName;
            var draws: u32 = 0;
            while (true) {
                p.drawName(io, prefix);
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

/// The prefix, then 26 lowercase base32 characters of 128 random bits.
fn drawName(p: *Pending, io: Io, prefix: []const u8) void {
    var random: [16]u8 = undefined;
    io.random(&random);
    @memcpy(p.temp_buffer[0..prefix.len], prefix);
    encodeBase32(&random, p.temp_buffer[prefix.len..][0..26]);
    p.temp_len = @intCast(prefix.len + 26);
}

const base32 = "abcdefghijklmnopqrstuvwxyz234567";

fn encodeBase32(bytes: *const [16]u8, out: *[26]u8) void {
    var bits = std.mem.readInt(u128, bytes, .big);
    var i: usize = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = base32[@as(u5, @truncate(bits))];
        bits >>= 5;
    }
}

fn applyMode(p: *Pending, io: Io, mode: Mode) CreateError!void {
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
pub fn tempName(p: *const Pending) []const u8 {
    if (p.temp_len == 0) return p.exact;
    return p.temp_buffer[0..p.temp_len];
}

/// The destination's base name.
pub fn baseName(p: *const Pending) []const u8 {
    return p.dest[p.base_start..];
}

/// The destination's directory relative to the caller's `dir`, or null
/// for a destination directly in it.
pub fn parentSubPath(p: *const Pending) ?[]const u8 {
    if (p.base_start == 0) return null;
    return parentPath(p.dest, p.base_start);
}

// ---------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------

/// The writer `Pending.writer` hands out. Its `interface` is an
/// `Io.Writer`; `commit` flushes it.
pub const Writer = struct {
    interface: Io.Writer,
    /// Private: the `Io` the writes go through (a writer adapter keeps it).
    io: Io,
    /// Private: `CreateOptions.writeback_bytes`.
    threshold: u32,
    /// Private: bytes written since the last writeback.
    since: u64 = 0,
    /// Private: bytes written in all.
    offset: u64 = 0,
    /// The error behind the last `error.WriteFailed`.
    err: ?anyerror = null,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    fn pending(w: *Writer) *Pending {
        return @alignCast(@fieldParentPtr("writer_state", w)); // safe: every Writer lives in a Pending
    }

    fn drain(iw: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", iw)); // safe: this vtable is only installed on a Writer
        try w.put(iw.buffered());
        iw.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try w.put(bytes);
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try w.put(last);
        return n + last.len * splat;
    }

    fn put(w: *Writer, bytes: []const u8) Io.Writer.Error!void {
        if (bytes.len == 0) return;
        const p = w.pending();
        p.file.writeStreamingAll(w.io, bytes) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        w.offset += bytes.len;
        w.since += bytes.len;
        if (w.threshold == 0 or w.since < w.threshold) return;
        sys.writeback(w.io, p.file.handle, w.offset - w.since, w.since) catch |err| {
            // A writeback error is a failed sync: the commit poisons.
            w.err = err;
            p.cause = err;
            return error.WriteFailed;
        };
        w.since = 0;
    }
};

/// A buffered writer onto the temp. `commit` flushes it, so bytes still in
/// `buffer` are written before the sync. With `writeback_bytes`, writeback
/// starts every that many bytes. The pending must not move while the
/// writer is in use.
pub fn writer(p: *Pending, io: Io, buffer: []u8) *Io.Writer {
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
    fallback: Fallback = .report,
    publish: Publish = .replace,
    /// Windows: how long to retry a rename a scanner or indexer is
    /// blocking. 0 = once.
    busy_deadline: Io.Duration = .fromMilliseconds(2000),
    /// As `SyncOptions.barrier`: Darwin orders the temp with a barrier and
    /// flushes the device once, at the directory.
    barrier: bool = true,
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
    /// An earlier sync failed; only `discard` is valid.
    Poisoned,
    /// `create_new` on a filesystem with no atomic no-replace rename and no
    /// hard links.
    OperationUnsupported,
};

/// Syncs the temp at `options.level`, publishes it, and syncs the
/// directory that received the name.
///
/// A failed sync poisons the pending and removes the temp at once: its
/// contents are unknown and must never be renamed into place. Write the
/// bytes from your own copy into a new `Pending`. A rename that fails and
/// leaves the temp intact (`AccessDenied`, a deadline) leaves the pending
/// `synced`, and a second `commit` retries only the rename. A cancel before
/// the rename returns `error.Canceled` with the state unchanged; after it,
/// `error.PublishedNotDurable` with `cause` `Canceled`.
///
/// With `Fallback.refuse`, Darwin and Windows decide everything before the
/// rename. Linux learns that a filesystem refuses `fsync` on a directory
/// only after it, and then returns `PublishedNotDurable` with `cause`
/// `LevelUnavailable` (ext4, xfs and btrfs accept it).
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn commit(p: *Pending, io: Io, options: CommitOptions) CommitError!Committed {
    switch (p.state) {
        .poisoned => return error.Poisoned,
        .published, .kept, .discarded => unreachable, // unreachable: commit after the pending ended is a caller bug
        .synced => {
            if (@backingInt(options.level) > @backingInt(p.synced_level)) {
                if (std.debug.runtime_safety) @panic("airlock: a retried commit asked for a stronger level than its first sync");
                return error.LevelUnavailable;
            }
            return p.publishSynced(io, options);
        },
        .open => {},
    }
    try p.flushWriter(io);
    try p.syncTemp(io, options);
    return p.publishSynced(io, options);
}

/// Flushes a writer in use. Any failure, a writeback's included, is a
/// failed sync.
fn flushWriter(p: *Pending, io: Io) CommitError!void {
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

fn syncTemp(p: *Pending, io: Io, options: CommitOptions) CommitError!void {
    const reached = platform.syncChain(io, p.file.handle, fileLevel(options), options.barrier, p.tempName()) catch |err| switch (err) {
        // EINTR and a cancel are not a failed sync: the kernel kept its state.
        error.Canceled => return error.Canceled,
        else => |e| return p.poison(io, e),
    };
    if (options.fallback == .refuse and !fileMeets(reached, options)) return error.LevelUnavailable;
    p.file_reached = reached;
    p.synced_level = options.level;
    p.state = .synced;
    if (!is_windows) {
        // close is checked exactly once: an NFS deferred write fails here.
        p.file_open = false;
        sys.close(io, p.file.handle, p.tempName()) catch |err| return p.poison(io, err);
    }
}

/// Marks the pending poisoned, removes the temp, and returns `cause`.
fn poison(p: *Pending, io: Io, cause: anyerror) CommitError {
    p.poisonState(io, cause);
    return @errorCast(cause);
}

fn poisonState(p: *Pending, io: Io, cause: anyerror) void {
    p.cause = cause;
    p.removeTemp(io);
    p.releaseParent(io);
    p.state = .poisoned;
}

/// Closes the temp if it is open and removes its name. On Windows by
/// handle, so the name goes even while a scanner holds the file.
fn removeTemp(p: *Pending, io: Io) void {
    if (is_windows and p.file_open) {
        // ziglint-ignore: Z026 cleanup after a failure the caller already gets
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
        // ziglint-ignore: Z026 cleanup after a failure the caller already gets
        sys.unlink(io, p.parent.handle, p.tempName()) catch {};
        return;
    }
    // A batch closed the parent: name the temp from the caller's directory.
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const parent = p.parentSubPath() orelse "";
    const path = if (parent.len == 0) p.tempName() else std.mem.print(&buffer, "{s}/{s}", .{ parent, p.tempName() }) catch return;
    // ziglint-ignore: Z026 cleanup after a failure the caller already gets
    sys.unlink(io, p.root.handle, path) catch {};
}

fn releaseParent(p: *Pending, io: Io) void {
    if (p.owns_parent and p.parent_open) sys.release(io, p.parent.handle);
    p.parent_open = false;
}

/// Steps 4 to 8 of a commit, from a synced temp.
fn publishSynced(p: *Pending, io: Io, options: CommitOptions) CommitError!Committed {
    var flush: ?sys.Handle = null;
    defer if (flush) |h| sys.release(io, h);
    var dir_refused = false;
    if (is_windows and @backingInt(options.level) >= @backingInt(Level.data)) {
        flush = platform.openDirFlush(io, p.parent.handle, options.busy_deadline, null) catch |err| switch (err) {
            error.NoDevice => blk: {
                if (options.fallback == .refuse) return error.LevelUnavailable;
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
    p.state = .published;
    const reached = p.syncParent(io, options, flush, dir_refused) catch |err| {
        p.cause = err;
        p.finish(io);
        return error.PublishedNotDurable;
    };
    p.finish(io);
    return .{ .reached = reached, .kept = false };
}

/// After the rename: the directory sync, and what the commit reached.
fn syncParent(p: *Pending, io: Io, options: CommitOptions, flush: ?sys.Handle, refused_before: bool) anyerror!Reached {
    const cut: Reached = Reached.min(p.file_reached, .ordered);
    if (@backingInt(options.level) < @backingInt(Level.data)) return cut;
    try io.checkCancel();
    const outcome: platform.DirOutcome = if (is_windows)
        (if (flush) |h| try platform.flushDir(io, h, p.baseName()) else .{ .reached = .none, .refused = refused_before })
    else
        try platform.dirSync(io, p.parent.handle, options.barrier, options.busy_deadline, p.baseName());
    if (outcome.refused) {
        if (options.fallback == .refuse) return error.LevelUnavailable;
        // The data was ordered before the name; the name may be lost.
        return cut;
    }
    return combine(p.file_reached, outcome.reached);
}

/// What a file sync followed by a successful directory sync reached. On
/// Darwin the directory's `F_FULLFSYNC` persists everything handed to the
/// device before it, so it upgrades the file.
pub fn combine(file: Reached, dir: Reached) Reached {
    if (is_darwin and dir == .full) return .full;
    return Reached.min(file, dir);
}

const Renamed = enum { renamed, taken };

/// Step 6: the rename, as `options.publish` asks.
fn rename(p: *Pending, io: Io, options: CommitOptions) CommitError!Renamed {
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
/// as a second name for the same file, which its prefix lets a caller
/// prune. Without hard links, `keep_existing` checks then renames (safe,
/// since equal names hold equal contents) and `create_new` cannot be done.
fn linkFallback(p: *Pending, io: Io, publish: Publish) CommitError!Renamed {
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
    // The new name holds the file; the temp's name is a leftover a caller
    // prunes by prefix if this fails.
    // ziglint-ignore: Z026 the published name holds the file; a leftover temp name is prunable by its prefix
    sys.unlink(io, parent, p.tempName()) catch {};
    return .renamed;
}

fn renameWindows(p: *Pending, io: Io, options: CommitOptions) CommitError!Renamed {
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
fn taken(p: *Pending, io: Io, publish: Publish) CommitError!Committed {
    const failure = p.removeTakenTemp(io);
    p.finish(io);
    if (publish == .create_new) {
        p.state = .discarded;
        try failure;
        return error.PathAlreadyExists;
    }
    p.state = .kept;
    try failure;
    return .{ .reached = .none, .kept = true };
}

fn removeTakenTemp(p: *Pending, io: Io) Io.Dir.DeleteFileError!void {
    if (is_windows) {
        try sys.dispose(io, p.file.handle, p.tempName());
        return;
    }
    try sys.unlink(io, p.parent.handle, p.tempName());
}

/// Step 8: close what is still open once the pending has ended.
fn finish(p: *Pending, io: Io) void {
    if (p.file_open) {
        sys.release(io, p.file.handle);
        p.file_open = false;
    }
    p.releaseParent(io);
}

/// Idempotent; meant for `defer`. Before the publish it closes the temp and
/// removes its name; after, it closes whatever is still open and never
/// unlinks, so it cannot remove a name someone else now owns.
pub fn discard(p: *Pending, io: Io) void {
    switch (p.state) {
        .open, .synced => p.removeTemp(io),
        // A poisoned pending removed its temp when the sync failed.
        .poisoned, .published, .kept, .discarded => {},
    }
    p.finish(io);
    p.state = .discarded;
}

/// Batch use: closes a parent airlock opened, so a batch of many pendings
/// holds one handle each. The batch reopens each distinct parent once.
pub fn dropParent(p: *Pending, io: Io) void {
    if (p.owns_parent and p.parent_open) {
        sys.release(io, p.parent.handle);
        p.parent_open = false;
    }
}

/// Batch use: the batch's handle on the parent from here on.
pub fn adoptParent(p: *Pending, parent: Io.Dir) void {
    p.parent = parent;
    p.owns_parent = false;
    p.parent_open = true;
}

/// Batch use: a synced temp, ready to be renamed. POSIX closes the temp,
/// checking `close` once.
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn markSynced(p: *Pending, io: Io, level: Level, reached: Reached) CommitError!void {
    p.file_reached = reached;
    p.synced_level = level;
    p.state = .synced;
    if (!is_windows) {
        p.file_open = false;
        sys.close(io, p.file.handle, p.tempName()) catch |err| return p.poison(io, err);
    }
}

/// Batch use: flushes a writer in use before the batch syncs the temp.
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn prepare(p: *Pending, io: Io) CommitError!void {
    return p.flushWriter(io);
}

/// Batch use: a failed sync of the temp.
pub fn markFailed(p: *Pending, io: Io, cause: anyerror) void {
    p.poisonState(io, cause);
}

/// Batch use: rename a synced temp.
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn renameSynced(p: *Pending, io: Io, publish: Publish, busy: Io.Duration) CommitError!bool {
    const options: CommitOptions = .{ .publish = publish, .busy_deadline = busy };
    switch (try p.rename(io, options)) {
        .renamed => {
            p.state = .published;
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

/// Batch use: the pending has ended inside a batch.
pub fn finishPublished(p: *Pending, io: Io) void {
    p.finish(io);
}

pub const WriteFileOptions = struct {
    create: CreateOptions = .{},
    commit: CommitOptions = .{},
};

pub const WriteFileError = CreateError || CommitError || Io.File.WritePositionalError;

/// Create, write and commit, for a whole buffer.
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn writeFile(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8, options: WriteFileOptions) WriteFileError!Committed {
    var p = try create(io, dir, sub_path, options.create);
    defer p.discard(io);
    try p.file.writePositionalAll(io, bytes, 0);
    return p.commit(io, options.commit);
}

test "base32 names are 26 lowercase characters" {
    var out: [26]u8 = undefined;
    encodeBase32(&@splat(0xff), &out);
    try std.testing.expectEqualStrings("h7777777777777777777777777", &out);
    encodeBase32(&@splat(0), &out);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaa", &out);
}

test "a destination splits into its directory and its base" {
    try std.testing.expectEqual(@as(usize, 0), baseStart("HEAD"));
    try std.testing.expectEqual(@as(usize, 11), baseStart("refs/heads/main"));
    try std.testing.expectEqualStrings("refs/heads", parentPath("refs/heads/main", 11));
    try std.testing.expectEqualStrings("/", parentPath("/x", 1));
}
