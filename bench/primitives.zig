//! Raw primitives for the probe; no fallback can hide a refused primitive.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const linux = std.os.linux;
const windows = std.os.windows;

pub const Kind = enum { fsync, fdatasync, full, barrier, nt_full, nt_data, nt_writeout, nt_write_data };
pub const Error = error{ Refused, InputOutput };

extern "ntdll" fn NtFlushBuffersFileEx(windows.HANDLE, windows.ULONG, ?*anyopaque, windows.ULONG, *windows.IO_STATUS_BLOCK) callconv(.winapi) windows.NTSTATUS;

pub fn sync(handle: Io.File.Handle, kind: Kind) Error!void {
    if (builtin.os.tag == .windows) {
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        const status = switch (kind) {
            .nt_full => windows.ntdll.NtFlushBuffersFile(handle, &iosb),
            .nt_write_data => NtFlushBuffersFileEx(handle, 1, null, 0, &iosb),
            .nt_data => NtFlushBuffersFileEx(handle, 4, null, 0, &iosb),
            .nt_writeout => NtFlushBuffersFileEx(handle, 2, null, 0, &iosb),
            else => unreachable,
        };
        return switch (status) {
            .SUCCESS => {},
            .INVALID_PARAMETER, .NOT_SUPPORTED, .INVALID_DEVICE_REQUEST => error.Refused,
            else => error.InputOutput,
        };
    }
    while (true) {
        // Read errno on this thread, immediately after the syscall.
        const code = if (builtin.os.tag == .linux) linux.errno(switch (kind) {
            .fsync => linux.fsync(handle),
            .fdatasync => linux.fdatasync(handle),
            else => unreachable,
        }) else std.c.errno(switch (kind) {
            .fsync => std.c.fsync(handle),
            .fdatasync => std.c.fdatasync(handle),
            .full => std.c.fcntl(handle, std.c.F.FULLFSYNC, @as(c_int, 0)),
            .barrier => std.c.fcntl(handle, std.c.F.BARRIERFSYNC, @as(c_int, 0)),
            else => unreachable,
        });
        switch (code) {
            .SUCCESS => return,
            .INTR => continue,
            .INVAL, .NOSYS, .ROFS, .NOTTY, .OPNOTSUPP => return error.Refused,
            else => return error.InputOutput,
        }
    }
}
