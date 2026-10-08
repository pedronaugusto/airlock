//! Names made durable: renames, removals, new directories and symbolic
//! links, each with the directory syncs that make it survive a power cut,
//! and the removal of temps a crash left behind.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Blocking = @import("Blocking.zig");
const sys = @import("sys.zig");
const platform = @import("platform.zig");
const level_mod = @import("level.zig");
const Staged = @import("Staged.zig");
const Level = level_mod.Level;
const Reached = level_mod.Reached;
const SyncOptions = level_mod.SyncOptions;
const Fallback = level_mod.Fallback;

const is_windows = builtin.target.os.tag == .windows;

/// The errors behind `error.PublishedNotDurable`: the name changed, and the
/// sync that would make the change durable failed.
pub const SyncAfterError = platform.DirSyncError || Io.File.StatError;

/// Where a call puts what `error.PublishedNotDurable` hides.
pub const Diagnostics = struct {
    /// The error of the sync after the name changed.
    cause: ?SyncAfterError = null,
};

pub const RenameOptions = struct {
    sync: SyncOptions = .{},
    /// Windows: how long to retry a rename a scanner or indexer is
    /// blocking. 0 = once.
    busy_deadline: Io.Duration = .fromMilliseconds(2000),
    /// Filled in when the call returns `error.PublishedNotDurable`.
    diagnostics: ?*Diagnostics = null,
};

pub const RenameError = Io.Dir.RenameError || error{
    /// The rename happened; a directory sync after it failed or was
    /// canceled. `diagnostics` says which.
    PublishedNotDurable,
};

/// Renames `old` (relative to `old_dir`) to `new` (relative to `new_dir`),
/// replacing `new` if it exists, then syncs the directory that holds `new`
/// and, when it is a different one, the directory that held `old`: on a
/// filesystem that does not journal both entries together a crash must not
/// leave both names or neither. Any error after the rename is
/// `error.PublishedNotDurable`, so a caller can tell "not renamed" from
/// "renamed, not yet durable". A directory sync the filesystem refuses
/// leaves the rename `.ordered`.
pub fn rename(io: Io, old_dir: Io.Dir, old: []const u8, new_dir: Io.Dir, new: []const u8, options: RenameOptions) RenameError!Reached {
    if (is_windows) {
        try renameWindows(io, old_dir, old, new_dir, new, options.busy_deadline);
    } else {
        try sys.rename(io, old_dir.handle, old, new_dir.handle, new);
    }
    if (@backingInt(options.sync.level) < @backingInt(Level.data)) return .none;
    return syncRenamed(io, old_dir, old, new_dir, new, options) catch |err| return notDurable(options.diagnostics, err);
}

fn syncRenamed(io: Io, old_dir: Io.Dir, old: []const u8, new_dir: Io.Dir, new: []const u8, options: RenameOptions) SyncAfterError!Reached {
    var new_parent = try Parent.open(io, new_dir, new);
    defer new_parent.close(io);
    var old_parent = try Parent.open(io, old_dir, old);
    defer old_parent.close(io);
    var reached = try syncOne(io, options.sync.blocking, new_parent.dir, options.busy_deadline);
    if (!try sameDirectory(io, new_parent.dir, old_parent.dir)) {
        reached = Reached.min(reached, try syncOne(io, options.sync.blocking, old_parent.dir, options.busy_deadline));
    }
    return reached;
}

/// Records `cause` and returns `error.PublishedNotDurable`.
fn notDurable(diagnostics: ?*Diagnostics, cause: SyncAfterError) error{PublishedNotDurable} {
    if (diagnostics) |d| d.cause = cause;
    return error.PublishedNotDurable;
}

fn renameWindows(io: Io, old_dir: Io.Dir, old: []const u8, new_dir: Io.Dir, new: []const u8, busy: Io.Duration) Io.Dir.RenameError!void {
    const handle = sys.openFileWindows(io, old_dir.handle, old, .rename) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.FileBusy => error.FileBusy,
        error.IsDir => error.IsDir,
        error.NotDir => error.NotDir,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.NetworkNotFound => error.NetworkNotFound,
        error.NoDevice => error.NoDevice,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.SystemResources => error.SystemResources,
        error.AntivirusInterference => error.AntivirusInterference,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
    defer sys.release(io, handle);
    var backoff: platform.Backoff = .start(io, busy);
    while (true) {
        const outcome = try sys.renameByHandle(io, handle, new_dir.handle, new, true);
        switch (outcome) {
            .renamed => return,
            .collision => return error.DirNotEmpty,
            .denied, .sharing => {
                if (try backoff.wait(io)) continue;
                return if (outcome == .denied) error.AccessDenied else error.FileBusy;
            },
        }
    }
}

