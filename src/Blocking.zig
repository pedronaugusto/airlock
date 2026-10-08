//! An optional executor for raw blocking sync calls. airlock owns neither
//! threads nor queues; applications supply an adapter from their runtime.
const std = @import("std");
const Io = std.Io;

/// Borrowed until the airlock call returns. Concurrent batches may invoke
/// `run` concurrently, so shared context must support that.
context: ?*anyopaque = null,

/// Execute `function(argument)` exactly once and wait for it to finish.
/// The function and argument are borrowed stack storage: never retain them.
/// A started job must finish before returning success, even if cancellation
/// arrives while it runs. Return `Canceled` only when the job never started;
/// this keeps a completed syscall's error from being hidden by cancellation.
/// Scheduling and cancellation use the calling task's `io`. The function
/// itself makes no Io calls and captures errno on its executing thread.
run: *const fn (io: Io, context: ?*anyopaque, function: *const fn (*anyopaque) void, argument: *anyopaque) Io.Cancelable!void,
