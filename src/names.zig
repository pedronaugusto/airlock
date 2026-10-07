//! Renames and removals with the directory syncs that make them durable.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("sys.zig");
const platform = @import("platform.zig");
const level_mod = @import("level.zig");
const Level = level_mod.Level;
const Reached = level_mod.Reached;
const SyncOptions = level_mod.SyncOptions;

const is_windows = builtin.os.tag == .windows;

pub const RenameOptions = struct {
    sync: SyncOptions = .{},
    /// Windows: how long to retry a rename a scanner or indexer is
    /// blocking. 0 = once.
    busy_deadline: Io.Duration = .fromMilliseconds(2000),
};

pub const RenameError = Io.Dir.RenameError || platform.DirSyncError;

/// Renames `old` (relative to `old_dir`) to `new` (relative to `new_dir`),
/// replacing `new` if it exists, then syncs the directory that holds `new`
/// and, when it is a different one, the directory that held `old`: on a
/// filesystem that does not journal both entries together a crash must not
/// leave both names or neither.
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn rename(io: Io, old_dir: Io.Dir, old: []const u8, new_dir: Io.Dir, new: []const u8, options: RenameOptions) RenameError!Reached {
    if (is_windows) {
        try renameWindows(io, old_dir, old, new_dir, new, options.busy_deadline);
    } else {
        try sys.rename(io, old_dir.handle, old, new_dir.handle, new);
    }
    if (@backingInt(options.sync.level) < @backingInt(Level.data)) return .none;
    var new_parent = try Parent.open(io, new_dir, new);
    defer new_parent.close(io);
    var old_parent = try Parent.open(io, old_dir, old);
    defer old_parent.close(io);
    var reached = try syncOne(io, new_parent.dir, options);
    if (!try sameDirectory(io, new_parent.dir, old_parent.dir)) {
        reached = Reached.min(reached, try syncOne(io, old_parent.dir, options));
    }
    return reached;
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

pub const RemoveError = Io.Dir.DeleteFileError || platform.DirSyncError;

/// Removes the file `sub_path` names relative to `dir`, then syncs the
/// directory that held it. On Windows the delete has POSIX semantics: the
/// name goes at once, even while another process holds the file open.
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn remove(io: Io, dir: Io.Dir, sub_path: []const u8, options: RenameOptions) RemoveError!Reached {
    try sys.unlink(io, dir.handle, sub_path);
    if (@backingInt(options.sync.level) < @backingInt(Level.data)) return .none;
    var parent = try Parent.open(io, dir, sub_path);
    defer parent.close(io);
    return syncOne(io, parent.dir, options);
}

/// The directory that holds `sub_path`: `dir` itself, or its nested
/// directory opened for the sync.
const Parent = struct {
    dir: Io.Dir,
    owned: bool,

    fn open(io: Io, dir: Io.Dir, sub_path: []const u8) Io.Dir.OpenError!Parent {
        var i = sub_path.len;
        while (i > 0) : (i -= 1) {
            const c = sub_path[i - 1];
            if (c == '/' or (is_windows and c == '\\')) break;
        }
        if (i == 0) return .{ .dir = dir, .owned = false };
        const path = if (i == 1) sub_path[0..1] else sub_path[0 .. i - 1];
        return .{ .dir = .{ .handle = try sys.openDir(io, dir.handle, path) }, .owned = true };
    }

    fn close(p: *Parent, io: Io) void {
        if (p.owned) sys.release(io, p.dir.handle);
    }
};

fn syncOne(io: Io, dir: Io.Dir, options: RenameOptions) platform.DirSyncError!Reached {
    const outcome = try platform.dirSync(io, dir.handle, options.sync.barrier, options.busy_deadline, null);
    if (outcome.refused) {
        if (options.sync.fallback == .refuse) return error.LevelUnavailable;
        return .ordered;
    }
    return platform.decide(outcome.reached, options.sync.level, options.sync.fallback);
}

fn sameDirectory(io: Io, a: Io.Dir, b: Io.Dir) Io.File.StatError!bool {
    if (a.handle == b.handle) return true;
    if (!is_windows and (a.handle == sys.at_fdcwd or b.handle == sys.at_fdcwd)) return false;
    const x = try sys.statId(io, a.handle);
    const y = try sys.statId(io, b.handle);
    return x.volume == y.volume and x.file == y.file;
}
