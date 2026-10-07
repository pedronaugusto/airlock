//! Every raw call airlock makes, and the test seam in front of each one.
//!
//! std's `File.sync` cannot carry what a durable write needs: it has no
//! data-only or barrier forms, and `Threaded` treats `EINVAL`, `EROFS` and
//! `EBADF` from `fsync` as programming errors. So every sync, rename,
//! unlink, close and identity call goes through this file, which maps each
//! code to an error and tells a refusal (the filesystem cannot be asked)
//! apart from a failure (the bytes did not get down).
//!
//! The seam (`seam.zig`) decides each call first when the `Io` carries a
//! test's hook; production pays one function-pointer compare per call.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const windows = std.os.windows;

const native_os = builtin.target.os.tag;
const is_windows = native_os == .windows;
const is_linux = native_os == .linux;
const is_darwin = native_os.isDarwin();

const seam = @import("seam");

pub const Call = seam.Call;
const Code = seam.Code;
const intercept = seam.intercept;

/// A failure code the hook injects in place of `call`, or null to run it.
fn injected(io: Io, call: Call, path: ?[]const u8) Io.Cancelable!?Code {
    const result = intercept(io, call, path) orelse return null;
    return switch (result) {
        .code => |c| if (c == success) null else c,
        .canceled => error.Canceled,
        .value => null,
    };
}

const success: Code = .SUCCESS;

pub const Handle = if (is_windows) windows.HANDLE else posix.fd_t;

/// The filesystem cannot be asked for this call. Internal: callers turn it
/// into a fallback or `error.LevelUnavailable`.
pub const Refused = error{Refused};

/// A sync's failures, as std names them, plus a refusal.
pub const SyncError = Io.File.SyncError || Refused;

// ---------------------------------------------------------------------
// POSIX
// ---------------------------------------------------------------------

/// The errno of a raw call's return value.
fn errnoOf(rc: anytype) posix.E {
    return if (is_linux) linux.errno(rc) else std.c.errno(rc);
}

/// Runs `f` until it is not interrupted, honouring a cancel between tries.
/// The hook decides each try first.
fn retrying(io: Io, call: Call, path: ?[]const u8, comptime f: anytype, args: anytype) Io.Cancelable!posix.E {
    while (true) {
        try io.checkCancel();
        const code: posix.E = (try injected(io, call, path)) orelse errnoOf(@call(.auto, f, args));
        if (code != .INTR) return code;
    }
}

fn isNotSupported(e: posix.E) bool {
    // Darwin's EOPNOTSUPP (102) is not in std's table; ENOTSUP (45) is
    // spelled OPNOTSUPP there.
    return e == .OPNOTSUPP or @backingInt(e) == 102;
}

fn syncFailure(e: posix.E) Io.File.SyncError {
    return switch (e) {
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .ACCES, .PERM => error.AccessDenied,
        else => posix.unexpectedErrno(e),
    };
}

const darwin_full_fsync = if (is_darwin) std.c.F.FULLFSYNC else 0;
const darwin_barrier_fsync = if (is_darwin) std.c.F.BARRIERFSYNC else 0;

fn darwinFcntl(fd: posix.fd_t, cmd: c_int) c_int {
    return std.c.fcntl(fd, cmd, @as(c_int, 0));
}

fn cFsync(fd: posix.fd_t) c_int {
    return std.c.fsync(fd);
}

/// Darwin `F_FULLFSYNC`: the device writes its cache down.
pub fn fullFsync(io: Io, fd: posix.fd_t, call: Call, path: ?[]const u8) SyncError!void {
    const e = try retrying(io, call, path, darwinFcntl, .{ fd, darwin_full_fsync });
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .NOTTY, .PERM => error.Refused,
        else => if (isNotSupported(e)) error.Refused else syncFailure(e),
    };
}

/// Darwin `F_BARRIERFSYNC`: everything handed to the device before it is
/// written before anything after it.
pub fn barrierFsync(io: Io, fd: posix.fd_t, path: ?[]const u8) SyncError!void {
    const e = try retrying(io, .sync_barrier, path, darwinFcntl, .{ fd, darwin_barrier_fsync });
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .NOTTY, .PERM => error.Refused,
        else => if (isNotSupported(e)) error.Refused else syncFailure(e),
    };
}

/// Plain `fsync` on Darwin and the BSDs: a writeout, or the end of a chain.
pub fn plainFsync(io: Io, fd: posix.fd_t, call: Call, path: ?[]const u8) SyncError!void {
    const e = if (is_linux)
        try retrying(io, call, path, linux.fsync, .{fd})
    else
        try retrying(io, call, path, cFsync, .{fd});
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .ROFS => error.Refused,
        else => if (isNotSupported(e)) error.Refused else syncFailure(e),
    };
}

/// Linux `fdatasync`.
pub fn dataFsync(io: Io, fd: posix.fd_t, path: ?[]const u8) SyncError!void {
    const e = try retrying(io, .sync_data, path, linux.fdatasync, .{fd});
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .ROFS, .NOSYS => error.Refused,
        else => syncFailure(e),
    };
}

/// Linux `fsync` on a file, as the full sync.
pub fn linuxFsync(io: Io, fd: posix.fd_t, call: Call, path: ?[]const u8) (SyncError || error{BadHandle})!void {
    const e = try retrying(io, call, path, linux.fsync, .{fd});
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .ROFS => error.Refused,
        .BADF => error.BadHandle,
        else => syncFailure(e),
    };
}

fn linuxGetfl(fd: posix.fd_t) usize {
    return linux.fcntl(fd, linux.F.GETFL, 0);
}

/// Linux: whether `fd` is an `O_PATH` handle (or `AT_FDCWD`), which a
/// directory sync must reopen. Any other answer means the handle is bad.
pub fn isPathOnly(io: Io, fd: posix.fd_t) Io.Cancelable!bool {
    if (fd == linux.AT.FDCWD) return true;
    while (true) {
        try io.checkCancel();
        if (try injected(io, .getfl, null)) |code| {
            if (code == .INTR) continue;
            return false;
        }
        const rc = linuxGetfl(fd);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const flags: linux.O = @bitCast(@as(u32, @truncate(rc))); // safe: F_GETFL returns the open flags in the low 32 bits
                return flags.PATH;
            },
            .INTR => continue,
            else => return false,
        }
    }
}

