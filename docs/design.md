# airlock design

## Batch ownership and durability

Every writing handle gets its own writeout and error check. A full sync of a
different file alone does not replace that check. Reopened paths cannot recover
writeback errors already reported to a previous descriptor; they are a separate
benchmark contract from retained writing handles.

On Darwin, bounded `Io.Group`s overlap per-file writeouts. Each worker owns one
slot; the caller joins the group, registers volumes and folds failures in add
order. No worker mutates the volume table. Paths are folded and closed before
another group opens, bounding handles by `parallel` plus retained volume
representatives. If concurrency is unavailable, the work runs inline.

The durability sequence is per-file writeouts, a pre-publish barrier per volume,
renames and fences in add order, distinct-directory writeouts, and a full flush
per volume. Per-file errors, refusal, cancellation, synced retries, close errors
and volume identity remain part of the contract. Raw sync-call counts describe
calls, not physical cache drains or filesystem transaction boundaries.

## Benchmark workloads

`zig build bench` builds and runs the rows in ReleaseFast. The installed
`zig-out/bench/airlock-bench` accepts a row prefix and `--dir <parent>` to
select a disk. It creates and removes only its own random child of that parent.
Each row gets an empty directory; overwrite rows first create their target.
`--smoke` returns after parsing: hosted CI compiles every row without taking
measurements. The manual Windows interface below runs separately from those checks.

Rows cover raw primitives; syncs at each level; new and overwrite publishes
at 4 KiB and 1 MiB; batches of 1, 10, 100 and 1000 files at 4 and 64 KiB,
with renames, writing handles and paths; Linux parallelism 1, 4, 16 and 64;
name operations; append and migration baselines; and inline versus an
application-supplied Threaded executor. macOS uses p1 and p16; both Linux data syncs and macOS writeouts now honor
`parallel`.

Primitive probes dirty 4 KiB before starting the timer, then time only the
sync; directory probes similarly create an entry before timing its sync.
Publish and batch rows include creation, writing, commit and handle cleanup.
Their latency is per operation/batch, while `per_second` counts files for
batch rows. Probes take 1000 samples; replace takes 200 at 4 KiB and 50 at
1 MiB; batches take 20 at N < 100 and 3 otherwise. Small batch samples give
throughput, not a statistically strong tail estimate. Append comparisons
write successive 4 KiB records outside the timer and compare full syncs at
the same reached level.

W, B and F count writeouts, barriers and device flush calls. `raw_calls`
counts only airlock's seam events, excluding std-shaped opens/writes and
executor scheduling. Counts are collected separately, outside the timer.
Raw probes count their one primitive directly. A baseline bypassing airlock's
seam has `counts_available: false`; its zero fields are not syscall counts.
The batch flush-each row uses airlock and is counted. Deterministic tests
assert the design's barrier counts; CI never gates latency or throughput.

The starting cost budget is one device flush rather than N: with a roughly
4 ms flush and 20 us writeout, N = 100 costs about 400 ms when each dirty
file is flushed immediately, versus 4 ms + 100 writeouts plus opens, writes
and identity calls for a batch. Linux instead retains N data syncs and
expects concurrent filesystem journal commits to share flushes. Device,
filesystem and dirty-handle behavior determine whether those estimates hold.

## macOS batch strategies

`airlock-macos-batch` isolates write-all-then-sync strategies and emits the
write, sync and close times separately, plus every raw file-sync duration.
It accepts `--dir`, `--rounds` (default 9), `--n` (100), `--size` (4096),
`--parallel` (16) and `--filter <strategy>`. A fresh directory is created for
every sample; its setup flush is outside the timer. Strategies rotate between
rounds. All contract baselines identify each writing handle's volume, sync
that handle and fully sync its parent. `writes` has no durability; reopened
rows are references with the documented fresh-descriptor error limitation.
`writeout_full_each` writes every file out before its full-sync series;
`writeout_parallel` overlaps writeouts in bounded groups then fully syncs the
directory. `batch`, `pending` and `paths` exercise the public API. None of the
raw strategies hides primitive refusal behind a fallback.

`--other-dir <parent on a different volume>` splits the public batch, pending
or path rows between two verified distinct volume IDs, including both parents.
It can use the internal APFS disk and a mounted APFS image together.
`--audit` on the two-volume `batch` row checks 102 W + 2 F for N=100
through shakedown; those instrumented timings are separate from timed rows. The image
is still backed by the internal disk, so it is a second filesystem, not an
independent external-device test. `--smoke` takes no measurements on any OS.

## Manual hosted Windows benchmarks

Dispatch the existing workflow with
`gh workflow run ci.yml --ref <branch-or-main> -f windows-bench=true`.
It runs the own suite with Zig 0.17.0 and explicit ReleaseFast on
`windows-latest`, retaining all emitted JSONL, stderr, exit status and runner
metadata as an Actions artifact. It changes neither the preflight planner nor
its fast/merge/release matrices. Ordinary CI still compiles and smoke-runs only.

These are **indicative hosted-runner numbers, not a target check**. Shared CPU,
virtual storage and load vary; this manual job has no timing thresholds and
cannot establish an idle-hardware durability or throughput target. The Windows
symlink timing/count rows explicitly report `skipped`: the public operation
returns `OperationUnsupported`. The macOS strategy program emits no rows on
Windows because its strategies require Darwin primitives. Raw primitive
refusals remain refusal records, without fabricated latencies.
