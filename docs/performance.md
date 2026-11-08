> Historical results: this report measures the previous 64 MiB default with memory-only SQLhevi
> temporary storage. The current default is 512 MiB with a matching hard limit and local io_uring
> scratch. These timings and OOM counts do not describe the current build; see [spill validation](spill.md).

# Performance and the 64 MiB SQLite pool

Measured on 2026-11-08 with the pinned, unchanged SQLite 3.55.0 development source.
Historical names were normalized during the project rename; see the
[evidence provenance note](test-results/README.md). These are not new performance measurements.

**The pool did not materially slow these ordinary read/write workloads, but it imposed a sharp
query-capacity limit.** A join materializing 20 MiB of payload succeeded; 24 MiB failed with
`SQLiteMemory`. Both the actual SQLhevi SQL/Pager and the three-process VSR cluster rolled back
the failed request and continued serving queries. Plain SQLite completed larger joins using
either more heap memory or temporary files.

The much larger latency difference between SQLhevi and embedded SQLite appears at only 2–3 MiB
of SQLite allocations, well below the pool limit. Private connection setup, cache-miss replay,
the paged adapter, and (for the cluster) replication are separate costs. This experiment does
not isolate the exact CPU contribution of each of them.

## Ordinary reads and writes

Host results below are **microseconds per request**, the median of four per-run p50 values.
Each run uses a fresh process. The three SQLite columns run the same baseline executable,
with only the allocator configuration changed. All use an in-memory database and memory-backed
temporary results. SQLhevi uses its actual production Engine and Pager with a bounded RAM
image standing in for its LSM; this column excludes replication and durable I/O.

| Workload | SQLite system allocator | SQLite 64 MiB pool | SQLite 256 MiB pool | SQLhevi SQL/Pager |
|---|---:|---:|---:|---:|
| point_read | 2.33 | 2.14 | 2.14 | 272.57 |
| point_write | 6.84 | 5.86 | 6.22 | 294.40 |
| batch_write_256 | 40.41 | 35.34 | 35.50 | 449.00 |
| scan_4096 | 207.72 | 182.48 | 185.76 | 5154.24 |
| eight_way_join | 1159.90 | 1121.88 | 1124.62 | 14014.51 |

The 64 and 256 MiB pools were similar on these small requests. None exhausted the pool.
The 64 MiB pool was also competitive with the system allocator. Differences of a few percent
are not evidence of a general speed advantage: CPU frequency and other host activity were
not controlled.

For the SQLhevi adapter, a point request took four SQL execution attempts; a scan or eight-way
join took 21 attempts. Each attempt opens and closes a private SQLite connection. A miss
causes another attempt after fetching approximately one 64 KiB page. The baseline keeps its
connection and page cache across requests. It still prepares/finalizes SQL and begins/commits
a transaction for every request; it does not reuse prepared statements.

Observed serial throughput, **requests per second**, calculated from total timed requests divided
by their summed elapsed time (a batch request updates 256 rows):

| Workload | SQLite system allocator | SQLite 64 MiB pool | SQLhevi SQL/Pager |
|---|---:|---:|---:|
| point_read | 413754 | 447943 | 3577 |
| point_write | 142753 | 158201 | 3308 |
| batch_write_256 | 14206 | 14835 | 1827 |
| scan_4096 | 4853 | 5381 | 190 |
| eight_way_join | 858 | 892 | 71 |

Batch-write p95 is substantially higher than its median; all samples are included in total
throughput. This test does not separately attribute those outliers. Raw logs and
[host-summary.csv](test-results/performance/host-summary.csv) include both mean and tail measurements.

## Materialized join pressure

The fixture contains 4,096 indexed rows with 256-byte payloads, plus a separate guard row.
The stress request is:

```sql
UPDATE guard SET v = v + 1;
WITH j AS MATERIALIZED (
  SELECT a.id AS aid, b.id AS bid, zeroblob(1024) AS payload
  FROM bench a CROSS JOIN bench b
  WHERE a.id <= 128 AND b.id <= :width
)
SELECT sum(length(payload)) FROM j;
```

