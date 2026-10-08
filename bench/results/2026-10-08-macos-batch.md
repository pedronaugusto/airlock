# 2026-10-08: macOS batch follow-up

Zig 0.17.0, ReleaseFast, before = airlock `e57408da926be35ccc1c3fadbaca3fe82f2dc0ed`.
The native machine is macOS 26.2 (25C56), ARM64 Mac15,8, 16 logical CPUs,
internal Apple SSD, APFS Data volume. A fresh 2 GiB sparse APFS disk image
provides a second filesystem/device ID on that same physical SSD. It is not
an external-drive test. Linux is the local Lima `bench` VM: Ubuntu 24.04.5,
ARM64 Linux 6.8.0-142, 8 vCPUs, ext4, io_uring enabled. Windows benchmark code
is compiled in CI; no hosted-runner timings are recorded.

## Hypothesis: one expensive full sync, not N drains

The per-call probe supports the cost observation for **closed and reopened**
files. It does not establish APFS's internal transaction boundaries. All 100
4 KiB files are written before syncing; every raw call's duration is retained.
Fresh directories and their setup flush are outside the measured workload.
The strategies rotate over nine repetitions; the two volumes run separately.

| Strategy | Internal best total, ms | Image best total, ms |
|---|---:|---:|
| Writes only, no durability | 6.664 | 7.597 |
| Close all, reopen read-only, full sync each + directory | 12.049 | 25.037 |
| Close all, reopen read-write, full sync each + directory | 12.377 | 26.644 |
| Full sync every retained writing handle + directory | 413.187 | 1,067.388 |
| Same, reverse file order | 407.272 | 719.521 |
| First writing handle full, remaining handles plain, directory full | 16.250 | 34.364 |
| Barrier every writing handle, directory full | 86.520 | 1,074.467 |
| Plain writeout each, directory full | 13.377 | 28.227 |
| Full sync writing handles, parallel 16, directory full | 139.231 | 358.411 |
| Writeouts, parallel 16, directory full | 11.272 | 27.487 |
| Writeout all first, then full sync each writing handle + directory | 12.329 | 23.128 |

For reopened read-only descriptors, the median first full sync is **4,011 us**
internally and **19,332 us** on the image. The remaining 99 calls together
cost **62 us** and **58 us**. Reopening read-write gives the same shape:
4,163 / 19,206 us first, then 54 / 53 us total. Access mode does not explain it.
After explicitly writing all files out on their writing handles, the full
sync series also becomes cheap: first 4,247 / 10,177 us, remaining 99 total
65 / 61 us. Retaining writing handles without those writeouts instead costs
hundreds of milliseconds, even after the first full sync and with reversed
order. Therefore “the first full sync commits every still-dirty open file”
is too strong. Closing or explicit writeout changes the observed behavior.

The old serial plain writeouts are measurable: the first takes 95 / 44 us,
then the remaining 99 total **3,168 / 13,499 us**. That supports overlapping
writeouts, but not the precise claim that every call commits a separate APFS
transaction or costs 11 us. These are syscall timings, not a count of physical
cache drains or an APFS transaction trace. Timing identifies the cost shape;
it cannot prove the mechanism. System-wide tracing was unavailable without
administrator access.

Correctness uses the documented guarantee, not that inference. Apple's
[fcntl manual](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/fcntl.2)
says a full sync persists earlier fsync'd data on the same device; its barrier
recipe is to fsync every descriptor before issuing a barrier. Every writing
handle still gets its own writeout and error check. A different file's full
sync alone is not used as a substitute.

The write-only floor also refutes a universal 10x expectation against a
write-all-then-sync loop: a roughly 12 ms baseline with at least 6.7 ms of
writing cannot become 1.2 ms by removing sync calls. The earlier 43.25x result
against flush-as-you-go is a different workload.

## Selected strategy

