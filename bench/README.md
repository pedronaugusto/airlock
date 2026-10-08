# Durability measurements

`zig build bench` builds and runs the rows in ReleaseFast. The installed
`zig-out/bench/airlock-bench` accepts a row prefix and `--dir <parent>` to
select a disk. It creates and removes only its own random child of that parent.
Each row gets an empty directory; overwrite rows first create their target.
`--smoke` returns after parsing: hosted CI compiles every row without taking
measurements. Windows timings are deliberately absent.

Rows cover raw primitives; syncs at each level; new and overwrite publishes
at 4 KiB and 1 MiB; batches of 1, 10, 100 and 1000 files at 4 and 64 KiB,
with renames, writing handles and paths; Linux parallelism 1, 4, 16 and 64;
name operations; append and migration baselines; and inline versus an
application-supplied Threaded executor. macOS uses p1 and p16 (parallelism
only changes Linux's sync scheduling).

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

[results/2026-10-08.md](results/2026-10-08.md) records the native macOS and
local Lima Linux results, acceptance verdicts and the hook A/B against main
before this change. JSONL files beside it retain the complete rows and
repetitions. The XFS results are from an isolated loop image inside the VM;
neither that image nor the ext4 virtual disk represents a physical NVMe XFS
release measurement. No external non-Apple SSD was available for the
barrier-support probe.