/// Linux `sync_file_range(SYNC_FILE_RANGE_WRITE)`: start writeback early.
pub fn writeback(io: Io, fd: posix.fd_t, offset: u64, len: u64) Io.File.SyncError!void {
    if (!is_linux or !@hasField(linux.SYS, "sync_file_range")) return;
    const e = try retrying(io, .writeback, null, syncFileRange, .{ fd, offset, len });
    return switch (e) {
        .SUCCESS => {},
        // A filesystem without writeback control: the final sync does it all.
        .INVAL, .NOSYS, .SPIPE => {},
        else => syncFailure(e),
    };
}

fn syncFileRange(fd: posix.fd_t, offset: u64, len: u64) usize {
    const write_flag = 2; // SYNC_FILE_RANGE_WRITE
    return linux.syscall4(.sync_file_range, @bitCast(@as(isize, fd)), offset, len, write_flag); // safe: a descriptor is a non-negative int; offsets are bit-preserved
}

/// `close`, exactly once. EINTR means closed: Linux releases the descriptor
/// whatever `close` returns, so a second call could close another thread's
/// file. EIO (an NFS deferred write) is a failed sync.
pub fn close(io: Io, handle: Handle, path: ?[]const u8) Io.File.SyncError!void {
    if (is_windows) return closeWindows(io, handle, path);
    const e: posix.E = if (injected(io, .close, path) catch null) |code| blk: {
        // The hook decided what close says; the real descriptor still goes,
        // exactly once.
        closeQuietly(handle);
        break :blk code;
    } else if (is_linux)
        linux.errno(linux.close(handle))
    else
        std.c.errno(std.c.close(handle));
    return switch (e) {
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        // EINTR: Linux released the descriptor anyway; it is closed.
        else => {},
    };
}

/// Close a descriptor that `close` reported on through the hook only.
fn closeQuietly(handle: Handle) void {
    if (is_linux) {
        _ = linux.close(handle);
    } else if (!is_windows) {
        _ = std.c.close(handle);
    }
}

/// `close` where its answer changes nothing: a handle being dropped after
/// another failure, or one airlock only read through.
pub fn release(io: Io, handle: Handle) void {
    // ziglint-ignore: Z026 a handle dropped after another failure; that failure is the one the caller gets
    close(io, handle, null) catch {};
}

fn openatRaw(dir: posix.fd_t, path: [*:0]const u8, flags: posix.O, mode: posix.mode_t) if (is_linux) usize else c_int {
    if (is_linux) return linux.openat(dir, path, flags, mode);
    return std.c.openat(dir, path, flags, mode);
}

pub const OpenDirError = Io.Dir.OpenError;

/// A directory opened read-only so it can be synced and named relative to:
/// `openat(O_RDONLY | O_DIRECTORY | O_CLOEXEC)`, never `O_PATH`.
pub fn openDir(io: Io, dir: Handle, sub_path: []const u8) OpenDirError!Handle {
    if (is_windows) return openDirWindows(io, dir, sub_path, false);
    const path = try posix.toPosixPath(sub_path);
    var flags: posix.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    flags.DIRECTORY = true;
    while (true) {
        try io.checkCancel();
        if (try injected(io, .open_dir, sub_path)) |code| {
            if (code == .INTR) continue;
            return openDirFailure(code);
        }
        const rc = openatRaw(dir, &path, flags, 0);
        const e = errnoOf(rc);
        switch (e) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return openDirFailure(e),
        }
    }
}

fn openDirFailure(e: posix.E) OpenDirError {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .LOOP => error.SymLinkLoop,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV => error.NoDevice,
        .NOMEM => error.SystemResources,
        .NAMETOOLONG => error.NameTooLong,
        else => posix.unexpectedErrno(e),
    };
}

pub const OpenFileError = Io.File.OpenError;

/// An existing file opened to be synced: read-only on POSIX, for write on
/// Windows (a flush needs write access; a read-only file has its attribute
/// cleared for the open and put back).
pub fn openFile(io: Io, dir: Handle, sub_path: []const u8) OpenFileError!Handle {
    if (is_windows) return openFileWindows(io, dir, sub_path, .sync);
    const path = try posix.toPosixPath(sub_path);
    const flags: posix.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    while (true) {
        try io.checkCancel();
        if (try injected(io, .open_file, sub_path)) |code| {
            if (code == .INTR) continue;
            return openFileFailure(code);
        }
        const rc = openatRaw(dir, &path, flags, 0);
        const e = errnoOf(rc);
        switch (e) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return openFileFailure(e),
        }
    }
}

fn openFileFailure(e: posix.E) OpenFileError {
    return switch (e) {
        .EXIST => error.PathAlreadyExists,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .LOOP => error.SymLinkLoop,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV, .NXIO => error.NoDevice,
        .NOMEM => error.SystemResources,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        .TXTBSY => error.FileBusy,
        .BUSY => error.DeviceBusy,
        .FBIG, .OVERFLOW => error.FileTooBig,
        .AGAIN => error.WouldBlock,
        else => posix.unexpectedErrno(e),
    };
}

pub const CreateTempError = Io.File.OpenError || error{Busy};

/// Exclusive create of `name` in `dir`: `O_CREAT | O_EXCL`, so an existing
/// name is never clobbered. Windows: share read and delete only, with
/// delete access held, so a scanner can never block the rename.
pub fn createTemp(io: Io, dir: Handle, name: []const u8, mode: Io.File.Permissions, read: bool) CreateTempError!Handle {
    if (is_windows) return createTempWindows(io, dir, name, read);
    const path = try posix.toPosixPath(name);
    var flags: posix.O = .{ .ACCMODE = if (read) .RDWR else .WRONLY, .CLOEXEC = true };
    flags.CREAT = true;
    flags.EXCL = true;
    while (true) {
        try io.checkCancel();
        if (try injected(io, .create_temp, name)) |code| {
            if (code == .INTR) continue;
            return openFileFailure(code);
        }
        const rc = openatRaw(dir, &path, flags, mode.toMode());
        const e = errnoOf(rc);
        switch (e) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return openFileFailure(e),
        }
    }
}

