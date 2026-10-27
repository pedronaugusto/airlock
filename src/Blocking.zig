//! An optional executor for raw blocking sync calls. airlock owns neither
//! threads nor queues; applications supply an adapter from their runtime.
const std = @import("std");
const Io = std.Io;

const Blocking = @This();

/// Execute `job` exactly once and wait for it to finish. The job is
/// borrowed stack storage: never retain it. A started job must finish
/// before returning success, even if cancellation arrives while it runs.
/// Return `Canceled` only when the job never started; this keeps a
/// completed syscall's error from being hidden by cancellation. Scheduling
/// and cancellation use the calling task's `io`. The job itself makes no Io
/// calls and captures errno on its executing thread. Concurrent batches may
/// call `run` concurrently.
///
/// A runner with state of its own embeds its `Blocking` and finds itself
/// from `self` with `@fieldParentPtr`; one without ignores `self`.
run: *const fn (self: *Blocking, io: Io, job: *Job) Io.Cancelable!void,

/// One raw call for a runner to make: embedded in the call's own state,
/// which its function finds from the `Job` with `@fieldParentPtr`.
pub const Job = struct {
    /// Private: the call.
    runFn: *const fn (job: *Job) void,

    /// Makes the call, on the thread that calls this.
    pub fn execute(job: *Job) void {
        job.runFn(job);
    }
};