Widths 32, 64, 128, 160, 192, 256, 512, 768, and 1024 materialize 4–128 MiB
of **raw payload**, before record, page, and allocator overhead. The aggregate returns one
integer, so output limits do not confound memory exhaustion. The source database is small
enough to avoid the separate 31 MiB read-set bound. The update and join are one atomic request.

Peak SQLite allocation totals from the host runs:

| Raw join payload | Plain SQLite, system allocator | SQLite, 256 MiB pool | SQLhevi, 64 MiB pool |
|---|---:|---:|---:|
| 4 MiB | 7.29 MiB; succeeds | 13.68 MiB; succeeds | 13.06 MiB; succeeds |
| 16 MiB | 24.44 MiB; succeeds | 45.80 MiB; succeeds | 45.17 MiB; succeeds |
| 20 MiB | 30.14 MiB; succeeds | 56.49 MiB; succeeds | 55.87 MiB; succeeds |
| 24 MiB | 35.91 MiB; succeeds | 67.25 MiB; succeeds | OOM at 63.01 MiB |
| 32 MiB | 47.31 MiB; succeeds | 88.63 MiB; succeeds | OOM |
| 64 MiB | 93.05 MiB; succeeds | 174.30 MiB; succeeds | OOM |
| 96 MiB | 138.91 MiB; succeeds | OOM at 252.05 MiB | OOM |
| 128 MiB | 184.52 MiB; succeeds | OOM | OOM |

Plain SQLite with the **64 MiB pool** had the same success/failure boundary as SQLhevi.
A larger pool moves the boundary; it does not remove it. The 20–24 MiB boundary is specific to
this query, schema and build, not a universal maximum join size.