/// Permissions on the open handle: `fchmod`, so umask does not apply and
/// there is no window between a stat and a chmod of the path.
pub fn setMode(io: Io, handle: Handle, mode: Io.File.Permissions) Io.File.SetPermissionsError!void {
    if (is_windows) return setReadOnlyWindows(io, handle, isReadOnly(mode));
    const fchmod = if (is_linux) linux.fchmod else std.c.fchmod;
    const e = try retrying(io, .set_mode, null, fchmod, .{ handle, mode.toMode() });
    return switch (e) {
        .SUCCESS => {},
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .IO => error.InputOutput,
        .LOOP => error.SymLinkLoop,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .ROFS => error.ReadOnlyFileSystem,
        else => posix.unexpectedErrno(e),
    };
}

fn isReadOnly(mode: Io.File.Permissions) bool {
    if (is_windows) return @backingInt(mode) & 1 != 0; // FILE_ATTRIBUTE_READONLY
    return mode.readOnly();
}

pub const RenameError = Io.Dir.RenameError;

fn renameatRaw(old_dir: posix.fd_t, old: [*:0]const u8, new_dir: posix.fd_t, new: [*:0]const u8) if (is_linux) usize else c_int {
    if (is_linux) return linux.renameat(old_dir, old, new_dir, new);
    return std.c.renameat(old_dir, old, new_dir, new);
}

/// `renameat`: replaces `new` if it exists.
pub fn rename(io: Io, old_dir: Handle, old: []const u8, new_dir: Handle, new: []const u8) RenameError!void {
    const old_z = try posix.toPosixPath(old);
    const new_z = try posix.toPosixPath(new);
    const e = try retrying(io, .rename, new, renameatRaw, .{ old_dir, &old_z, new_dir, &new_z });
    if (e != .SUCCESS) return renameFailure(e);
}

fn renameFailure(e: posix.E) RenameError {
    return switch (e) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .BUSY, .TXTBSY => error.FileBusy,
        .DQUOT => error.DiskQuota,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .MLINK => error.LinkQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NOMEM => error.SystemResources,
        .NOSPC => error.NoSpaceLeft,
        .EXIST, .NOTEMPTY => error.DirNotEmpty,
        .ROFS => error.ReadOnlyFileSystem,
        .XDEV => error.CrossDevice,
        .IO => error.HardwareFailure,
        else => posix.unexpectedErrno(e),
    };
}

fn renameNoReplaceRaw(old_dir: posix.fd_t, old: [*:0]const u8, new_dir: posix.fd_t, new: [*:0]const u8) if (is_linux) usize else c_int {
    if (is_linux) return linux.renameat2(old_dir, old, new_dir, new, .{ .NOREPLACE = true });
    if (is_darwin) return std.c.renameatx_np(old_dir, old, new_dir, new, .{ .EXCL = true });
    // No atomic no-replace rename here: the link fallback does it.
    return -1;
}

/// A rename that fails with `error.AlreadyExists` rather than replace.
/// `error.Refused` where the filesystem has no such rename.
pub fn renameNoReplace(io: Io, old_dir: Handle, old: []const u8, new_dir: Handle, new: []const u8) (RenameError || Refused || error{AlreadyExists})!void {
    if (!is_linux and !is_darwin) return error.Refused;
    const old_z = try posix.toPosixPath(old);
    const new_z = try posix.toPosixPath(new);
    const e = try retrying(io, .rename_noreplace, new, renameNoReplaceRaw, .{ old_dir, &old_z, new_dir, &new_z });
    return switch (e) {
        .SUCCESS => {},
        .EXIST => error.AlreadyExists,
        .INVAL, .NOSYS => error.Refused,
        else => if (isNotSupported(e)) error.Refused else renameFailure(e),
    };
}

fn linkatRaw(old_dir: posix.fd_t, old: [*:0]const u8, new_dir: posix.fd_t, new: [*:0]const u8) if (is_linux) usize else c_int {
    if (is_linux) return linux.linkat(old_dir, old, new_dir, new, 0);
    return std.c.linkat(old_dir, old, new_dir, new, 0);
}

/// `linkat`, the fallback for a rename that must not replace. Refused on
/// filesystems without hard links (exFAT, FAT, some SMB).
pub fn link(io: Io, old_dir: Handle, old: []const u8, new_dir: Handle, new: []const u8) (RenameError || Refused || error{AlreadyExists})!void {
    const old_z = try posix.toPosixPath(old);
    const new_z = try posix.toPosixPath(new);
    const e = try retrying(io, .link, new, linkatRaw, .{ old_dir, &old_z, new_dir, &new_z });
    return switch (e) {
        .SUCCESS => {},
        .EXIST => error.AlreadyExists,
        .PERM => error.Refused,
        else => if (isNotSupported(e)) error.Refused else renameFailure(e),
    };
}

pub const UnlinkError = Io.Dir.DeleteFileError;

fn unlinkatRaw(dir: posix.fd_t, path: [*:0]const u8) if (is_linux) usize else c_int {
    if (is_linux) return linux.unlinkat(dir, path, 0);
    return std.c.unlinkat(dir, path, 0);
}

/// `unlinkat` of a file.
pub fn unlink(io: Io, dir: Handle, name: []const u8) UnlinkError!void {
    if (is_windows) return unlinkWindows(io, dir, name);
    const path = try posix.toPosixPath(name);
    const e = try retrying(io, .unlink, name, unlinkatRaw, .{ dir, &path });
    return switch (e) {
        .SUCCESS => {},
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .BUSY => error.FileBusy,
        .IO => error.FileSystem,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.NotDir,
        .NOMEM => error.SystemResources,
        .ROFS => error.ReadOnlyFileSystem,
        else => posix.unexpectedErrno(e),
    };
}

pub const MakeDirError = Io.Dir.CreateDirError;

fn mkdiratRaw(dir: posix.fd_t, path: [*:0]const u8, mode: posix.mode_t) if (is_linux) usize else c_int {
    if (is_linux) return linux.mkdirat(dir, path, mode);
    return std.c.mkdirat(dir, path, mode);
}