pub const RemoveError = Io.Dir.DeleteFileError || error{
    /// The name is gone; the directory sync after it failed or was
    /// canceled. `diagnostics` says which.
    PublishedNotDurable,
};

/// Removes a file and syncs the directory that held it. On Windows the
/// delete has POSIX semantics: the name goes at once, even while another
/// process holds the file open. Any error after the removal is
/// `error.PublishedNotDurable`.
pub fn remove(io: Io, dir: Io.Dir, sub_path: []const u8, options: RenameOptions) RemoveError!Reached {
    try sys.unlink(io, dir.handle, sub_path);
    if (@backingInt(options.sync.level) < @backingInt(Level.data)) return .none;
    return syncParentOf(io, dir, sub_path, options) catch |err| return notDurable(options.diagnostics, err);
}

fn syncParentOf(io: Io, dir: Io.Dir, sub_path: []const u8, options: RenameOptions) SyncAfterError!Reached {
    var parent = try Parent.open(io, dir, sub_path);
    defer parent.close(io);
    return syncOne(io, options.sync.blocking, parent.dir, options.busy_deadline);
}

// ---------------------------------------------------------------------
// New directories
// ---------------------------------------------------------------------

pub const MakePathOptions = struct {
    sync: SyncOptions = .{},
    /// Filled in when the call returns `error.PublishedNotDurable`.
    diagnostics: ?*Diagnostics = null,
};

pub const MakePathError = Io.Dir.CreateDirError || Io.Dir.OpenError || platform.DirSyncError || error{
    /// A directory was created; the sync of the directory that received
    /// it failed or was canceled.
    PublishedNotDurable,
};

/// What `makePath` did: how many directories it created, and what the
/// syncs of their parents reached. `.none` when it synced nothing: nothing
/// airlock did made the existing directories durable.
pub const Made = struct { reached: Reached, created: u32 };

/// How many times `makePath` starts again when a directory it was about to
/// create into vanished (a concurrent prune).
const max_vanished = 8;

/// Creates every missing directory of `sub_path`, relative to `dir`, and
/// syncs the directory each new one was created in, so a file published
/// into the deepest one later is not lost with a parent nobody synced (the
/// mkdir case of Pillai et al., OSDI '14). A directory another process
/// creates first is taken as it is, and its parent is synced all the same.
/// When a parent vanishes under it, it starts again, a few times.
pub fn makePath(io: Io, dir: Io.Dir, sub_path: []const u8, options: MakePathOptions) MakePathError!Made {
    var made: Made = .{ .reached = .full, .created = 0 };
    var synced = false;
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        makeMissing(io, dir, sub_path, options, &made, &synced) catch |err| switch (err) {
            error.FileNotFound => if (tries + 1 < max_vanished) continue else return err,
            else => |e| return e,
        };
        break;
    }
    if (!synced) made.reached = .none;
    return made;
}

/// One pass of `makePath`: the deepest directory of `sub_path` that
/// exists, then each missing one under it. `FileNotFound` means a
/// directory vanished on the way, and the caller starts again.
fn makeMissing(io: Io, dir: Io.Dir, sub_path: []const u8, options: MakePathOptions, made: *Made, synced: *bool) MakePathError!void {
    var end = sub_path.len;
    while (end > 0 and isSeparator(sub_path[end - 1])) end -= 1;
    // The deepest prefix that exists, from the whole path back.
    var start = end;
    const deepest: ?sys.Handle = while (start > 0) {
        if (sys.openDir(io, dir.handle, sub_path[0..start])) |handle| break handle else |err| switch (err) {
            error.FileNotFound => start = previousSeparator(sub_path, start),
            else => |e| return e,
        }
    } else null;
    var parent: Parent = if (deepest) |handle| .{ .dir = .{ .handle = handle }, .owned = true } else .{ .dir = dir, .owned = false };
    defer parent.close(io);
    var i = start;
    while (i < end) {
        while (i < end and isSeparator(sub_path[i])) i += 1;
        var j = i;
        while (j < end and !isSeparator(sub_path[j])) j += 1;
        const name = sub_path[i..j];
        i = j;
        if (name.len == 0 or std.mem.eql(u8, name, ".")) continue;
        const created = if (sys.makeDir(io, parent.dir.handle, name)) true else |err| switch (err) {
            error.PathAlreadyExists => false,
            else => |e| return e,
        };
        if (created) made.created += 1;
        if (@backingInt(options.sync.level) >= @backingInt(Level.data)) {
            // Whoever created it, its entry is synced before anything goes
            // under it.
            const reached = syncOne(io, options.sync.blocking, parent.dir, platform.default_busy_deadline) catch |err| {
                if (made.created == 0) return err;
                return notDurable(options.diagnostics, err);
            };
            made.reached = Reached.min(made.reached, reached);
            synced.* = true;
        }
        const child = try sys.openDir(io, parent.dir.handle, name);
        parent.close(io);
        parent = .{ .dir = .{ .handle = child }, .owned = true };
    }
}