SQLite's memsys5 allocator rounds blocks to powers of two and stores allocator bookkeeping
inside its supplied heap. For example, the 24 MiB query consumed 67.25 MiB under memsys5 but
35.91 MiB with the system allocator. Thus a 64 MiB reservation is not 64 MiB of usable SQL
payload. See the unchanged [mem5.c](../dependencies/sqlite/src/mem5.c) and
[SQLite memory documentation](https://sqlite.org/malloc.html).

SQLhevi forces memory-backed temporary storage and has no disk-spill fallback. Its larger
queries fail; their failure latencies must not be compared as successful-query throughput.
An eight-table indexed join succeeds with about 2.20 MiB of SQLite allocations, demonstrating
that join count alone does not predict memory use.

After **every** pressure request the driver verifies the guard value and a point read.
A successful join must increment the guard once; a failed join must leave it unchanged.
The production-engine harness also asserts that audited live SQLite allocations return to
zero after every request. Final checks validate the table count/payload sum and perform another
write. Separate post-pressure read/write measurements remain in the logs.

## Native cluster and temporary-file behavior

Three fresh QEMU TCG runs used a 6 GiB, two-vCPU Linux guest, real io_uring, TCP loopback,
and ext4. Each replica had a 1 GiB backing-storage budget. Plain SQLite used the same guest
and filesystem, with WAL and `synchronous=FULL`. Its MEMORY and FILE columns refer to
**temporary results**, not the durability of the main database. The baseline and cluster
ran sequentially; all three replicas shared the guest and its disk.

**These are software-emulated timings, not hardware throughput claims.** Mean elapsed time
per request across three runs, in **milliseconds**:

| Workload | SQLite WAL/FULL, temp MEMORY | SQLite WAL/FULL, temp FILE | SQLhevi, three replicas |
|---|---:|---:|---:|
| point_read | 0.12 | 0.09 | 30.30 |
| point_write | 13.11 | 11.03 | 29.99 |
| batch_write_256 | 21.11 | 17.65 | 45.10 |
| scan_4096 | 4.76 | 3.37 | 110.99 |
| eight_way_join | 20.42 | 17.14 | 284.12 |

The cluster achieved approximately 33 serial point reads or writes per second in this VM.
Its tick-based client/server loops, CPU emulation, durable quorum work and checkpointing all
contribute to latency. Reads also go through VSR. These numbers cannot isolate allocator cost
or predict production latency.

| 128 MiB materialized payload | Result | SQLite heap peak | Mean latency |
|---|---|---:|---:|
| Plain SQLite, temp MEMORY | All six complete | 184.46 MiB | 1,011.69 ms |
| Plain SQLite, temp FILE | All six complete | 3.54 MiB | 1,934.94 ms |
| SQLhevi, 64 MiB pool | All six return `ERR SQLiteMemory` | Not exported by cluster client | 184.71 ms to rejection |

The FILE baseline wrote **177,635,328 bytes (169.41 MiB) of temporary data per 128 MiB
join** through the ordinary SQLite VFS. This is successful VFS write traffic, not physical
device bytes. OS page cache is outside the SQLite allocation metric. The lower heap usage
comes with additional I/O and higher latency; it is not free memory. See
[SQLite's temporary-file documentation](https://sqlite.org/tempfiles.html).

The native cluster reproduced the same 20 MiB success / 24 MiB OOM boundary. Across the host
engine and native cluster there were **162 materialized-join requests: 72 successes and
90 expected OOM rejections**. Every failed request preserved the guard value, and every
following validation read succeeded. The 256 MiB control also exhausted its pool on the
96 and 128 MiB workloads; that control is plain SQLite, not a modified SQLhevi server.

Post-pressure SQLhevi cluster p50 remained about 31 ms for point reads and writes, but mean
latencies increased from 30.30/29.99 ms to 42.31/49.45 ms, with median per-run p95 values
of 159.82/102.69 ms. There are real tail spikes in this workload. Replication/storage work
and the request position in the checkpoint cycle were not separately instrumented, so this
test cannot assign those spikes to the heap pool. Host engine p50 changed from approximately
273/294 µs to 286/299 µs, and its audited live SQLite allocations returned to zero.

**The 64 MiB pool is not the process memory limit.** All nine measured replica processes
ended at 969,512–969,520 KiB resident memory, approximately **947 MiB per replica** even
with the 1 GiB storage budget and this small dataset. That includes SQLite, LSM, replication
and other buffers. The FILE baseline peaked at approximately 7.4 MiB process RSS; the
MEMORY baseline peaked at approximately 347 MiB. The host SQL/Pager fixture peaked around
112 MiB RSS. Process RSS and allocator high-water marks should not be interchanged.

The final logs contain three `CLUSTER BENCH PASS` markers and no panic or failure.

## Method and limitations

- Host: Intel Core Ultra 7 255H, Linux x86-64, Zig 0.16.0 ReleaseSafe, statically linked musl.
  Four serial runs per host backend, pinned to CPU 0, rotating backend order.
  Build activity and QEMU tests were outside these timed host campaigns.
- Same pinned SQLite amalgamation everywhere; 64 KiB main-database pages, approximately 2 MiB
  page-cache target, single-threaded SQLite, no mmap or extension loading. Baselines retain the
  POSIX VFS and system allocator option. Production retains its existing VFS, memory audit,
  authorizer, instruction limits and compile flags. SQLite source was not edited.
- Each full host run measures 128 point reads, 64 point updates, 16 batch updates, 16 scans,
  16 eight-way joins, three repetitions of each of nine materialized joins, and another
  128/64 reads/writes after pressure. Setup and validation queries are not timed.
- Native runs use 16 reads, eight point writes, two batches/scans/eight-way joins, two repetitions
  of each materialized join, and 16/eight post-pressure reads/writes. The client keeps one VSR
  session; process creation and registration are excluded from request timings.
- Baseline memory is measured with `SQLITE_STATUS_MEMORY_USED`; production-engine memory uses
  the existing allocator audit. Both sum allocation sizes, including allocator rounding.
  Whole-process RSS is a different measure. Cluster heap metrics are unavailable remotely:
  zeros in those CSV fields mean **unavailable**, not zero allocation.
- Temporary-file traffic is counted with a bounded Zig VFS wrapper around successful writes
  to delete-on-close temporary files. Main DB/WAL writes are excluded. It forwards to SQLite's
  unchanged POSIX implementation. The built-in `TEMPBUF_SPILL` counter in this revision does
  not include the ephemeral btree used by this materialized CTE, so it is not used.
- Pressure-case allocation/fetch counters include their subsequent validation reads;
  latency samples exclude those reads. Point/scan/join attempt counts above cover only their
  timed requests. Peaks include all live SQLite allocations, not just incremental query memory.
- p50 selects the lower middle sample; p95 uses nearest rank. The host latency table takes the
  median of per-run p50 values; the native latency table uses the mean of all timed requests.
  CSV percentile summaries are medians of per-run statistics. Tiny native sample
  sets and shared hardware make the native results diagnostic rather than a performance claim.
- This is a small, serial workload, not a concurrency, sustained-throughput, maximum-database-size,
  crash-durability or network-fault benchmark. The existing deterministic simulation tests cover
  faults separately. Increasing the pool would not address private connection/replay overhead,
  replication latency, read-set limits or dirty-set limits.

## Reproduce

The commands below run the same workloads against the current implementation. They do not
recreate the historical memory-only production configuration. Current labels include the compiled
pool size and spill mode. Add `-Dsqlite-memory-limit=67108864` to build the 64 MiB variant; the
in-memory adapter explicitly omits scratch, while the native server uses the new local file VFS.
Build the optional Zig benchmark drivers:

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.tooling/global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/.tooling/cache"
.tooling/zig-x86_64-linux-0.16.0/zig build benchmarks check -Doptimize=ReleaseSafe -j4

taskset -c 0 ./zig-out/bin/SQLhevi-bench-sqlite system :memory: memory ram
taskset -c 0 ./zig-out/bin/SQLhevi-bench-sqlite 64 :memory: memory ram
taskset -c 0 ./zig-out/bin/SQLhevi-bench-sqlite 256 :memory: memory ram
taskset -c 0 ./zig-out/bin/SQLhevi-bench-engine
```

Repeat four times, rotating the order `system,64,256,engine` by one position each time.
The baseline arguments are allocator (`system`, `64`, `256`), database path, temporary
storage mode (`memory` or `file`), result label, and an optional fifth `quick` argument.
Use a fresh database path on every run. File-backed main databases use WAL with
`synchronous=FULL`; their temporary files are placed in the database's directory.

On a host supporting io_uring, the integrated driver creates the two plain-SQLite databases
and a three-process SQLhevi cluster, using the same workload and filesystem:

```sh
mkdir -p .tooling/performance-new
./zig-out/bin/SQLhevi-bench-cluster "$PWD/zig-out/bin/SQLhevi" \
  "$PWD/zig-out/bin/SQLhevi-bench-sqlite" "$PWD/.tooling/performance-new"
```

This environment restricts io_uring and has no /dev/kvm. Using the kernel/modules prepared
as described in [testing.md](testing.md#reproduce-the-native-vm):

```sh
mkdir -p .tooling/bench-guest/lib
cp .tooling/guest/lib/*.ko .tooling/bench-guest/lib/
cp zig-out/bin/SQLhevi .tooling/bench-guest/SQLhevi
cp zig-out/bin/SQLhevi-bench-sqlite .tooling/bench-guest/SQLhevi-bench-sqlite
cp zig-out/bin/SQLhevi-bench-cluster .tooling/bench-guest/init
(cd .tooling/bench-guest && find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > ../bench-guest.cpio.gz)
test ! -e .tooling/performance-new.ext4
truncate -s 2G .tooling/performance-new.ext4
mkfs.ext4 -q -F .tooling/performance-new.ext4
timeout 180 qemu-system-x86_64 -accel tcg -machine q35 -cpu max -m 6144 -smp 2 \
  -display none -serial file:.tooling/performance-new.log -monitor none -no-reboot \
  -kernel .tooling/alpine/boot/vmlinuz-virt -initrd .tooling/bench-guest.cpio.gz \
  -append 'console=ttyS0 rdinit=/init panic=1 quiet' \
  -drive file=.tooling/performance-new.ext4,format=raw,if=virtio -nic none
rg 'CLUSTER BENCH PASS|BENCH FAIL|panic' .tooling/performance-new.log
```

Require `CLUSTER BENCH PASS` and no failure/panic. QEMU exit status alone is insufficient.
Run three times with fresh images to reproduce the native campaign.

The [raw results](test-results/performance/) contain all final host/native runs, CSV summaries,
source/executable hashes, environment details, static-linking checks and the build/check log.
All 12 unit tests and Cobra/TigerStyle checks passed: 405 assertions across 181 functions in
25 Zig files. No shared runtime dependency was added.