/// `mkdirat(name, 0777)`: umask applies. Windows creates it by name.
pub fn makeDir(io: Io, dir: Handle, name: []const u8) MakeDirError!void {
    if (is_windows) return makeDirWindows(io, dir, name);
    const path = try posix.toPosixPath(name);
    const e = try retrying(io, .make_dir, name, mkdiratRaw, .{ dir, &path, 0o777 });
    return switch (e) {
        .SUCCESS => {},
        .EXIST => error.PathAlreadyExists,
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .DQUOT => error.DiskQuota,
        .LOOP => error.SymLinkLoop,
        .MLINK => error.LinkQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .ROFS => error.ReadOnlyFileSystem,
        else => posix.unexpectedErrno(e),
    };
}

pub const SymLinkError = Io.Dir.SymLinkError || error{OperationUnsupported};

fn symlinkatRaw(target: [*:0]const u8, dir: posix.fd_t, path: [*:0]const u8) if (is_linux) usize else c_int {
    if (is_linux) return linux.symlinkat(target, dir, path);
    return std.c.symlinkat(target, dir, path);
}

/// `symlinkat(target, dir, name)`. Windows: `error.OperationUnsupported`,
/// since creating a symbolic link there needs a privilege or developer
/// mode.
pub fn symLink(io: Io, target: []const u8, dir: Handle, name: []const u8) SymLinkError!void {
    if (is_windows) return error.OperationUnsupported;
    const target_z = try posix.toPosixPath(target);
    const path = try posix.toPosixPath(name);
    const e = try retrying(io, .symlink, name, symlinkatRaw, .{ &target_z, dir, &path });
    return switch (e) {
        .SUCCESS => {},
        .EXIST => error.PathAlreadyExists,
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .DQUOT => error.DiskQuota,
        .IO => error.FileSystem,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .ROFS => error.ReadOnlyFileSystem,
        else => posix.unexpectedErrno(e),
    };
}

/// A file's identity as the filesystem numbers it.
pub const Id = struct { volume: u64, file: u128 };

pub const StatIdError = Io.File.StatError;
pub const StatPathError = Io.Dir.StatFileError;

/// The bits of a `dev_t` or `ino_t`, whichever sign and width the platform
/// gives it: Darwin's device number is an `i32`.
fn unsigned(x: anytype) u64 {
    const bits_type = @Int(.unsigned, @bitSizeOf(@TypeOf(x)));
    return @as(bits_type, @bitCast(x)); // safe: reinterprets the same bits as unsigned
}

/// A Linux device as one number: the major and the minor both, since two
/// volumes can share either.
pub fn linuxVolume(major: u32, minor: u32) u64 {
    return (@as(u64, major) << 32) | minor;
}

fn statxRaw(dir: posix.fd_t, path: [*:0]const u8, flags: u32, buf: *linux.Statx) usize {
    return linux.statx(dir, path, flags, .{ .INO = true }, buf);
}

fn fstatRaw(fd: posix.fd_t, buf: *posix.Stat) c_int {
    return std.c.fstat(fd, buf);
}

fn fstatatRaw(dir: posix.fd_t, path: [*:0]const u8, buf: *posix.Stat, flags: u32) c_int {
    return std.c.fstatat(dir, path, buf, flags);
}

/// The identity of an open handle.
pub fn statId(io: Io, handle: Handle) StatIdError!Id {
    if (is_windows) return statIdWindows(io, handle);
    if (is_linux) {
        var buf = std.mem.zeroes(linux.Statx);
        const e = try retrying(io, .stat_id, null, statxRaw, .{ handle, "", linux.AT.EMPTY_PATH, &buf });
        if (e != .SUCCESS) return statFailure(e);
        if (!buf.mask.INO) return error.Unexpected;
        return .{ .volume = linuxVolume(buf.dev_major, buf.dev_minor), .file = buf.ino };
    }
    var buf = std.mem.zeroes(posix.Stat);
    const e = try retrying(io, .stat_id, null, fstatRaw, .{ handle, &buf });
    if (e != .SUCCESS) return statFailure(e);
    return .{ .volume = unsigned(buf.dev), .file = unsigned(buf.ino) };
}

fn statFailure(e: posix.E) StatIdError {
    return switch (e) {
        .NOMEM => error.SystemResources,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        else => posix.unexpectedErrno(e),
    };
}

/// The identity of what `sub_path` names relative to `dir`, without
/// opening it, so a socket has one too.
pub fn statIdPath(io: Io, dir: Handle, sub_path: []const u8, follow: bool) StatPathError!Id {
    if (is_windows) return statIdPathWindows(io, dir, sub_path, follow);
    const path = try posix.toPosixPath(sub_path);
    if (is_linux) {
        var buf = std.mem.zeroes(linux.Statx);
        const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
        const e = try retrying(io, .stat_id, sub_path, statxRaw, .{ dir, &path, flags, &buf });
        if (e != .SUCCESS) return statPathFailure(e);
        if (!buf.mask.INO) return error.Unexpected;
        return .{ .volume = linuxVolume(buf.dev_major, buf.dev_minor), .file = buf.ino };
    }
    var buf = std.mem.zeroes(posix.Stat);
    const flags: u32 = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    const e = try retrying(io, .stat_id, sub_path, fstatatRaw, .{ dir, &path, &buf, flags });
    if (e != .SUCCESS) return statPathFailure(e);
    return .{ .volume = unsigned(buf.dev), .file = unsigned(buf.ino) };
}

fn statPathFailure(e: posix.E) StatPathError {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        else => posix.unexpectedErrno(e),
    };
}