fn isSeparator(c: u8) bool {
    return c == '/' or (is_windows and c == '\\');
}

/// Where the separator before `end` is in `path`, or 0.
fn previousSeparator(path: []const u8, end: usize) usize {
    var i = end;
    while (i > 0 and !isSeparator(path[i - 1])) i -= 1;
    while (i > 0 and isSeparator(path[i - 1])) i -= 1;
    return i;
}

// ---------------------------------------------------------------------
// Symbolic links
// ---------------------------------------------------------------------

pub const SymLinkOptions = struct {
    sync: SyncOptions = .{},
    /// The temp link's prefix, as `Temp.random`: at most 32 bytes, no
    /// separator.
    temp_prefix: []const u8 = ".",
    /// Filled in when the call returns `error.PublishedNotDurable`.
    diagnostics: ?*Diagnostics = null,
};

pub const SymLinkError = sys.SymLinkError || Io.Dir.RenameError || Io.Dir.OpenError || platform.DirSyncError || error{
    /// The link is in place; the directory sync after the rename failed or
    /// was canceled.
    PublishedNotDurable,
};

/// `SymLinkError`, and a filesystem that cannot keep the level.
pub const SymLinkOrRefuseError = SymLinkError || error{
    /// The filesystem refused the directory sync that orders the new link
    /// before its name, so the level cannot be kept. Nothing was renamed.
    LevelUnavailable,
};

/// Points `sub_path`, relative to `dir`, at `target`, replacing whatever
/// is there in one step: a temp link next to it, renamed over it. Readers
/// see the old name or the new link, never neither. At `ordered` the temp
/// link is made durable before the rename, so a crash cannot leave the name
/// pointing at a link that never reached the disk; at `data` the directory
/// is synced again after the rename. The usual "current -> release-N"
/// swap. A filesystem that refuses the directory sync leaves the link
/// `.written` at best. Windows returns `error.OperationUnsupported`.
pub fn symLink(io: Io, dir: Io.Dir, target: []const u8, sub_path: []const u8, options: SymLinkOptions) SymLinkError!Reached {
    return linkAs(.report, io, dir, target, sub_path, options);
}

/// `symLink`, but a filesystem that refuses the directory sync ordering
/// the link before its name is `error.LevelUnavailable`, and nothing is
/// renamed.
pub fn symLinkOrRefuse(io: Io, dir: Io.Dir, target: []const u8, sub_path: []const u8, options: SymLinkOptions) SymLinkOrRefuseError!Reached {
    return linkAs(.refuse, io, dir, target, sub_path, options);
}

fn LinkError(comptime fallback: Fallback) type {
    return if (fallback == .refuse) SymLinkOrRefuseError else SymLinkError;
}

fn linkAs(comptime fallback: Fallback, io: Io, dir: Io.Dir, target: []const u8, sub_path: []const u8, options: SymLinkOptions) LinkError(fallback)!Reached {
    if (is_windows) return error.OperationUnsupported;
    const base_start = Staged.baseStart(sub_path);
    const base = sub_path[base_start..];
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.BadPathName;
    if (options.temp_prefix.len > Staged.max_prefix or Staged.baseStart(options.temp_prefix) != 0) return error.BadPathName;
    var parent = try Parent.open(io, dir, sub_path);
    defer parent.close(io);
    var buffer: [64]u8 = undefined;
    var temp: []const u8 = undefined;
    var draws: u32 = 0;
    while (true) {
        temp = buffer[0..Staged.drawName(io, options.temp_prefix, &buffer)];
        sys.symLink(io, target, parent.dir.handle, temp) catch |err| switch (err) {
            error.PathAlreadyExists => {
                draws += 1;
                if (draws < 4) continue;
                return err;
            },
            else => |e| return e,
        };
        break;
    }
    const level = options.sync.level;
    var reached: Reached = .none;
    if (level != .none) {
        // The link before its name: once renamed, a crash must not find the
        // name over a link that never reached the disk. A filesystem that
        // refuses the sync leaves no such order, so it is refused, or
        // reported, before the rename.
        reached = linkSync(fallback, io, options.sync.blocking, parent.dir) catch |err| {
            // ziglint-ignore: Z026 cleanup after a failure the caller already gets
            sys.unlink(io, parent.dir.handle, temp) catch {};
            return err;
        };
    }
    sys.rename(io, parent.dir.handle, temp, parent.dir.handle, base) catch |err| {
        // ziglint-ignore: Z026 cleanup after a failure the caller already gets
        sys.unlink(io, parent.dir.handle, temp) catch {};
        return err;
    };
    if (@backingInt(level) < @backingInt(Level.data)) return reached;
    const second = syncOne(io, options.sync.blocking, parent.dir, platform.default_busy_deadline) catch |err| return notDurable(options.diagnostics, err);
    return if (reached.atLeast(.ordered)) second else reached;
}