Darwin now overlaps plain per-file writeouts in bounded `Io.Group`s, using
`parallel` (default 16). Each worker owns one slot and uses its writing handle,
including a pending's writer flush and file identity. The calling task alone
registers volumes and folds failures in add order after joining the group.
Paths are folded and their handles closed before opening another group, so
only `parallel` plus retained volume representatives need stay open. If the
Io cannot provide concurrency, the same work runs inline.

No filesystem-name or drive-vendor heuristic is needed: the API-guaranteed
sequence remains N file writeouts, one pre-publish barrier per volume, renames
and fences in add order, distinct-directory writeouts, then one full flush per
volume. Per-file errors, refusal, cancellation, synced retries, close errors,
and volume identity are retained. No worker mutates the volume table. Linux
and Windows retain their strategies. Append and single-file sync are untouched.

| Parallelism, 100 x 4 KiB | Internal raw baseline / batch, best ms | Image raw baseline / batch, best ms |
|---|---:|---:|
| 4 | 11.309 / 11.253 | 26.372 / 28.066 |
| 16 | 10.350 / 10.371 | 27.247 / 26.162 |
| 64 | 10.462 / 10.378 | 27.137 / 27.250 |

These are nine rotated repetitions per combination. The default 16 matches
the fastest contract-correct internal baseline within **0.2%**, and beats the
best raw parallel baseline on the image. Wider groups do not improve both
volumes. Across separate diagnostic phases the image's lowest sequential
writeout/full-each sample is 23.128 ms versus an initial 15-repeat batch pass's
23.316 ms (0.8%); the paired comparison below also matches or beats it. These
small differences are measurement variation, not a universal latency bound.

## Source A/B

The same common driver alternates before and after executables seven times,
reversing workload and executable order on alternate repetitions. Values are
the best complete sample, including creates, writes, identity, commit and
close; they are not combinations of best individual calls. Preparatory
allocation and setup flushes are outside the timer.

| Workload | Internal before -> after, ms | Image before -> after, ms |
|---|---:|---:|
| 10 x 4 KiB writing handles + directory | 4.907 -> 4.856 | 10.996 -> 11.887 |
| 100 x 4 KiB writing handles + directory | **12.162 -> 10.111** | **23.993 -> 24.099** |
| 100 x 64 KiB writing handles + directory | 13.088 -> 10.266 | 36.199 -> 22.379 |
| 1000 x 4 KiB writing handles + directory | 77.734 -> 60.638 | 181.023 -> 162.758 |
| 100 x 4 KiB pending publishes | 19.080 -> 17.062 | 42.000 -> 43.119 |
| 100 x 64 KiB pending publishes | 19.945 -> 17.918 | 45.986 -> 51.834 |
| 100 x 4 KiB paths + directory | 13.811 -> 11.176 | 26.380 -> 24.155 |

These are the final implementation's seven alternating repetitions, after
ensuring the serial registration helper is inlined and retains its existing
subject argument. The earlier seven-repeat prototype A/B is retained as
`initial-ab` in the same data file; final values are labelled `final-ab`.
The 100-file writing-handle throughput improves **20.3% internally** and is
within **0.4% on the image**. Final paired raw contract baselines are 11.069 ms
internally (parallel writeout) and 25.267 ms on the image (parallel writeout);
the batch is faster than both. The initial A/B saw an image improvement from
25.207 to 24.249 ms and a 4.4% slower path sample. In the final A/B the image
10-file and 100-file pending rows instead have slower best samples (7.5%,
2.6% and 11.3% respectively); their full ranges overlap. Sparse-image flush
and allocation times vary substantially. These samples are disclosed rather
than claimed as a universal improvement. A fresh path descriptor still has
the documented writeback-error limitation and is not the writing-handle
acceptance baseline.

A batch spanning internal APFS and the image checks that the two directory
volume IDs really differ. The separate shakedown audit observes **102 W + 2 F**
for 100 borrowed writing handles plus both directories. Timed rows also
exercise 100 mixed-volume pending publishes. The image and internal disk
share the physical device, so those timings include nested image flushes.

## Linux and Windows