/// Whether a name exists in `dir`, by `fstatat` without following links.
pub fn exists(io: Io, dir: Handle, name: []const u8) StatPathError!bool {
    _ = statIdPath(io, dir, name, false) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

pub const at_fdcwd: Handle = if (is_windows) undefined else posix.AT.FDCWD;

// ---------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------

const flush_data_sync_only: u32 = 0x4; // FLUSH_FLAGS_FILE_DATA_SYNC_ONLY
const flush_no_sync: u32 = 0x2; // FLUSH_FLAGS_NO_SYNC

/// The flags of `NtFlushBuffersFileEx` airlock uses.
pub const FlushEx = enum(u32) {
    /// Contents and what it takes to read them, and the device cache.
    data_sync_only = flush_data_sync_only,
    /// Written out to the device without flushing its cache.
    no_sync = flush_no_sync,
};

extern "ntdll" fn NtFlushBuffersFileEx(
    FileHandle: windows.HANDLE,
    Flags: windows.ULONG,
    Parameters: ?*anyopaque,
    ParametersSize: windows.ULONG,
    IoStatusBlock: *windows.IO_STATUS_BLOCK,
) callconv(.winapi) windows.NTSTATUS;

/// Runs `f` until it is not cancelled by an APC, honouring a cancel
/// between tries. The hook decides each try first.
fn retryingNt(io: Io, call: Call, path: ?[]const u8, comptime f: anytype, args: anytype) Io.Cancelable!windows.NTSTATUS {
    while (true) {
        try io.checkCancel();
        const status: windows.NTSTATUS = (try injected(io, call, path)) orelse @call(.auto, f, args);
        if (status != .CANCELLED) return status;
    }
}

fn ntSyncFailure(status: windows.NTSTATUS) Io.File.SyncError {
    return switch (status) {
        .ACCESS_DENIED => error.AccessDenied,
        .DISK_FULL => error.NoSpaceLeft,
        .QUOTA_EXCEEDED => error.DiskQuota,
        .UNEXPECTED_NETWORK_ERROR, .DEVICE_DATA_ERROR, .DATA_ERROR, .IO_DEVICE_ERROR, .FILE_CORRUPT_ERROR => error.InputOutput,
        else => windows.unexpectedStatus(status),
    };
}

fn isRefusalNt(status: windows.NTSTATUS) bool {
    return status == .INVALID_PARAMETER or status == .NOT_SUPPORTED or status == .INVALID_DEVICE_REQUEST;
}

fn ntFlush(handle: windows.HANDLE) windows.NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtFlushBuffersFile(handle, &iosb);
}

fn ntFlushEx(handle: windows.HANDLE, flags: u32) windows.NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return NtFlushBuffersFileEx(handle, flags, null, 0, &iosb);
}

/// `NtFlushBuffersFile`: contents, metadata and the device cache.
pub fn flushWindows(io: Io, handle: windows.HANDLE, call: Call, path: ?[]const u8) SyncError!void {
    const status = try retryingNt(io, call, path, ntFlush, .{handle});
    if (status == .SUCCESS) return;
    if (status == .NOT_SUPPORTED or status == .INVALID_DEVICE_REQUEST) return error.Refused;
    return ntSyncFailure(status);
}

/// `NtFlushBuffersFileEx` with one flag. Refused outside NTFS (and for
/// `no_sync`, FAT and exFAT): ReFS, redirectors.
pub fn flushExWindows(io: Io, handle: windows.HANDLE, flag: FlushEx, path: ?[]const u8) SyncError!void {
    const call: Call = switch (flag) {
        .data_sync_only => .sync_data,
        .no_sync => .sync_writeout,
    };
    const status = try retryingNt(io, call, path, ntFlushEx, .{ handle, @backingInt(flag) });
    if (status == .SUCCESS) return;
    if (isRefusalNt(status)) return error.Refused;
    return ntSyncFailure(status);
}

fn closeWindows(io: Io, handle: windows.HANDLE, path: ?[]const u8) Io.File.SyncError!void {
    _ = injected(io, .close, path) catch null;
    _ = windows.ntdll.NtClose(handle);
}

/// A name as NT wants it relative to `root`: WTF-16, slashes turned round.
fn ntName(root: windows.HANDLE, name: []const u8) Io.Dir.PathNameError!Io.Threaded.WindowsPathSpace {
    return Io.Threaded.sliceToPrefixedFileW(root, name, .{}) catch |err| switch (err) {
        error.NameTooLong => error.NameTooLong,
        else => error.BadPathName,
    };
}

fn ntCreate(
    handle: *windows.HANDLE,
    access: windows.ACCESS_MASK,
    attr: *const windows.OBJECT.ATTRIBUTES,
    attributes: windows.FILE.ATTRIBUTE,
    share: windows.FILE.SHARE,
    disposition: windows.FILE.CREATE_DISPOSITION,
    options: windows.FILE.MODE,
) windows.NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtCreateFile(handle, access, attr, &iosb, null, attributes, share, disposition, options, null, 0);
}

/// A directory opened relative to `root` (`sub_path` empty: `root` itself
/// again), with the rights a flush and relative opens need.
pub fn openDirWindows(io: Io, root: windows.HANDLE, sub_path: []const u8, flush_only: bool) OpenDirError!windows.HANDLE {
    var space: Io.Threaded.WindowsPathSpace = undefined;
    var name: windows.UNICODE_STRING = .init(&.{});
    var absolute = false;
    if (sub_path.len != 0) {
        space = try ntName(root, sub_path);
        name = space.string();
        absolute = Io.Dir.path.isAbsoluteWindowsWtf16(space.span());
    }
    const attr: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (absolute) null else root, .ObjectName = &name };
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE_DIRECTORY = .{
            .LIST = !flush_only,
            .ADD_FILE = true,
            .TRAVERSE = !flush_only,
            .READ_ATTRIBUTES = true,
        } },
    };
    var handle: windows.HANDLE = undefined;
    const status = try retryingNt(io, .open_dir, sub_path, ntCreate, .{
        &handle,                                                                  access,
        &attr,                                                                    windows.FILE.ATTRIBUTE{ .NORMAL = true },
        windows.FILE.SHARE.VALID_FLAGS,                                           windows.FILE.CREATE_DISPOSITION.OPEN,
        windows.FILE.MODE{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
    });
    return switch (status) {
        .SUCCESS => handle,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .NOT_A_DIRECTORY => error.NotDir,
        .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
        .OBJECT_NAME_INVALID => error.BadPathName,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => error.NetworkNotFound,
        .NOT_SUPPORTED, .INVALID_DEVICE_REQUEST => error.NoDevice,
        else => windows.unexpectedStatus(status),
    };
}

