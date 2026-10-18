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
//! test's hook; production pays one function-pointer compare per call. A
//! hook with a route has the calls it lets through made through the
//! route's `Io` and its `flush` instead of the system, one for one: the
//! platform's logic around each call is the same either way, so airlock
//! runs on a simulated file system as it runs on a real one.
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

const Blocking = @import("Blocking.zig");

const seam = @import("seam");
const aegis_id = @import("aegis").id;

pub const Call = seam.Call;
const Code = seam.Code;
const Route = seam.Route;

/// What a try at a raw call is to be.
const Decision = union(enum) {
    /// Made on the system.
    system,
    /// Not made: it returns this failure code.
    code: Code,
    /// Made through the hook's route.
    route: *const Route,
};

/// What the hook, if `io` carries one, makes of a try at `call`.
fn decide(io: Io, call: Call, path: ?[]const u8) Io.Cancelable!Decision {
    const hook = seam.hookOf(io) orelse return .system;
    if (hook.call(hook.ctx, call, path)) |result| switch (result) {
        .code => |c| if (c != success) return .{ .code = c },
        .canceled => return error.Canceled,
        .value => {},
    };
    return if (hook.route) |*route| .{ .route = route } else .system;
}

/// What a try came to: the code the system or the hook returned, or the
/// route the call is to be made through instead.
const Attempt = union(enum) { code: Code, route: *const Route };

const success: Code = .SUCCESS;
/// The code of a call interrupted before it was made.
const interrupted: Code = if (is_windows) .CANCELLED else .INTR;

/// `Io.File` and `Io.Dir` of a raw handle, for a call made through a route.
fn fileOf(handle: Handle) Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}
fn dirOf(handle: Handle) Io.Dir {
    return .{ .handle = handle };
}

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
/// The hook decides each try first; a try it routes is the caller's to
/// make through the route.
fn retrying(io: Io, call: Call, path: ?[]const u8, comptime f: anytype, args: anytype) Io.Cancelable!Attempt {
    while (true) {
        try io.checkCancel();
        const code: Code = switch (try decide(io, call, path)) {
            .system => codeOf(f, args),
            .code => |c| c,
            .route => |route| return .{ .route = route },
        };
        if (code != interrupted) return .{ .code = code };
    }
}

/// The code `f(args)` returns: a raw call's errno or NTSTATUS, or a route's
/// code as it is.
fn codeOf(comptime f: anytype, args: anytype) Code {
    const rc = @call(.auto, f, args);
    if (@TypeOf(rc) == Code) return rc;
    return errnoOf(rc);
}

/// Execute only the call elsewhere; never read thread-local errno on the
/// calling task after returning from an executor.
fn syncCall(io: Io, blocking: ?Blocking, comptime f: anytype, args: anytype) Io.Cancelable!Code {
    const hook = blocking orelse return codeOf(f, args);
    const Job = struct {
        const Self = @This();
        arguments: @TypeOf(args),
        result: Code = undefined,

        fn run(argument: *anyopaque) void {
            const job: *Self = @ptrCast(@alignCast(argument)); // safe: argument points to the live Job below
            job.result = codeOf(f, job.arguments);
        }
    };
    var job: Job = .{ .arguments = args };
    try hook.run(io, hook.context, Job.run, &job);
    return job.result;
}

/// A route's sync, as the code the platform's call would return.
fn routeFlush(route: *const Route, handle: Handle, kind: seam.Flush) Code {
    return route.flush(route.ctx, handle, kind);
}

/// Cancellation and seam interception remain on the calling task. Each
/// actual sync attempt, including retries and fallbacks, uses the
/// executor: the system's call, or the route's sync of `handle` at `kind`.
fn retryingSync(io: Io, blocking: ?Blocking, call: Call, path: ?[]const u8, handle: Handle, kind: seam.Flush, comptime f: anytype, args: anytype) Io.Cancelable!Code {
    while (true) {
        try io.checkCancel();
        const code = switch (try decide(io, call, path)) {
            .system => try syncCall(io, blocking, f, args),
            .code => |c| c,
            .route => |route| try syncCall(io, blocking, routeFlush, .{ route, handle, kind }),
        };
        if (code != interrupted) return code;
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
pub fn fullFsync(io: Io, blocking: ?Blocking, fd: posix.fd_t, call: Call, path: ?[]const u8) SyncError!void {
    const e = try retryingSync(io, blocking, call, path, fd, .full, darwinFcntl, .{ fd, darwin_full_fsync });
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .NOTTY, .PERM => error.Refused,
        else => if (isNotSupported(e)) error.Refused else syncFailure(e),
    };
}

/// Darwin `F_BARRIERFSYNC`: everything handed to the device before it is
/// written before anything after it.
pub fn barrierFsync(io: Io, blocking: ?Blocking, fd: posix.fd_t, path: ?[]const u8) SyncError!void {
    const e = try retryingSync(io, blocking, .sync_barrier, path, fd, .barrier, darwinFcntl, .{ fd, darwin_barrier_fsync });
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .NOTTY, .PERM => error.Refused,
        else => if (isNotSupported(e)) error.Refused else syncFailure(e),
    };
}

/// Plain `fsync` on Darwin and the BSDs: a writeout, or the end of a chain.
/// Darwin's does not flush the device; the BSDs' is their full sync.
pub fn plainFsync(io: Io, blocking: ?Blocking, fd: posix.fd_t, call: Call, path: ?[]const u8) SyncError!void {
    const kind: seam.Flush = if (is_darwin or call == .sync_writeout) .writeout else .full;
    const e = if (is_linux)
        try retryingSync(io, blocking, call, path, fd, kind, linux.fsync, .{fd})
    else
        try retryingSync(io, blocking, call, path, fd, kind, cFsync, .{fd});
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .ROFS => error.Refused,
        else => if (isNotSupported(e)) error.Refused else syncFailure(e),
    };
}

/// Linux `fdatasync`.
pub fn dataFsync(io: Io, blocking: ?Blocking, fd: posix.fd_t, path: ?[]const u8) SyncError!void {
    const e = try retryingSync(io, blocking, .sync_data, path, fd, .data, linux.fdatasync, .{fd});
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .ROFS, .NOSYS => error.Refused,
        else => syncFailure(e),
    };
}