/// The sync that makes a new link durable before its rename: `.ordered`
/// when it did, what it reached when the filesystem refused it.
fn linkSync(comptime fallback: Fallback, io: Io, blocking: ?Blocking, dir: Io.Dir) LinkError(fallback)!Reached {
    const outcome = try platform.dirSync(io, blocking, dir.handle, platform.default_busy_deadline, null);
    if (outcome.refused) {
        if (fallback == .refuse) return error.LevelUnavailable;
        return Reached.min(outcome.reached, .written);
    }
    return .ordered;
}

// ---------------------------------------------------------------------
// Leftover temps
// ---------------------------------------------------------------------

pub const PruneOptions = struct {
    /// Only temps last modified at least this long ago go, so the temps
    /// another process is writing now stay.
    older_than: Io.Duration = .fromSeconds(3600),
};

pub const PruneError = Io.Dir.Iterator.Error || Io.Dir.StatFileError || Io.Dir.DeleteFileError;

/// Removes the random temps a crash or a kill left in `dir`: the names
/// `prefix` and 26 base32 characters, as `Temp.random` draws them, and
/// nothing else, last modified at least `older_than` ago. Returns how many
/// went. `dir` must be open for iteration. The removals are not synced: a
/// temp that comes back after a crash goes on the next prune.
pub fn pruneTemps(io: Io, dir: Io.Dir, prefix: []const u8, options: PruneOptions) PruneError!u32 {
    if (prefix.len > Staged.max_prefix or Staged.baseStart(prefix) != 0) return error.BadPathName;
    const now = Io.Timestamp.now(io, .real);
    var removed: u32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!Staged.isRandomName(entry.name, prefix)) continue;
        const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            // Committed or pruned by someone else since the listing.
            error.FileNotFound => continue,
            else => |e| return e,
        };
        if (now.nanoseconds - stat.mtime.nanoseconds < options.older_than.nanoseconds) continue;
        sys.unlink(io, dir.handle, entry.name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        removed += 1;
    }
    return removed;
}

/// The directory that holds `sub_path`: `dir` itself, or its nested
/// directory opened for the sync.
const Parent = struct {
    dir: Io.Dir,
    owned: bool,

    fn open(io: Io, dir: Io.Dir, sub_path: []const u8) Io.Dir.OpenError!Parent {
        const base_start = Staged.baseStart(sub_path);
        if (base_start == 0) return .{ .dir = dir, .owned = false };
        return .{ .dir = .{ .handle = try sys.openDir(io, dir.handle, Staged.parentPath(sub_path, base_start)) }, .owned = true };
    }

    fn close(p: *Parent, io: Io) void {
        if (p.owned) sys.release(io, p.dir.handle);
        p.owned = false;
    }
};

/// One directory's sync after a name changed in it: a refusal leaves the
/// change `.ordered`.
fn syncOne(io: Io, blocking: ?Blocking, dir: Io.Dir, busy: Io.Duration) platform.DirSyncError!Reached {
    const outcome = try platform.dirSync(io, blocking, dir.handle, busy, null);
    return if (outcome.refused) .ordered else outcome.reached;
}

fn sameDirectory(io: Io, a: Io.Dir, b: Io.Dir) Io.File.StatError!bool {
    if (a.handle == b.handle) return true;
    if (!is_windows and (a.handle == sys.at_fdcwd or b.handle == sys.at_fdcwd)) return false;
    const x = try sys.statId(io, a.handle);
    const y = try sys.statId(io, b.handle);
    return x.volume == y.volume and x.file == y.file;
}

test "a path's components are found from the end" {
    try std.testing.expectEqual(@as(usize, 1), previousSeparator("a/b", 3));
    try std.testing.expectEqual(@as(usize, 0), previousSeparator("a/b", 1));
    try std.testing.expectEqual(@as(usize, 1), previousSeparator("a//b", 4));
    try std.testing.expectEqual(@as(usize, 0), previousSeparator("abc", 3));
}