fn makeDirWindows(io: Io, root: windows.HANDLE, name: []const u8) MakeDirError!void {
    const space = try ntName(root, name);
    var nt = space.string();
    const absolute = Io.Dir.path.isAbsoluteWindowsWtf16(space.span());
    const attr: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (absolute) null else root, .ObjectName = &nt };
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true, .READ_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = try retryingNt(io, .make_dir, name, ntCreate, .{
        &handle,                                                                  access,
        &attr,                                                                    windows.FILE.ATTRIBUTE{ .NORMAL = true },
        windows.FILE.SHARE.VALID_FLAGS,                                           windows.FILE.CREATE_DISPOSITION.CREATE,
        windows.FILE.MODE{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
    });
    switch (status) {
        .SUCCESS => release(io, handle),
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .NOT_A_DIRECTORY => return error.NotDir,
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_NAME_INVALID => return error.BadPathName,
        .DISK_FULL => return error.NoSpaceLeft,
        .MEDIA_WRITE_PROTECTED => return error.ReadOnlyFileSystem,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => return error.NetworkNotFound,
        else => return windows.unexpectedStatus(status),
    }
}

/// What a Windows file open by name is for.
pub const OpenFor = enum { sync, delete, rename };

/// A file opened by name relative to `root`: for a flush (write access),
/// or for a delete or a rename by handle (delete access). A read-only file
/// opened for a flush is opened as `openReadOnlyForSync` says.
pub fn openFileWindows(io: Io, root: windows.HANDLE, sub_path: []const u8, purpose: OpenFor) OpenFileError!windows.HANDLE {
    return openByName(io, root, sub_path, purpose) catch |err| switch (err) {
        error.AccessDenied => if (purpose == .sync) openReadOnlyForSync(io, root, sub_path) else err,
        else => err,
    };
}

/// A read-only file opened for a flush, which needs write access (git's
/// and relic's loose objects are read-only): the attribute is cleared, the
/// file opened, and the attribute put back at once. Access is checked when
/// a handle is opened, so the handle keeps its write access. A file that
/// is not read-only was denied for a real reason, and stays denied.
fn openReadOnlyForSync(io: Io, root: windows.HANDLE, sub_path: []const u8) OpenFileError!windows.HANDLE {
    const attributes = try openAttributes(io, root, sub_path);
    defer release(io, attributes);
    const info = basicInformation(attributes) orelse return error.AccessDenied;
    if (!info.FileAttributes.READONLY) return error.AccessDenied;
    var writable = info.FileAttributes;
    writable.READONLY = false;
    if (try setAttributes(io, attributes, writable) != .SUCCESS) return error.AccessDenied;
    const opened = openByName(io, root, sub_path, .sync);
    const restored = setAttributes(io, attributes, info.FileAttributes) catch .CANCELLED;
    const handle = try opened;
    if (restored != .SUCCESS) {
        release(io, handle);
        return error.AccessDenied;
    }
    return handle;
}

/// Clears the read-only attribute of `name` in `root`, and says whether it
/// was set.
fn clearReadOnly(io: Io, root: windows.HANDLE, name: []const u8) bool {
    const attributes = openAttributes(io, root, name) catch return false;
    defer release(io, attributes);
    const info = basicInformation(attributes) orelse return false;
    if (!info.FileAttributes.READONLY) return false;
    var writable = info.FileAttributes;
    writable.READONLY = false;
    const status = setAttributes(io, attributes, writable) catch return false;
    return status == .SUCCESS;
}

/// A handle on `name` in `root` for its attributes alone, the link itself
/// if it is one.
fn openAttributes(io: Io, root: windows.HANDLE, name: []const u8) OpenFileError!windows.HANDLE {
    const space = try ntName(root, name);
    var nt = space.string();
    const absolute = Io.Dir.path.isAbsoluteWindowsWtf16(space.span());
    const attr: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (absolute) null else root, .ObjectName = &nt };
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = try retryingNt(io, .open_file, name, ntCreate, .{
        &handle,                                                                                                  access,
        &attr,                                                                                                    windows.FILE.ATTRIBUTE{ .NORMAL = true },
        windows.FILE.SHARE.VALID_FLAGS,                                                                           windows.FILE.CREATE_DISPOSITION.OPEN,
        windows.FILE.MODE{ .NON_DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true },
    });
    if (status != .SUCCESS) return openFailureNt(status);
    return handle;
}

fn basicInformation(handle: windows.HANDLE) ?windows.FILE.BASIC_INFORMATION {
    var info: windows.FILE.BASIC_INFORMATION = undefined;
    if (ntQueryInfo(handle, std.mem.asBytes(&info), .Basic) != .SUCCESS) return null;
    return info;
}

/// Sets `attributes` on `handle`; the times stay as they are.
fn setAttributes(io: Io, handle: windows.HANDLE, attributes: windows.FILE.ATTRIBUTE) Io.Cancelable!windows.NTSTATUS {
    var info: windows.FILE.BASIC_INFORMATION = .{
        .CreationTime = 0,
        .LastAccessTime = 0,
        .LastWriteTime = 0,
        .ChangeTime = 0,
        .FileAttributes = attributes,
    };
    // No attributes at all is spelled NORMAL.
    if (@as(u32, @bitCast(attributes)) == 0) info.FileAttributes = .{ .NORMAL = true };
    return retryingNt(io, .set_mode, null, ntSetInfo, .{ handle, std.mem.asBytes(&info), .Basic });
}

fn openByName(io: Io, root: windows.HANDLE, sub_path: []const u8, purpose: OpenFor) OpenFileError!windows.HANDLE {
    const space = try ntName(root, sub_path);
    var name = space.string();
    const absolute = Io.Dir.path.isAbsoluteWindowsWtf16(space.span());
    const attr: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (absolute) null else root, .ObjectName = &name };
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true, .RIGHTS = .{ .DELETE = purpose != .sync } },
        .GENERIC = .{ .WRITE = purpose == .sync },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = try retryingNt(io, .open_file, sub_path, ntCreate, .{
        &handle,                                                                                                                          access,
        &attr,                                                                                                                            windows.FILE.ATTRIBUTE{ .NORMAL = true },
        windows.FILE.SHARE.VALID_FLAGS,                                                                                                   windows.FILE.CREATE_DISPOSITION.OPEN,
        windows.FILE.MODE{ .NON_DIRECTORY_FILE = purpose == .sync, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = purpose != .sync },
    });
    return switch (status) {
        .SUCCESS => handle,
        else => openFailureNt(status),
    };
}