The Linux production branch compiles away the Darwin scheduling addition.
An initial seven-repeat VM pass returned lower best throughput (5.5% to 18.0%
for batches); the negative samples are retained. A longer 21-repeat alternating
pass resolved that concern:

| Linux ext4 workload | Before -> after, best files/s (append: ops/s) |
|---|---:|
| 100 x 4 KiB files, p1 | 5,226.3 -> 5,247.6 (+0.4%) |
| 100 x 4 KiB files, p16 | 17,452.9 -> 18,257.9 (+4.6%) |
| 100 x 64 KiB files, p16 | 11,873.6 -> 12,204.2 (+2.8%) |
| 100 x 4 KiB renames, p16 | 15,432.0 -> 15,001.3 (-2.8%) |
| 100 x 4 KiB paths, p16 | 26,627.2 -> 27,721.9 (+4.1%) |
| Full append | 5,240.9 -> 5,054.0 (-3.6%) |

The decisive control is binary comparison: both Linux benchmark executables
have exactly identical `.text` (650,996 bytes, SHA-256
`91e9888d3eea09f35ff337225b38b5815dd12dbabe244bccecfcdc159a9c0ae8`)
and `.rodata` (105,184 bytes, SHA-256
`ae3457b930543ac25daf7612ca3a1a9221453769c5e8a1380969b89fb1110f30`).
All throughput ranges overlap; append medians are 4,704.0 vs 4,700.9 ops/s.
These fluctuations cannot be a changed Linux instruction path. Windows's
serial writeout/flush sequence and deterministic counts remain unchanged;
Windows cross-compilation passes, and hosted merge CI checks its tests.

## Tests and revised Acceptance 3

The new scheduling test first fails against the before code (zero scheduled
group calls), then passes with bounded scheduling and forced
ConcurrencyUnavailable. Shakedown checks failed and canceled concurrent
writeouts, first-slot failure attribution with no publishes, and refusal
without promoting an unsynced file. The Linux/Darwin multiset test compares
p1 with p16. Existing descriptor-budget, fence, kept-file, synced-retry,
barrier-count, hook and exhaustive single-fault batch tests pass. Lint, native
check and Windows cross-compilation pass. Timing is never a CI gate.

Recommended replacement for the book's Acceptance 3:

> On macOS, write-all-then-sync batches at N = 100 must match or beat the
> fastest documented, contract-correct writing-handle strategy at the same
> Reached, within measured noise, on internal APFS and a second volume.
> Preserve per-file writeback-error checks and identify every volume.
> Measure flush-as-you-go separately; a 10x gain is a workload-specific target
> when device flushes dominate. Report syscall counts and per-call timing,
> without equating N full-sync calls with N physical drains.

The book is not edited here. Its batch sequence needs concurrent Darwin
writeouts and its Acceptance 3 needs the workload distinction above. Its
barrier counts still hold. The repo note's root revision is stale.

## Data and reproduction

Build with `zig build bench`; invoke `zig-out/bench/airlock-macos-batch` with
`--dir`, `--filter`, `--n`, `--size`, `--parallel`, `--rounds`. For two volumes,
add `--other-dir` and select `batch`, `paths` or `pending`; `--audit` with a
two-volume `batch` records seam counts separately from uninstrumented timings.
Alternating original/current executables use the common driver. No timing is
taken by `--smoke`. Keep samples from different processes in separate output
files or pipe them to a collector; concatenating the resulting JSONL is safe.

- [Internal strategies and every raw call](2026-10-08-macos-batch-strategies-internal.jsonl)
- [APFS image strategies and every raw call](2026-10-08-macos-batch-strategies-image.jsonl)
- [Parallelism comparison](2026-10-08-macos-batch-parallel.jsonl)
- [Alternating source A/B](2026-10-08-macos-batch-ab.jsonl)
- [Two-volume rows and separate count audit](2026-10-08-macos-batch-volumes.jsonl)
- [Both Linux sample series](2026-10-08-macos-batch-linux.jsonl)
