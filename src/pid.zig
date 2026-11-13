//! A lock holder file's process id, read as git's `read_lock_pid` (lockfile.c) reads it: the file
//! right-trimmed of C's white space and taken as a C string, to its first NUL; then `pid `; then
//! what `strtoumax` takes whole in base 10 (white space, a `+`, the digits). airlock names no
//! process where git's reading names none a system gives: a `-` (git's value wraps, and its
//! `kill` of -1 would ask after every process), a value past u32, 0, and a file longer than git's
//! LOCK_PID_MAXLEN, 32 bytes, more than git writes.
const std = @import("std");

/// The longest holder file read, git's LOCK_PID_MAXLEN: one longer names no process.
pub const max_len = 32;

/// What a holder file names.
pub const Pid = struct { pid: u32 };

/// C's `isspace` in the C locale.
pub fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r' => true,
        else => false,
    };
}

/// The process a holder file's bytes name, as git reads them; `error.NotAPid` where they name none.
pub fn parse(_: void, text: []const u8) error{NotAPid}!Pid {
    if (text.len > max_len) return error.NotAPid;
    var end = text.len;
    while (end > 0 and isSpace(text[end - 1])) end -= 1;
    var line = text[0..end];
    if (std.mem.indexOfScalar(u8, line, 0)) |nul| line = line[0..nul];
    if (!std.mem.startsWith(u8, line, "pid ")) return error.NotAPid;
    var at: usize = "pid ".len;
    while (at < line.len and isSpace(line[at])) at += 1;
    if (at < line.len and line[at] == '+') at += 1;
    if (at == line.len) return error.NotAPid;
    var pid: u32 = 0;
    for (line[at..]) |c| {
        if (c < '0' or c > '9') return error.NotAPid;
        pid = std.math.mul(u32, pid, 10) catch return error.NotAPid;
        pid = std.math.add(u32, pid, c - '0') catch return error.NotAPid;
    }
    if (pid == 0) return error.NotAPid;
    return .{ .pid = pid };
}