fn openFailureNt(status: windows.NTSTATUS) Io.File.OpenError {
    return switch (status) {
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .OBJECT_NAME_INVALID => error.BadPathName,
        .ACCESS_DENIED => error.AccessDenied,
        .SHARING_VIOLATION => error.FileBusy,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .NOT_A_DIRECTORY => error.NotDir,
        .DISK_FULL => error.NoSpaceLeft,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => error.NetworkNotFound,
        .NO_MEDIA_IN_DEVICE => error.NoDevice,
        .VIRUS_INFECTED, .VIRUS_DELETED => error.AntivirusInterference,
        .MEDIA_WRITE_PROTECTED => error.ReadOnlyFileSystem,
        else => windows.unexpectedStatus(status),
    };
}

fn createTempWindows(io: Io, root: windows.HANDLE, name: []const u8, read: bool) CreateTempError!windows.HANDLE {
    const space = try ntName(root, name);
    var nt = space.string();
    const attr: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = root, .ObjectName = &nt };
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true, .RIGHTS = .{ .DELETE = true } },
        .GENERIC = .{ .WRITE = true, .READ = read },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = try retryingNt(io, .create_temp, name, ntCreate, .{
        &handle,                                                                      access,
        &attr,                                                                        windows.FILE.ATTRIBUTE{ .NORMAL = true },
        windows.FILE.SHARE{ .READ = true, .DELETE = true },                           windows.FILE.CREATE_DISPOSITION.CREATE,
        windows.FILE.MODE{ .NON_DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
    });
    return switch (status) {
        .SUCCESS => handle,
        // The name lingers while another process holds the deleted file.
        .DELETE_PENDING => error.Busy,
        else => openFailureNt(status),
    };
}

fn setReadOnlyWindows(io: Io, handle: windows.HANDLE, read_only: bool) Io.File.SetPermissionsError!void {
    if (!read_only) return;
    var info: windows.FILE.BASIC_INFORMATION = .{
        .CreationTime = 0,
        .LastAccessTime = 0,
        .LastWriteTime = 0,
        .ChangeTime = 0,
        .FileAttributes = .{ .READONLY = true },
    };
    const status = try retryingNt(io, .set_mode, null, ntSetInfo, .{ handle, std.mem.asBytes(&info), .Basic });
    return switch (status) {
        .SUCCESS => {},
        .ACCESS_DENIED => error.AccessDenied,
        else => windows.unexpectedStatus(status),
    };
}

fn ntSetInfo(handle: windows.HANDLE, info: []u8, class: windows.FILE.INFORMATION_CLASS) windows.NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtSetInformationFile(handle, &iosb, info.ptr, @intCast(info.len), class);
}

/// How a Windows rename by handle ended.
pub const RenameOutcome = enum { renamed, collision, denied, sharing };

/// Rename the open file `handle` to `name` in `root`, by handle:
/// `FileRenameInformationEx` with POSIX semantics, falling back to
/// `FileRenameInformation` where the filesystem or the OS refuses it.
/// `denied` and `sharing` are contention a retry may outlast: NTFS reports
/// "the target is open" as access denied.
pub fn renameByHandle(io: Io, handle: windows.HANDLE, root: windows.HANDLE, name: []const u8, replace: bool) RenameError!RenameOutcome {
    const space = try ntName(root, name);
    const absolute = Io.Dir.path.isAbsoluteWindowsWtf16(space.span());
    var info: windows.FILE.RENAME_INFORMATION = .init(.{
        .Flags = .{ .REPLACE_IF_EXISTS = replace, .POSIX_SEMANTICS = true, .IGNORE_READONLY_ATTRIBUTE = true },
        .RootDirectory = if (absolute) null else root,
        .FileName = space.span(),
    });
    var status = try retryingNt(io, .win_rename_ex, name, ntSetInfo, .{ handle, info.toBuffer(), .RenameEx });
    if (status == .INVALID_PARAMETER or status == .INVALID_INFO_CLASS or status == .NOT_SUPPORTED) {
        info.Flags = .{ .REPLACE_IF_EXISTS = replace };
        status = try retryingNt(io, .rename, name, ntSetInfo, .{ handle, info.toBuffer(), .Rename });
        // The legacy rename will not replace a read-only target: clear the
        // attribute once and rename again.
        if (status == .ACCESS_DENIED and replace and clearReadOnly(io, root, name)) {
            status = try retryingNt(io, .rename, name, ntSetInfo, .{ handle, info.toBuffer(), .Rename });
        }
    }
    return switch (status) {
        .SUCCESS => .renamed,
        .OBJECT_NAME_COLLISION => .collision,
        .ACCESS_DENIED => .denied,
        .SHARING_VIOLATION, .DELETE_PENDING => .sharing,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .OBJECT_NAME_INVALID => error.BadPathName,
        .NOT_SAME_DEVICE => error.CrossDevice,
        .DIRECTORY_NOT_EMPTY => error.DirNotEmpty,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .NOT_A_DIRECTORY => error.NotDir,
        .DISK_FULL => error.NoSpaceLeft,
        .MEDIA_WRITE_PROTECTED => error.ReadOnlyFileSystem,
        else => windows.unexpectedStatus(status),
    };
}