/// Linux `fsync` on a file, as the full sync.
pub fn linuxFsync(io: Io, blocking: ?Blocking, fd: posix.fd_t, call: Call, path: ?[]const u8) (SyncError || error{BadHandle})!void {
    const e = try retryingSync(io, blocking, call, path, fd, .full, linux.fsync, .{fd});
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
        switch (try decide(io, .getfl, null)) {
            .system => {},
            .code => |code| {
                if (code == .INTR) continue;
                return false;
            },
            // A routed sync fails with a bad handle only for a bad handle.
            .route => return false,
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
    const e = switch (try retrying(io, .writeback, null, syncFileRange, .{ fd, offset, len })) {
        .code => |c| c,
        // Starting writeback promises nothing a crash keeps, so a simulated
        // disk is told nothing: the final sync does it all.
        .route => return,
    };
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
    const e: posix.E = switch (decide(io, .close, path) catch .system) {
        .code => |code| blk: {
            // The hook decided what close says; the descriptor still goes,
            // exactly once.
            closeRouted(io, handle);
            break :blk code;
        },
        .route => |route| {
            fileOf(handle).close(route.io);
            return;
        },
        .system => if (is_linux)
            linux.errno(linux.close(handle))
        else
            std.c.errno(std.c.close(handle)),
    };
    return switch (e) {
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        // EINTR: Linux released the descriptor anyway; it is closed.
        else => {},
    };
}

/// Close a handle whose close the hook answered: through the route, if
/// there is one, otherwise on the system.
fn closeRouted(io: Io, handle: Handle) void {
    if (seam.hookOf(io)) |hook| if (hook.route) |route| return fileOf(handle).close(route.io);
    if (is_windows) {
        _ = windows.ntdll.NtClose(handle);
    } else if (is_linux) {
        _ = linux.close(handle);
    } else {
        _ = std.c.close(handle);
    }
}

/// `close` where its answer changes nothing: a handle being dropped after
/// another failure, or one airlock only read through.
pub fn release(io: Io, handle: Handle) void {
    // glint-ignore: Z026 -- a handle dropped after another failure; that failure is the one the caller gets
    close(io, handle, null) catch {};
}

fn openatRaw(dir: posix.fd_t, path: [*:0]const u8, flags: posix.O, mode: posix.mode_t) if (is_linux) usize else c_int {
    if (is_linux) return linux.openat(dir, path, flags, mode);
    return std.c.openat(dir, path, flags, mode);
}

pub const OpenDirError = Io.Dir.OpenError || error{ InputOutput, NoSpaceLeft };

/// A directory opened read-only so it can be synced and named relative to:
/// `openat(O_RDONLY | O_DIRECTORY | O_CLOEXEC)`, never `O_PATH`.
pub fn openDir(io: Io, dir: Handle, sub_path: []const u8) OpenDirError!Handle {
    if (is_windows) return openDirWindows(io, dir, sub_path, false);
    const path = try posix.toPosixPath(sub_path);
    var flags: posix.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    flags.DIRECTORY = true;
    while (true) {
        try io.checkCancel();
        switch (try decide(io, .open_dir, sub_path)) {
            .system => {},
            .code => |code| {
                if (code == .INTR) continue;
                return openDirFailure(code);
            },
            .route => |route| return (try dirOf(dir).openDir(route.io, sub_path, .{})).handle,
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
        .IO => error.InputOutput,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        else => posix.unexpectedErrno(e),
    };
}

pub const OpenFileError = Io.File.OpenError || error{InputOutput};

/// An existing file opened to be synced: read-only on POSIX, for write on
/// Windows (a flush needs write access; a read-only file has its attribute
/// cleared for the open and put back).
pub fn openFile(io: Io, dir: Handle, sub_path: []const u8) OpenFileError!Handle {
    if (is_windows) return openFileWindows(io, dir, sub_path, .sync);
    const path = try posix.toPosixPath(sub_path);
    const flags: posix.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    while (true) {
        try io.checkCancel();
        switch (try decide(io, .open_file, sub_path)) {
            .system => {},
            .code => |code| {
                if (code == .INTR) continue;
                return openFileFailure(code);
            },
            .route => |route| return (try dirOf(dir).openFile(route.io, sub_path, .{})).handle,
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
        .IO => error.InputOutput,
        .ROFS => error.ReadOnlyFileSystem,
        .TXTBSY => error.FileBusy,
        .BUSY => error.DeviceBusy,
        .FBIG, .OVERFLOW => error.FileTooBig,
        .AGAIN => error.WouldBlock,
        else => posix.unexpectedErrno(e),
    };
}

pub const CreateTempError = OpenFileError || error{Busy};

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
        switch (try decide(io, .create_temp, name)) {
            .system => {},
            .code => |code| {
                if (code == .INTR) continue;
                return openFileFailure(code);
            },
            .route => |route| return createTempRouted(route, dir, name, mode, read),
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

/// `createTemp` through a route: an exclusive create.
fn createTempRouted(route: *const Route, dir: Handle, name: []const u8, mode: Io.File.Permissions, read: bool) CreateTempError!Handle {
    const file = try dirOf(dir).createFile(route.io, name, .{ .read = read, .exclusive = true, .truncate = false, .permissions = mode });
    return file.handle;
}

/// Permissions on the open handle: `fchmod`, so umask does not apply and
/// there is no window between a stat and a chmod of the path.
pub fn setMode(io: Io, handle: Handle, mode: Io.File.Permissions) SetModeError!void {
    if (is_windows) return setReadOnlyWindows(io, handle, isReadOnly(mode));
    const fchmod = if (is_linux) linux.fchmod else std.c.fchmod;
    const e = switch (try retrying(io, .set_mode, null, fchmod, .{ handle, mode.toMode() })) {
        .code => |c| c,
        .route => |route| return fileOf(handle).setPermissions(route.io, mode),
    };
    return switch (e) {
        .SUCCESS => {},
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .IO => error.InputOutput,
        .LOOP => error.SymLinkLoop,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
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
    const e = switch (try retrying(io, .rename, new, renameatRaw, .{ old_dir, &old_z, new_dir, &new_z })) {
        .code => |c| c,
        .route => |route| return dirOf(old_dir).rename(old, dirOf(new_dir), new, route.io),
    };
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
    const e = switch (try retrying(io, .rename_noreplace, new, renameNoReplaceRaw, .{ old_dir, &old_z, new_dir, &new_z })) {
        .code => |c| c,
        .route => |route| return renamePreserveRouted(route, old_dir, old, new_dir, new),
    };
    return switch (e) {
        .SUCCESS => {},
        .EXIST => error.AlreadyExists,
        .INVAL, .NOSYS => error.Refused,
        else => if (isNotSupported(e)) error.Refused else renameFailure(e),
    };
}

/// `renameNoReplace` through a route: std's rename that never replaces.
fn renamePreserveRouted(route: *const Route, old_dir: Handle, old: []const u8, new_dir: Handle, new: []const u8) (RenameError || Refused || error{AlreadyExists})!void {
    return dirOf(old_dir).renamePreserve(old, dirOf(new_dir), new, route.io) catch |err| switch (err) {
        error.PathAlreadyExists => error.AlreadyExists,
        error.OperationUnsupported => error.Refused,
        else => |e| e,
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
    const e = switch (try retrying(io, .link, new, linkatRaw, .{ old_dir, &old_z, new_dir, &new_z })) {
        .code => |c| c,
        .route => |route| return linkRouted(route, old_dir, old, new_dir, new),
    };
    return switch (e) {
        .SUCCESS => {},
        .EXIST => error.AlreadyExists,
        .PERM => error.Refused,
        else => if (isNotSupported(e)) error.Refused else renameFailure(e),
    };
}

/// `link` through a route: std's hard link.
fn linkRouted(route: *const Route, old_dir: Handle, old: []const u8, new_dir: Handle, new: []const u8) (RenameError || Refused || error{AlreadyExists})!void {
    return dirOf(old_dir).hardLink(old, dirOf(new_dir), new, route.io, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => error.AlreadyExists,
        error.OperationUnsupported => error.Refused,
        else => |e| e,
    };
}

pub const UnlinkError = Io.Dir.DeleteFileError || error{NoSpaceLeft};

fn unlinkatRaw(dir: posix.fd_t, path: [*:0]const u8) if (is_linux) usize else c_int {
    if (is_linux) return linux.unlinkat(dir, path, 0);
    return std.c.unlinkat(dir, path, 0);
}

/// `unlinkat` of a file.
pub fn unlink(io: Io, dir: Handle, name: []const u8) UnlinkError!void {
    if (is_windows) return unlinkWindows(io, dir, name);
    const path = try posix.toPosixPath(name);
    const e = switch (try retrying(io, .unlink, name, unlinkatRaw, .{ dir, &path })) {
        .code => |c| c,
        .route => |route| return dirOf(dir).deleteFile(route.io, name),
    };
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
        .NOSPC => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        else => posix.unexpectedErrno(e),
    };
}

pub const MakeDirError = Io.Dir.CreateDirError || error{InputOutput};

fn mkdiratRaw(dir: posix.fd_t, path: [*:0]const u8, mode: posix.mode_t) if (is_linux) usize else c_int {
    if (is_linux) return linux.mkdirat(dir, path, mode);
    return std.c.mkdirat(dir, path, mode);
}

/// `mkdirat(name, 0777)`: umask applies. Windows creates it by name.
pub fn makeDir(io: Io, dir: Handle, name: []const u8) MakeDirError!void {
    if (is_windows) return makeDirWindows(io, dir, name);
    const path = try posix.toPosixPath(name);
    const e = switch (try retrying(io, .make_dir, name, mkdiratRaw, .{ dir, &path, 0o777 })) {
        .code => |c| c,
        .route => |route| return dirOf(dir).createDir(route.io, name, .default_dir),
    };
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
        .IO => error.InputOutput,
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
    const e = switch (try retrying(io, .symlink, name, symlinkatRaw, .{ &target_z, dir, &path })) {
        .code => |c| c,
        .route => |route| return dirOf(dir).symLink(route.io, target, name, .{}),
    };
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

/// The number the OS gives a volume: the device on POSIX, the serial number on
/// Windows. Not interchangeable with `DeviceId`, which is a hash of a name.
pub const VolumeId = aegis_id.Id(VolumeTag, u64);
const VolumeTag = struct {};

/// Windows: a 64-bit hash of a volume's NT device name; 0 where there is no
/// name to hash. A volume is told apart by both ids, never by one standing for
/// the other.
pub const DeviceId = aegis_id.Id(DeviceTag, u64);
const DeviceTag = struct {};

/// A file's identity as the filesystem numbers it. The file number is 128 bits
/// wide, so it cannot stand for a volume id even by mistake.
pub const Id = struct { volume: VolumeId, file: u128 };

pub const StatIdError = Io.File.StatError || error{InputOutput};
pub const StatPathError = Io.Dir.StatFileError || OpenFileError;

/// What `setMode` fails with: std's, and a full disk (a metadata write can need room).
pub const SetModeError = Io.File.SetPermissionsError || error{NoSpaceLeft};

/// The bits of a `dev_t` or `ino_t`, whichever sign and width the platform
/// gives it: Darwin's device number is an `i32`.
fn unsigned(x: anytype) u64 {
    const bits_type = @Int(.unsigned, @bitSizeOf(@TypeOf(x)));
    return @as(bits_type, @bitCast(x)); // safe: reinterprets the same bits as unsigned
}

/// A Linux device as one number: the major and the minor both, since two
/// volumes can share either.
pub fn linuxVolume(major: u32, minor: u32) VolumeId {
    return .fromRaw((@as(u64, major) << 32) | minor);
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
        const e = switch (try retrying(io, .stat_id, null, statxRaw, .{ handle, "", linux.AT.EMPTY_PATH, &buf })) {
            .code => |c| c,
            .route => |route| return routedId(try fileOf(handle).stat(route.io)),
        };
        if (e != .SUCCESS) return statFailure(e);
        if (!buf.mask.INO) return error.Unexpected;
        return .{ .volume = linuxVolume(buf.dev_major, buf.dev_minor), .file = buf.ino };
    }
    var buf = std.mem.zeroes(posix.Stat);
    const e = switch (try retrying(io, .stat_id, null, fstatRaw, .{ handle, &buf })) {
        .code => |c| c,
        .route => |route| return routedId(try fileOf(handle).stat(route.io)),
    };
    if (e != .SUCCESS) return statFailure(e);
    return .{ .volume = .fromRaw(unsigned(buf.dev)), .file = unsigned(buf.ino) };
}

/// A file's identity through a route: its inode, on the one volume the
/// route's file system is.
fn routedId(stat: Io.File.Stat) Id {
    return .{ .volume = routed_volume, .file = unsigned(stat.inode) };
}

/// The volume every file reached through a route is on.
const routed_volume: VolumeId = .fromRaw(0);

fn statFailure(e: posix.E) StatIdError {
    return switch (e) {
        .NOMEM => error.SystemResources,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .IO => error.InputOutput,
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
        const e = switch (try retrying(io, .stat_id, sub_path, statxRaw, .{ dir, &path, flags, &buf })) {
            .code => |c| c,
            .route => |route| return routedId(try dirOf(dir).statFile(route.io, sub_path, .{ .follow_symlinks = follow })),
        };
        if (e != .SUCCESS) return statPathFailure(e);
        if (!buf.mask.INO) return error.Unexpected;
        return .{ .volume = linuxVolume(buf.dev_major, buf.dev_minor), .file = buf.ino };
    }
    var buf = std.mem.zeroes(posix.Stat);
    const flags: u32 = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    const e = switch (try retrying(io, .stat_id, sub_path, fstatatRaw, .{ dir, &path, &buf, flags })) {
        .code => |c| c,
        .route => |route| return routedId(try dirOf(dir).statFile(route.io, sub_path, .{ .follow_symlinks = follow })),
    };
    if (e != .SUCCESS) return statPathFailure(e);
    return .{ .volume = .fromRaw(unsigned(buf.dev)), .file = unsigned(buf.ino) };
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

/// Everything one stat of a path reports, as the platform reports it.
pub const Full = struct {
    kind: Io.File.Kind,
    size: u64,
    /// The type and permission bits; on Windows none (0).
    mode: u32,
    /// The mode's permissions, or on Windows the file's attributes, as
    /// `std.Io` sets them.
    permissions: Io.File.Permissions,
    mtime: Io.Timestamp,
    /// The status change time; on Windows the attribute change time.
    ctime: Io.Timestamp,
    /// The creation time where the platform keeps one: Windows, Darwin and
    /// the BSDs, Linux where `statx` reports it.
    birth: ?Io.Timestamp,
    /// The inode; on Windows the 64-bit file index.
    inode: u64,
    /// The device, as the platform's `dev_t` holds it (Linux: `makedev`);
    /// on Windows the volume's serial number.
    device: u64,
    /// The owner and group; zero on Windows.
    uid: u32,
    gid: u32,
    /// Windows: the attributes and, for a reparse point, its tag. Zero
    /// elsewhere.
    attributes: u32,
    reparse_tag: u32,
};

fn statxFullRaw(dir: posix.fd_t, path: [*:0]const u8, flags: u32, buf: *linux.Statx) usize {
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .INO = true, .SIZE = true, .UID = true, .GID = true, .MTIME = true, .CTIME = true, .BTIME = true };
    return linux.statx(dir, path, flags | linux.AT.NO_AUTOMOUNT, mask, buf);
}

fn nanoseconds(sec: anytype, nsec: anytype) Io.Timestamp {
    return .{ .nanoseconds = @as(i96, sec) * std.time.ns_per_s + nsec };
}

/// A Linux device number as glibc's `makedev` packs it into a `dev_t`.
fn linuxDevice(major: u32, minor: u32) u64 {
    return ((@as(u64, major) & 0xfffff000) << 32) | ((@as(u64, major) & 0xfff) << 8) |
        ((@as(u64, minor) & 0xffffff00) << 12) | (@as(u64, minor) & 0xff);
}

/// The file type the mode bits name.
pub fn kindOfMode(mode: u32) Io.File.Kind {
    return switch (mode & 0o170000) {
        0o100000 => .file,
        0o040000 => .directory,
        0o120000 => .sym_link,
        0o060000 => .block_device,
        0o020000 => .character_device,
        0o010000 => .named_pipe,
        0o140000 => .unix_domain_socket,
        else => .unknown,
    };
}

/// The type bits of a kind, for a stat taken through a route.
fn modeOfKind(kind: Io.File.Kind) u32 {
    return switch (kind) {
        .file => 0o100000,
        .directory => 0o040000,
        .sym_link => 0o120000,
        .block_device => 0o060000,
        .character_device => 0o020000,
        .named_pipe => 0o010000,
        .unix_domain_socket => 0o140000,
        else => 0,
    };
}

/// The mode's permission bits, as `std.Io` holds them.
fn permissionsOfMode(mode: u32) Io.File.Permissions {
    return if (Io.File.Permissions.has_executable_bit) .fromMode(@intCast(mode & 0o7777)) else .default_file;
}

/// A path's stat through a route: what `std.Io` reports, on the one volume
/// a route's file system is, owned by no one.
fn routedFull(stat: Io.File.Stat) Full {
    const mode: u32 = if (Io.File.Permissions.has_executable_bit) modeOfKind(stat.kind) | @as(u32, @intCast(stat.permissions.toMode() & 0o7777)) else 0;
    return .{
        .kind = stat.kind,
        .size = stat.size,
        .mode = mode,
        .permissions = stat.permissions,
        .mtime = stat.mtime,
        .ctime = stat.ctime,
        .birth = null,
        .inode = unsigned(stat.inode),
        .device = routed_volume.raw(),
        .uid = 0,
        .gid = 0,
        .attributes = 0,
        .reparse_tag = 0,
    };
}

/// The whole stat of what `sub_path` names relative to `dir`, following a
/// symbolic link or not. A path that is not there is `FileNotFound` and a
/// path through something that is not a directory `NotDir`, apart, as the
/// platform tells them apart.
pub fn statPath(io: Io, dir: Handle, sub_path: []const u8, follow: bool) StatPathError!Full {
    if (is_windows) return statPathWindows(io, dir, sub_path, follow);
    const path = try posix.toPosixPath(sub_path);
    if (is_linux) {
        var buf = std.mem.zeroes(linux.Statx);
        const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
        const e = switch (try retrying(io, .stat, sub_path, statxFullRaw, .{ dir, &path, flags, &buf })) {
            .code => |c| c,
            .route => |route| return routedFull(try dirOf(dir).statFile(route.io, sub_path, .{ .follow_symlinks = follow })),
        };
        if (e != .SUCCESS) return statPathFailure(e);
        return .{
            .kind = kindOfMode(buf.mode),
            .size = buf.size,
            .mode = buf.mode,
            .permissions = permissionsOfMode(buf.mode),
            .mtime = nanoseconds(buf.mtime.sec, buf.mtime.nsec),
            .ctime = nanoseconds(buf.ctime.sec, buf.ctime.nsec),
            .birth = if (buf.mask.BTIME) nanoseconds(buf.btime.sec, buf.btime.nsec) else null,
            .inode = buf.ino,
            .device = linuxDevice(buf.dev_major, buf.dev_minor),
            .uid = buf.uid,
            .gid = buf.gid,
            .attributes = 0,
            .reparse_tag = 0,
        };
    }
    var buf = std.mem.zeroes(posix.Stat);
    const flags: u32 = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    const e = switch (try retrying(io, .stat, sub_path, fstatatRaw, .{ dir, &path, &buf, flags })) {
        .code => |c| c,
        .route => |route| return routedFull(try dirOf(dir).statFile(route.io, sub_path, .{ .follow_symlinks = follow })),
    };
    if (e != .SUCCESS) return statPathFailure(e);
    const mtime = buf.mtime();
    const ctime = buf.ctime();
    const mode: u32 = @intCast(buf.mode);
    return .{
        .kind = kindOfMode(mode),
        .size = @intCast(@max(buf.size, 0)),
        .mode = mode,
        .permissions = permissionsOfMode(mode),
        .mtime = nanoseconds(mtime.sec, mtime.nsec),
        .ctime = nanoseconds(ctime.sec, ctime.nsec),
        .birth = if (@hasDecl(posix.Stat, "birthtime")) birth: {
            const b = buf.birthtime();
            break :birth nanoseconds(b.sec, b.nsec);
        } else null,
        .inode = unsigned(buf.ino),
        .device = unsigned(buf.dev),
        .uid = @intCast(buf.uid),
        .gid = @intCast(buf.gid),
        .attributes = 0,
        .reparse_tag = 0,
    };
}

/// What a volume is, as the platform describes it.
pub const VolumeInfo = struct {
    remote: bool,
    /// The file system's type name, as many bytes of it as fit.
    name: [32]u8 = @splat(0),
    name_len: u8 = 0,

    fn setName(v: *VolumeInfo, text: []const u8) void {
        const n = @min(text.len, v.name.len);
        @memcpy(v.name[0..n], text[0..n]);
        v.name_len = @intCast(n);
    }
};

pub const VolumeError = Io.File.StatError || error{InputOutput};

/// Darwin's `struct statfs` with 64-bit inodes, the one `fstatfs` fills
/// on arm64 and `fstatfs$INODE64` on x86_64.
const DarwinStatfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    type: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

const darwin_statfs = struct {
    extern "c" fn fstatfs(fd: posix.fd_t, buf: *DarwinStatfs) c_int;
    extern "c" fn @"fstatfs$INODE64"(fd: posix.fd_t, buf: *DarwinStatfs) c_int;
};

fn darwinFstatfs(fd: posix.fd_t, buf: *DarwinStatfs) c_int {
    return if (builtin.target.cpu.arch == .x86_64) darwin_statfs.@"fstatfs$INODE64"(fd, buf) else darwin_statfs.fstatfs(fd, buf);
}

/// Darwin's `MNT_LOCAL`: the volume is stored on this machine.
const darwin_mnt_local = 0x1000;

/// Linux's `struct statfs` as far as its type: a word on 64-bit targets
/// but s390x's, where it is 32 bits, as it is in `statfs64` on 32-bit
/// ones. The rest of the buffer is room for what the kernel writes.
const LinuxStatfs = extern struct {
    words: [16]u64 align(8),

    fn magic(buf: *const LinuxStatfs) u64 {
        const word_is_long = @sizeOf(usize) == 8 and builtin.target.cpu.arch != .s390x;
        return if (word_is_long) buf.words[0] else std.mem.bytesAsValue(u32, std.mem.asBytes(&buf.words[0])[0..4]).*;
    }
};

fn linuxFstatfs(fd: posix.fd_t, buf: *LinuxStatfs) usize {
    const word: usize = @bitCast(@as(isize, fd)); // safe: a descriptor passes to the kernel as a word, its sign extended
    const address = @intFromPtr(buf); // safe: the kernel writes the buffer through its address
    if (@hasField(linux.SYS, "fstatfs64")) return linux.syscall3(.fstatfs64, word, @sizeOf(LinuxStatfs), address);
    return linux.syscall2(.fstatfs, word, address);
}

/// The network file systems by their Linux magic numbers: NFS, SMB and
/// CIFS, AFS and Coda, and FUSE, whose server may be anywhere. git's
/// list (`compat/fsmonitor/fsm-path-utils-linux.c`), and its names for
/// them where the mount table does not say.
const linux_remote = [_]struct { magic: u64, name: []const u8 }{
    .{ .magic = 0xff534d42, .name = "cifs" },
    .{ .magic = 0x517b, .name = "smb" },
    .{ .magic = 0xfe534d42, .name = "smb2" },
    .{ .magic = 0x6969, .name = "nfs" },
    .{ .magic = 0x5346414f, .name = "afs" },
    .{ .magic = 0x73757245, .name = "coda" },
    .{ .magic = 0x65735546, .name = "fuse" },
};

fn statxMountRaw(fd: posix.fd_t, buf: *linux.Statx) usize {
    return linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .MNT_ID = true }, buf);
}

/// The type `/proc/self/mountinfo` gives mount `id`, or nothing when the
/// table cannot be read or does not list it.
fn linuxMountType(io: Io, id: u64, out: *VolumeInfo) void {
    const file = Io.Dir.openFileAbsolute(io, "/proc/self/mountinfo", .{}) catch return;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    while (true) {
        // A line longer than the buffer (a mount's options can be) is
        // passed over; its mount is not the one.
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.interface.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            else => return,
        };
        // `id parent major:minor root point options [tags] - type source super`
        var fields = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\n"), ' ');
        const first = fields.next() orelse continue;
        if ((std.fmt.parseInt(u64, first, 10) catch continue) != id) continue;
        while (fields.next()) |field| if (std.mem.eql(u8, field, "-")) {
            out.setName(fields.next() orelse return);
            return;
        };
        return;
    }
}

/// What the volume `dir` is on is: whether it is remote and its file
/// system's type name.
pub fn volumeOf(io: Io, dir: Handle) VolumeError!VolumeInfo {
    if (is_windows) return volumeWindows(io, dir);
    if (is_linux) {
        var buf: LinuxStatfs = .{ .words = @splat(0) };
        const e = switch (try retrying(io, .statfs, null, linuxFstatfs, .{ dir, &buf })) {
            .code => |c| c,
            .route => return .{ .remote = false },
        };
        if (e != .SUCCESS) return statFailure(e);
        const magic = buf.magic();
        var info: VolumeInfo = .{ .remote = false };
        for (linux_remote) |r| if (r.magic == magic) {
            info.remote = true;
            info.setName(r.name);
        };
        var mount = std.mem.zeroes(linux.Statx);
        if (linux.errno(statxMountRaw(dir, &mount)) == .SUCCESS and mount.mask.MNT_ID) linuxMountType(io, mount.mnt_id, &info);
        return info;
    }
    if (!is_darwin) return error.Unexpected;
    var buf: DarwinStatfs = undefined;
    const e = switch (try retrying(io, .statfs, null, darwinFstatfs, .{ dir, &buf })) {
        .code => |c| c,
        .route => return .{ .remote = false },
    };
    if (e != .SUCCESS) return statFailure(e);
    var info: VolumeInfo = .{ .remote = buf.flags & darwin_mnt_local == 0 };
    info.setName(std.mem.sliceTo(&buf.fstypename, 0));
    return info;
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
/// between tries. The hook decides each try first; a try it routes is the
/// caller's to make through the route.
const retryingNt = retrying;

/// The status of a Windows call that has no route of its own: a routed try
/// is `routed`.
fn statusOf(attempt: Attempt, routed: windows.NTSTATUS) windows.NTSTATUS {
    return switch (attempt) {
        .code => |c| c,
        .route => routed,
    };
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

/// The statuses that say the device failed: `EIO`.
fn isDeviceFailureNt(status: windows.NTSTATUS) bool {
    return switch (status) {
        .UNEXPECTED_NETWORK_ERROR, .DEVICE_DATA_ERROR, .DATA_ERROR, .IO_DEVICE_ERROR, .FILE_CORRUPT_ERROR => true,
        else => false,
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
pub fn flushWindows(io: Io, blocking: ?Blocking, handle: windows.HANDLE, call: Call, path: ?[]const u8) SyncError!void {
    const status = try retryingSync(io, blocking, call, path, handle, .full, ntFlush, .{handle});
    if (status == .SUCCESS) return;
    if (status == .NOT_SUPPORTED or status == .INVALID_DEVICE_REQUEST) return error.Refused;
    return ntSyncFailure(status);
}

/// `NtFlushBuffersFileEx` with one flag. Refused outside NTFS (and for
/// `no_sync`, FAT and exFAT): ReFS, redirectors.
pub fn flushExWindows(io: Io, blocking: ?Blocking, handle: windows.HANDLE, flag: FlushEx, path: ?[]const u8) SyncError!void {
    const call: Call, const kind: seam.Flush = switch (flag) {
        .data_sync_only => .{ .sync_data, .data },
        .no_sync => .{ .sync_writeout, .writeout },
    };
    const status = try retryingSync(io, blocking, call, path, handle, kind, ntFlushEx, .{ handle, @backingInt(flag) });
    if (status == .SUCCESS) return;
    if (isRefusalNt(status)) return error.Refused;
    return ntSyncFailure(status);
}

fn closeWindows(io: Io, handle: windows.HANDLE, path: ?[]const u8) Io.File.SyncError!void {
    // Whatever the hook says, the handle goes, exactly once.
    _ = decide(io, .close, path) catch .system;
    closeRouted(io, handle);
}

/// A name as NT wants it relative to `root`: WTF-16, slashes turned round.
/// A 64 KiB buffer and several copies of it in a Debug build, which is why
/// the conversion is made only where a call is made on the system, inside
/// the function that makes it: a call a route answers never needs the name
/// in NT's form, and runs on a simulation's small task stack.
fn ntName(root: windows.HANDLE, name: []const u8) Io.Dir.PathNameError!Io.Threaded.WindowsPathSpace {
    return Io.Threaded.sliceToPrefixedFileW(root, name, .{}) catch |err| switch (err) {
        error.NameTooLong => error.NameTooLong,
        else => error.BadPathName,
    };
}

/// The status a name that does not convert stands for.
fn ntNameStatus(err: Io.Dir.PathNameError) windows.NTSTATUS {
    return switch (err) {
        error.NameTooLong => .NAME_TOO_LONG,
        else => .OBJECT_NAME_INVALID,
    };
}

/// `NtCreateFile` on `name` relative to `root` (`root` itself when `name`
/// is empty).
fn ntCreate(
    handle: *windows.HANDLE,
    access: windows.ACCESS_MASK,
    root: windows.HANDLE,
    name: []const u8,
    attributes: windows.FILE.ATTRIBUTE,
    share: windows.FILE.SHARE,
    disposition: windows.FILE.CREATE_DISPOSITION,
    options: windows.FILE.MODE,
) windows.NTSTATUS {
    var nt: windows.UNICODE_STRING = .init(&.{});
    var absolute = false;
    var space: Io.Threaded.WindowsPathSpace = undefined;
    if (name.len != 0) {
        space = ntName(root, name) catch |err| return ntNameStatus(err);
        nt = space.string();
        absolute = Io.Dir.path.isAbsoluteWindowsWtf16(space.span());
    }
    const attr: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (absolute) null else root, .ObjectName = &nt };
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtCreateFile(handle, access, &attr, &iosb, null, attributes, share, disposition, options, null, 0);
}

/// A directory opened relative to `root` (`sub_path` empty: `root` itself
/// again), with the rights a flush and relative opens need.
pub fn openDirWindows(io: Io, root: windows.HANDLE, sub_path: []const u8, flush_only: bool) OpenDirError!windows.HANDLE {
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
    const status = switch (try retryingNt(io, .open_dir, sub_path, ntCreate, .{
        &handle,                                  access,
        root,                                     sub_path,
        windows.FILE.ATTRIBUTE{ .NORMAL = true }, windows.FILE.SHARE.VALID_FLAGS,
        windows.FILE.CREATE_DISPOSITION.OPEN,     windows.FILE.MODE{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
    })) {
        .code => |c| c,
        .route => |route| return (try dirOf(root).openDir(route.io, if (sub_path.len == 0) "." else sub_path, .{})).handle,
    };
    return switch (status) {
        .SUCCESS => handle,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .NOT_A_DIRECTORY => error.NotDir,
        .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
        .OBJECT_NAME_INVALID => error.BadPathName,
        .NAME_TOO_LONG => error.NameTooLong,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => error.NetworkNotFound,
        .NOT_SUPPORTED, .INVALID_DEVICE_REQUEST => error.NoDevice,
        .DISK_FULL => error.NoSpaceLeft,
        // Win32 reports a name whose file awaits deletion as access denied.
        .DELETE_PENDING => error.AccessDenied,
        else => if (isDeviceFailureNt(status)) error.InputOutput else windows.unexpectedStatus(status),
    };
}

fn makeDirWindows(io: Io, root: windows.HANDLE, name: []const u8) MakeDirError!void {
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true, .READ_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = switch (try retryingNt(io, .make_dir, name, ntCreate, .{
        &handle,                                  access,
        root,                                     name,
        windows.FILE.ATTRIBUTE{ .NORMAL = true }, windows.FILE.SHARE.VALID_FLAGS,
        windows.FILE.CREATE_DISPOSITION.CREATE,   windows.FILE.MODE{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
    })) {
        .code => |c| c,
        .route => |route| return dirOf(root).createDir(route.io, name, .default_dir),
    };
    switch (status) {
        .SUCCESS => release(io, handle),
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .NOT_A_DIRECTORY => return error.NotDir,
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_NAME_INVALID => return error.BadPathName,
        .NAME_TOO_LONG => return error.NameTooLong,
        .DISK_FULL => return error.NoSpaceLeft,
        .MEDIA_WRITE_PROTECTED => return error.ReadOnlyFileSystem,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => return error.NetworkNotFound,
        .DELETE_PENDING => return error.AccessDenied,
        else => return if (isDeviceFailureNt(status)) error.InputOutput else windows.unexpectedStatus(status),
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
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = switch (try retryingNt(io, .open_file, name, ntCreate, .{
        &handle,                                  access,
        root,                                     name,
        windows.FILE.ATTRIBUTE{ .NORMAL = true }, windows.FILE.SHARE.VALID_FLAGS,
        windows.FILE.CREATE_DISPOSITION.OPEN,     windows.FILE.MODE{ .NON_DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true },
    })) {
        .code => |c| c,
        .route => |route| return (try dirOf(root).openFile(route.io, name, .{ .path_only = true, .follow_symlinks = false })).handle,
    };
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
    return switch (try retryingNt(io, .set_mode, null, ntSetInfo, .{ handle, std.mem.asBytes(&info), .Basic })) {
        .code => |c| c,
        .route => |route| {
            fileOf(handle).setPermissions(route.io, windowsPermissions(attributes.READONLY)) catch return .ACCESS_DENIED;
            return .SUCCESS;
        },
    };
}

fn openByName(io: Io, root: windows.HANDLE, sub_path: []const u8, purpose: OpenFor) OpenFileError!windows.HANDLE {
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true, .RIGHTS = .{ .DELETE = purpose != .sync } },
        .GENERIC = .{ .WRITE = purpose == .sync },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = switch (try retryingNt(io, .open_file, sub_path, ntCreate, .{
        &handle,                                  access,
        root,                                     sub_path,
        windows.FILE.ATTRIBUTE{ .NORMAL = true }, windows.FILE.SHARE.VALID_FLAGS,
        windows.FILE.CREATE_DISPOSITION.OPEN,     windows.FILE.MODE{ .NON_DIRECTORY_FILE = purpose == .sync, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = purpose != .sync },
    })) {
        .code => |c| c,
        // A routed sync needs no write access, and a routed rename or
        // delete goes by name: a handle on the file is all either needs.
        .route => |route| return (try dirOf(root).openFile(route.io, sub_path, .{
            .allow_directory = purpose != .sync,
            .path_only = purpose != .sync,
            .follow_symlinks = purpose == .sync,
        })).handle,
    };
    return switch (status) {
        .SUCCESS => handle,
        else => openFailureNt(status),
    };
}

fn openFailureNt(status: windows.NTSTATUS) OpenFileError {
    return switch (status) {
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .OBJECT_NAME_INVALID => error.BadPathName,
        .NAME_TOO_LONG => error.NameTooLong,
        .ACCESS_DENIED => error.AccessDenied,
        .SHARING_VIOLATION => error.FileBusy,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .NOT_A_DIRECTORY => error.NotDir,
        .DISK_FULL => error.NoSpaceLeft,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => error.NetworkNotFound,
        .NO_MEDIA_IN_DEVICE => error.NoDevice,
        .VIRUS_INFECTED, .VIRUS_DELETED => error.AntivirusInterference,
        .MEDIA_WRITE_PROTECTED => error.ReadOnlyFileSystem,
        .DELETE_PENDING => error.FileBusy,
        else => if (isDeviceFailureNt(status)) error.InputOutput else windows.unexpectedStatus(status),
    };
}

fn createTempWindows(io: Io, root: windows.HANDLE, name: []const u8, read: bool) CreateTempError!windows.HANDLE {
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true, .RIGHTS = .{ .DELETE = true } },
        .GENERIC = .{ .WRITE = true, .READ = read },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = switch (try retryingNt(io, .create_temp, name, ntCreate, .{
        &handle,                                  access,
        root,                                     name,
        windows.FILE.ATTRIBUTE{ .NORMAL = true }, windows.FILE.SHARE{ .READ = true, .DELETE = true },
        windows.FILE.CREATE_DISPOSITION.CREATE,   windows.FILE.MODE{ .NON_DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
    })) {
        .code => |c| c,
        .route => |route| return createTempRouted(route, root, name, .default_file, read),
    };
    return switch (status) {
        .SUCCESS => handle,
        // The name lingers while another process holds the deleted file.
        .DELETE_PENDING => error.Busy,
        else => openFailureNt(status),
    };
}

fn setReadOnlyWindows(io: Io, handle: windows.HANDLE, read_only: bool) SetModeError!void {
    if (!read_only) return;
    var info: windows.FILE.BASIC_INFORMATION = .{
        .CreationTime = 0,
        .LastAccessTime = 0,
        .LastWriteTime = 0,
        .ChangeTime = 0,
        .FileAttributes = .{ .READONLY = true },
    };
    const status = switch (try retryingNt(io, .set_mode, null, ntSetInfo, .{ handle, std.mem.asBytes(&info), .Basic })) {
        .code => |c| c,
        .route => |route| return fileOf(handle).setPermissions(route.io, windowsPermissions(true)),
    };
    return switch (status) {
        .SUCCESS => {},
        .ACCESS_DENIED => error.AccessDenied,
        .DISK_FULL => error.NoSpaceLeft,
        .MEDIA_WRITE_PROTECTED => error.ReadOnlyFileSystem,
        else => if (isDeviceFailureNt(status)) error.InputOutput else windows.unexpectedStatus(status),
    };
}

/// Windows permissions are attributes: read-only, or not.
fn windowsPermissions(read_only: bool) Io.File.Permissions {
    return @fromBackingInt(@as(u32, @intFromBool(read_only))); // FILE_ATTRIBUTE_READONLY
}

fn ntSetInfo(handle: windows.HANDLE, info: []u8, class: windows.FILE.INFORMATION_CLASS) windows.NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtSetInformationFile(handle, &iosb, info.ptr, @intCast(info.len), class);
}

/// `FileRenameInformationEx` (`posix`) or `FileRenameInformation` on `handle`
/// to `name` in `root`. The information holds the name in a buffer of its
/// own, 64 KiB: it is built here, where the call is made.
fn ntRenameByHandle(handle: windows.HANDLE, root: windows.HANDLE, name: []const u8, replace: bool, posix_semantics: bool) windows.NTSTATUS {
    const space = ntName(root, name) catch |err| return ntNameStatus(err);
    const absolute = Io.Dir.path.isAbsoluteWindowsWtf16(space.span());
    var info: windows.FILE.RENAME_INFORMATION = .init(.{
        .Flags = if (posix_semantics)
            .{ .REPLACE_IF_EXISTS = replace, .POSIX_SEMANTICS = true, .IGNORE_READONLY_ATTRIBUTE = true }
        else
            .{ .REPLACE_IF_EXISTS = replace },
        .RootDirectory = if (absolute) null else root,
        .FileName = space.span(),
    });
    return ntSetInfo(handle, info.toBuffer(), if (posix_semantics) .RenameEx else .Rename);
}

/// How a Windows rename by handle ended.
pub const RenameOutcome = enum { renamed, collision, denied, sharing };

/// Rename the open file `handle`, named `from` in `from_dir`, to `name` in
/// `root`, by handle: `FileRenameInformationEx` with POSIX semantics,
/// falling back to `FileRenameInformation` where the filesystem or the OS
/// refuses it. `denied` and `sharing` are contention a retry may outlast:
/// NTFS reports "the target is open" as access denied. A route has no
/// rename by handle, so it renames by `from`'s name.
pub fn renameByHandle(io: Io, handle: windows.HANDLE, from_dir: windows.HANDLE, from: []const u8, root: windows.HANDLE, name: []const u8, replace: bool) RenameError!RenameOutcome {
    var status = switch (try retryingNt(io, .win_rename_ex, name, ntRenameByHandle, .{ handle, root, name, replace, true })) {
        .code => |c| c,
        .route => |route| return renameRouted(route, from_dir, from, root, name, replace),
    };
    if (status == .INVALID_PARAMETER or status == .INVALID_INFO_CLASS or status == .NOT_SUPPORTED) {
        status = statusOf(try retryingNt(io, .rename, name, ntRenameByHandle, .{ handle, root, name, replace, false }), .NOT_SUPPORTED);
        // The legacy rename will not replace a read-only target: clear the
        // attribute once and rename again.
        if (status == .ACCESS_DENIED and replace and clearReadOnly(io, root, name)) {
            status = statusOf(try retryingNt(io, .rename, name, ntRenameByHandle, .{ handle, root, name, replace, false }), .NOT_SUPPORTED);
        }
    }
    return switch (status) {
        .SUCCESS => .renamed,
        .OBJECT_NAME_COLLISION => .collision,
        .ACCESS_DENIED => .denied,
        .SHARING_VIOLATION, .DELETE_PENDING => .sharing,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .OBJECT_NAME_INVALID => error.BadPathName,
        .NAME_TOO_LONG => error.NameTooLong,
        .NOT_SAME_DEVICE => error.CrossDevice,
        .DIRECTORY_NOT_EMPTY => error.DirNotEmpty,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .NOT_A_DIRECTORY => error.NotDir,
        .DISK_FULL => error.NoSpaceLeft,
        .MEDIA_WRITE_PROTECTED => error.ReadOnlyFileSystem,
        else => if (isDeviceFailureNt(status)) error.HardwareFailure else windows.unexpectedStatus(status),
    };
}

/// A Windows rename by handle, made through a route by name: the outcomes
/// `renameByHandle` reports, from std's errors.
fn renameRouted(route: *const Route, from_dir: windows.HANDLE, from: []const u8, root: windows.HANDLE, name: []const u8, replace: bool) RenameError!RenameOutcome {
    const renamed = if (replace)
        dirOf(from_dir).rename(from, dirOf(root), name, route.io)
    else
        dirOf(from_dir).renamePreserve(from, dirOf(root), name, route.io) catch |err| switch (err) {
            error.PathAlreadyExists => return .collision,
            error.OperationUnsupported => return error.Unexpected,
            else => |e| e,
        };
    renamed catch |err| switch (err) {
        error.AccessDenied => return .denied,
        error.FileBusy => return .sharing,
        else => |e| return e,
    };
    return .renamed;
}

/// Delete the open file `handle`, named `name` in `dir`:
/// `FileDispositionInformationEx` with POSIX semantics, so the name goes
/// even while a scanner holds the file. A route has no delete by handle, so
/// it deletes by name.
pub fn dispose(io: Io, handle: windows.HANDLE, dir: windows.HANDLE, name: []const u8) UnlinkError!void {
    var flags: windows.FILE.DISPOSITION.INFORMATION.EX = .{ .Flags = .{
        .DELETE = true,
        .POSIX_SEMANTICS = true,
        .IGNORE_READONLY_ATTRIBUTE = true,
    } };
    var status = switch (try retryingNt(io, .dispose, name, ntSetInfo, .{ handle, std.mem.asBytes(&flags), .DispositionEx })) {
        .code => |c| c,
        .route => |route| return dirOf(dir).deleteFile(route.io, name),
    };
    if (status == .INVALID_PARAMETER or status == .INVALID_INFO_CLASS or status == .NOT_SUPPORTED) {
        var legacy: windows.FILE.DISPOSITION.INFORMATION = .{ .DeleteFile = .TRUE };
        status = statusOf(try retryingNt(io, .dispose, name, ntSetInfo, .{ handle, std.mem.asBytes(&legacy), .Disposition }), .NOT_SUPPORTED);
    }
    return switch (status) {
        .SUCCESS => {},
        .ACCESS_DENIED, .CANNOT_DELETE => error.AccessDenied,
        .SHARING_VIOLATION => error.FileBusy,
        .DIRECTORY_NOT_EMPTY, .FILE_IS_A_DIRECTORY => error.IsDir,
        .MEDIA_WRITE_PROTECTED => error.ReadOnlyFileSystem,
        .DISK_FULL => error.NoSpaceLeft,
        else => if (isDeviceFailureNt(status)) error.FileSystem else windows.unexpectedStatus(status),
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
    return dispose(io, handle, root, name);
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

fn statFailureNt(status: windows.NTSTATUS) StatIdError {
    return switch (status) {
        .ACCESS_DENIED => error.AccessDenied,
        else => if (isDeviceFailureNt(status)) error.InputOutput else windows.unexpectedStatus(status),
    };
}

fn statIdWindows(io: Io, handle: windows.HANDLE) StatIdError!Id {
    var id: FileIdInformation = undefined;
    const status = switch (try retryingNt(io, .stat_id, null, ntQueryInfo, .{ handle, std.mem.asBytes(&id), .Id })) {
        .code => |c| c,
        // The process's current directory is a handle of its own to a
        // simulation, which names it as a directory, not as a file.
        .route => |route| return routedId(if (handle == Io.Dir.cwd().handle) try dirOf(handle).stat(route.io) else try fileOf(handle).stat(route.io)),
    };
    switch (status) {
        .SUCCESS => return .{
            .volume = .fromRaw(id.VolumeSerialNumber),
            .file = std.mem.readInt(u128, &id.FileId, .little),
        },
        .ACCESS_DENIED => return error.AccessDenied,
        // No 128-bit ids (FAT, some redirectors): the volume's 32-bit
        // serial and the 64-bit index are what there is.
        .INVALID_PARAMETER, .INVALID_INFO_CLASS, .NOT_IMPLEMENTED, .NOT_SUPPORTED => {},
        else => return statFailureNt(status),
    }
    var volume: extern struct {
        info: windows.FILE.FS_VOLUME_INFORMATION,
        label: [64]windows.WCHAR,
    } = undefined;
    switch (ntQueryVolume(handle, std.mem.asBytes(&volume))) {
        .SUCCESS, .BUFFER_OVERFLOW => {},
        .ACCESS_DENIED => return error.AccessDenied,
        else => |s| return statFailureNt(s),
    }
    var internal: windows.FILE.INTERNAL_INFORMATION = undefined;
    switch (ntQueryInfo(handle, std.mem.asBytes(&internal), .Internal)) {
        .SUCCESS => {},
        .ACCESS_DENIED => return error.AccessDenied,
        else => |s| return statFailureNt(s),
    }
    return .{
        .volume = .fromRaw(volume.info.VolumeSerialNumber),
        .file = @as(u64, @bitCast(internal.IndexNumber)), // safe: the index is an unsigned 64-bit number stored as LARGE_INTEGER
    };
}

fn statIdPathWindows(io: Io, root: windows.HANDLE, sub_path: []const u8, follow: bool) StatPathError!Id {
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = switch (try retryingNt(io, .open_file, sub_path, ntCreate, .{
        &handle,                                  access,
        root,                                     sub_path,
        windows.FILE.ATTRIBUTE{ .NORMAL = true }, windows.FILE.SHARE.VALID_FLAGS,
        windows.FILE.CREATE_DISPOSITION.OPEN,     windows.FILE.MODE{ .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = !follow },
    })) {
        .code => |c| c,
        .route => |route| blk: {
            handle = (try dirOf(root).openFile(route.io, sub_path, .{ .path_only = true, .follow_symlinks = follow })).handle;
            break :blk .SUCCESS;
        },
    };
    if (status != .SUCCESS) return openFailureNt(status);
    defer release(io, handle);
    return statIdWindows(io, handle);
}

fn statPathWindows(io: Io, root: windows.HANDLE, sub_path: []const u8, follow: bool) StatPathError!Full {
    const access: windows.ACCESS_MASK = .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } },
    };
    var handle: windows.HANDLE = undefined;
    const status = switch (try retryingNt(io, .stat, sub_path, ntCreate, .{
        &handle,                                  access,
        root,                                     sub_path,
        windows.FILE.ATTRIBUTE{ .NORMAL = true }, windows.FILE.SHARE.VALID_FLAGS,
        windows.FILE.CREATE_DISPOSITION.OPEN,     windows.FILE.MODE{ .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = !follow },
    })) {
        .code => |c| c,
        .route => |route| return routedFull(try dirOf(root).statFile(route.io, sub_path, .{ .follow_symlinks = follow })),
    };
    if (status != .SUCCESS) return openFailureNt(status);
    defer release(io, handle);

    var info: windows.FILE.ALL_INFORMATION = undefined;
    switch (ntQueryInfo(handle, std.mem.asBytes(&info), .All)) {
        // More than the buffer holds is the name, which this does not use.
        .SUCCESS, .BUFFER_OVERFLOW => {},
        else => |s| return statFailureNt(s),
    }
    const attributes = info.BasicInformation.FileAttributes;
    var tag: u32 = 0;
    if (attributes.REPARSE_POINT) {
        var tag_info: windows.FILE.ATTRIBUTE_TAG_INFO = undefined;
        switch (ntQueryInfo(handle, std.mem.asBytes(&tag_info), .AttributeTag)) {
            .SUCCESS => {},
            else => |s| return statFailureNt(s),
        }
        tag = @bitCast(tag_info.ReparseTag);
    }
    var volume: extern struct {
        info: windows.FILE.FS_VOLUME_INFORMATION,
        label: [64]windows.WCHAR,
    } = undefined;
    switch (ntQueryVolume(handle, std.mem.asBytes(&volume))) {
        .SUCCESS, .BUFFER_OVERFLOW => {},
        else => |s| return statFailureNt(s),
    }
    // A link is a symbolic link's tag or a junction's, the two that name
    // another path; any other reparse point (a cloud placeholder, a
    // deduplicated file) is the file or directory its attributes say.
    const is_link = tag == @as(u32, @bitCast(windows.IO_REPARSE_TAG.SYMLINK)) or tag == @as(u32, @bitCast(windows.IO_REPARSE_TAG.MOUNT_POINT));
    return .{
        .kind = if (is_link) .sym_link else if (attributes.DIRECTORY) .directory else .file,
        .size = @bitCast(info.StandardInformation.EndOfFile),
        .mode = 0,
        .permissions = @fromBackingInt(@as(u32, @bitCast(attributes))),
        .mtime = windows.fromSysTime(info.BasicInformation.LastWriteTime),
        .ctime = windows.fromSysTime(info.BasicInformation.ChangeTime),
        .birth = windows.fromSysTime(info.BasicInformation.CreationTime),
        .inode = @bitCast(info.InternalInformation.IndexNumber),
        .device = volume.info.VolumeSerialNumber,
        .uid = 0,
        .gid = 0,
        .attributes = @bitCast(attributes),
        .reparse_tag = tag,
    };
}

/// `FILE_REMOTE_DEVICE`: the device is another machine's.
const windows_remote_device = 0x10;

fn ntQueryVolumeClass(handle: windows.HANDLE, buf: []u8, class: windows.FS_INFORMATION_CLASS) windows.NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtQueryVolumeInformationFile(handle, &iosb, buf.ptr, @intCast(buf.len), class);
}

fn volumeWindows(io: Io, handle: windows.HANDLE) VolumeError!VolumeInfo {
    var device: extern struct { device_type: u32, characteristics: u32 } = undefined;
    const status = switch (try retryingNt(io, .statfs, null, ntQueryVolumeClass, .{ handle, std.mem.asBytes(&device), .Device })) {
        .code => |c| c,
        .route => return .{ .remote = false },
    };
    if (status != .SUCCESS) return statFailureNt(status);
    var info: VolumeInfo = .{ .remote = device.characteristics & windows_remote_device != 0 };
    var attribute: extern struct { attributes: u32, max_component: i32, name_bytes: u32, name: [32]u16 } = undefined;
    switch (ntQueryVolumeClass(handle, std.mem.asBytes(&attribute), .Attribute)) {
        .SUCCESS, .BUFFER_OVERFLOW => {},
        else => |s| return statFailureNt(s),
    }
    const units = @min(attribute.name_bytes / 2, attribute.name.len);
    var name: [32]u8 = undefined;
    var n: usize = 0;
    // File system names are ASCII ("NTFS", "ReFS", "FAT32"); anything else
    // is kept as a question mark.
    for (attribute.name[0..units]) |unit| {
        if (n == name.len) break;
        name[n] = if (unit < 0x80) @intCast(unit) else '?';
        n += 1;
    }
    info.setName(name[0..n]);
    return info;
}

/// Windows: a 64-bit hash of the volume's NT device name
/// (`\Device\HarddiskVolumeN`), which tells apart two volumes that share a
/// serial (cloned VHDs and VM images keep it).
pub fn volumeName(io: Io, handle: windows.HANDLE) StatIdError!DeviceId {
    if (seam.hookOf(io)) |hook| {
        if (hook.call(hook.ctx, .volume_name, null)) |r| switch (r) {
            .value => |v| return .fromRaw(v),
            .canceled => return error.Canceled,
            .code => |c| if (c != success) return statFailureNt(c),
        };
        // A route's file system is one volume, with no name to hash.
        if (hook.route != null) return .fromRaw(0);
    }
    var buf: extern struct { len: u32, name: [60]u16 } = undefined;
    const status = ntQueryInfo(handle, std.mem.asBytes(&buf), .VolumeName);
    switch (status) {
        .SUCCESS, .BUFFER_OVERFLOW => {},
        .ACCESS_DENIED => return error.AccessDenied,
        // A filesystem that will not say: one name for all of them, so the
        // serial alone decides, as before the name was asked.
        .INVALID_PARAMETER, .INVALID_INFO_CLASS, .NOT_IMPLEMENTED, .NOT_SUPPORTED => return .fromRaw(0),
        else => return statFailureNt(status),
    }
    const chars = @min(buf.len / 2, buf.name.len);
    return .fromRaw(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(buf.name[0..chars])));
}

test "blocking hook captures Darwin errno before leaving its worker" {
    if (!is_darwin) return error.SkipZigTest;
    const testing = std.testing;
    const test_seam = @import("airlock.testing");
    const Adapter = struct {
        fn work(function: *const fn (*anyopaque) void, argument: *anyopaque) void {
            function(argument);
        }

        fn run(io: Io, context: ?*anyopaque, function: *const fn (*anyopaque) void, argument: *anyopaque) Io.Cancelable!void {
            _ = context;
            try io.checkCancel();
            const worker = std.Thread.spawn(.{}, work, .{ function, argument }) catch @panic("test worker unavailable");
            worker.join();
            // Deliberately leave a different errno on the calling thread.
            std.c._errno().* = @backingInt(posix.E.NOSPC);
        }
    };
    const h = try test_seam.Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const code = try retryingSync(h.io(), .{ .run = Adapter.run }, .sync_full, null, -1, .full, darwinFcntl, .{ @as(posix.fd_t, -1), darwin_full_fsync });
    try testing.expectEqual(posix.E.BADF, code);
    try testing.expectEqual(1, h.syncs());
}