/// Delete the open file `handle`: `FileDispositionInformationEx` with
/// POSIX semantics, so the name goes even while a scanner holds the file.
pub fn dispose(io: Io, handle: windows.HANDLE, path: ?[]const u8) UnlinkError!void {
    var flags: windows.FILE.DISPOSITION.INFORMATION.EX = .{ .Flags = .{
        .DELETE = true,
        .POSIX_SEMANTICS = true,
        .IGNORE_READONLY_ATTRIBUTE = true,
    } };
    var status = try retryingNt(io, .dispose, path, ntSetInfo, .{ handle, std.mem.asBytes(&flags), .DispositionEx });
    if (status == .INVALID_PARAMETER or status == .INVALID_INFO_CLASS or status == .NOT_SUPPORTED) {
        var legacy: windows.FILE.DISPOSITION.INFORMATION = .{ .DeleteFile = .TRUE };
        status = try retryingNt(io, .dispose, path, ntSetInfo, .{ handle, std.mem.asBytes(&legacy), .Disposition });
    }
    return switch (status) {
        .SUCCESS => {},
        .ACCESS_DENIED, .CANNOT_DELETE => error.AccessDenied,
        .SHARING_VIOLATION => error.FileBusy,
        .DIRECTORY_NOT_EMPTY, .FILE_IS_A_DIRECTORY => error.IsDir,
        .MEDIA_WRITE_PROTECTED => error.ReadOnlyFileSystem,
        else => windows.unexpectedStatus(status),
    };
}

fn unlinkWindows(io: Io, root: windows.HANDLE, name: []const u8) UnlinkError!void {
    const handle = openFileWindows(io, root, name, .delete) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.FileBusy => error.FileBusy,
        error.IsDir => error.IsDir,
        error.NotDir => error.NotDir,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.NetworkNotFound => error.NetworkNotFound,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.Canceled => error.Canceled,
        error.SystemResources => error.SystemResources,
        else => error.Unexpected,
    };
    defer release(io, handle);
    return dispose(io, handle, name);
}

/// `FILE_ID_INFORMATION`: the volume's 64-bit serial number and the file's
/// 128-bit id, the pair Windows documents as naming one file.
const FileIdInformation = extern struct {
    VolumeSerialNumber: u64,
    FileId: [16]u8,
};

fn ntQueryInfo(handle: windows.HANDLE, buf: []u8, class: windows.FILE.INFORMATION_CLASS) windows.NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtQueryInformationFile(handle, &iosb, buf.ptr, @intCast(buf.len), class);
}

fn ntQueryVolume(handle: windows.HANDLE, buf: []u8) windows.NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtQueryVolumeInformationFile(handle, &iosb, buf.ptr, @intCast(buf.len), .Volume);
}

fn statIdWindows(io: Io, handle: windows.HANDLE) StatIdError!Id {
    var id: FileIdInformation = undefined;
    const status = try retryingNt(io, .stat_id, null, ntQueryInfo, .{ handle, std.mem.asBytes(&id), .Id });
    switch (status) {
        .SUCCESS => return .{
            .volume = id.VolumeSerialNumber,
            .file = std.mem.readInt(u128, &id.FileId, .little),
        },
        .ACCESS_DENIED => return error.AccessDenied,
        // No 128-bit ids (FAT, some redirectors): the volume's 32-bit
        // serial and the 64-bit index are what there is.
        .INVALID_PARAMETER, .INVALID_INFO_CLASS, .NOT_IMPLEMENTED, .NOT_SUPPORTED => {},
        else => return windows.unexpectedStatus(status),
    }
    var volume: extern struct {
        info: windows.FILE.FS_VOLUME_INFORMATION,
        label: [64]windows.WCHAR,
    } = undefined;
    switch (ntQueryVolume(handle, std.mem.asBytes(&volume))) {
        .SUCCESS, .BUFFER_OVERFLOW => {},
        .ACCESS_DENIED => return error.AccessDenied,
        else => |s| return windows.unexpectedStatus(s),
    }
    var internal: windows.FILE.INTERNAL_INFORMATION = undefined;
    switch (ntQueryInfo(handle, std.mem.asBytes(&internal), .Internal)) {
        .SUCCESS => {},
        .ACCESS_DENIED => return error.AccessDenied,
        else => |s| return windows.unexpectedStatus(s),
    }
    return .{
        .volume = volume.info.VolumeSerialNumber,
        .file = @as(u64, @bitCast(internal.IndexNumber)), // safe: the index is an unsigned 64-bit number stored as LARGE_INTEGER
    };
}

fn statIdPathWindows(io: Io, root: windows.HANDLE, sub_path: []const u8, follow: bool) StatPathError!Id {
    const space = try ntName(root, sub_path);
    var name = space.string();
    const absolute = Io.Dir.path.isAbsoluteWindowsWtf16(space.span());
    const attr: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (absolute) null else root, .ObjectName = &name };
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = try retryingNt(io, .open_file, sub_path, ntCreate, .{
        &handle,                                                                         access,
        &attr,                                                                           windows.FILE.ATTRIBUTE{ .NORMAL = true },
        windows.FILE.SHARE.VALID_FLAGS,                                                  windows.FILE.CREATE_DISPOSITION.OPEN,
        windows.FILE.MODE{ .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = !follow },
    });
    if (status != .SUCCESS) return openFailureNt(status);
    defer release(io, handle);
    return statIdWindows(io, handle);
}

/// Windows: a 64-bit hash of the volume's NT device name
/// (`\Device\HarddiskVolumeN`), which tells apart two volumes that share a
/// serial (cloned VHDs and VM images keep it).
pub fn volumeName(io: Io, handle: windows.HANDLE) StatIdError!u64 {
    if (intercept(io, .volume_name, null)) |r| switch (r) {
        .value => |v| return v,
        .canceled => return error.Canceled,
        .code => |c| if (c != success) return windows.unexpectedStatus(c),
    };
    var buf: extern struct { len: u32, name: [60]u16 } = undefined;
    const status = ntQueryInfo(handle, std.mem.asBytes(&buf), .VolumeName);
    switch (status) {
        .SUCCESS, .BUFFER_OVERFLOW => {},
        .ACCESS_DENIED => return error.AccessDenied,
        // A filesystem that will not say: one name for all of them, so the
        // serial alone decides, as before the name was asked.
        .INVALID_PARAMETER, .INVALID_INFO_CLASS, .NOT_IMPLEMENTED, .NOT_SUPPORTED => return 0,
        else => return windows.unexpectedStatus(status),
    }
    const chars = @min(buf.len / 2, buf.name.len);
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(buf.name[0..chars]));
}
