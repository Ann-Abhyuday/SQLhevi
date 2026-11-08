# SQLite heap limits and local temporary spill

The default SQLite pool and hard heap limit are both 536,870,912 bytes (512 MiB).
`build.zig` generates one compile-time setting, exposed as `limits.sqlite_heap_limit`;
`sqlite_heap_size` is an alias. The fixed array, `SQLITE_CONFIG_HEAP`, and
`sqlite3_hard_heap_limit64()` all use that value. `MEMSTATUS` is enabled explicitly.
SQLite's source and generated amalgamation remain unchanged.

Configure a new cluster with `-Dsqlite-memory-limit=1073741824` for 1 GiB or
`-Dsqlite-memory-limit=2000000000` for 2 GB. The latter is decimal: the signed `int` size in
`SQLITE_CONFIG_HEAP` cannot represent exactly 2 GiB. The accepted range is 4,194,304 through
2,147,483,647 bytes. Pool bookkeeping and buddy-allocation rounding reduce usable capacity;
individual memsys5 allocations cannot exceed 1 GiB even with a larger pool. The Zig allocator
wrapper accepts memsys5's documented zero-size rejection sentinel and preserves the original
allocation on a failed resize. Tests cover that boundary without allocating a gigabyte object.

Use identical builds and limits on all replicas. Changing the memory limit can change OOM results,
so a running cluster or an old journal must not be replayed under a new limit. There is no
supported rolling configuration migration in this experimental implementation. The setting is
not a whole-process RSS limit. VSR memory, page overlays, scratch bookkeeping, and stacks are
separate. A larger heap also does not disable file spill: SQLite's operator/cache thresholds
still govern it.

## Scratch storage and failure behavior

Native replicas always attach the Zig scratch VFS and use `temp_store=FILE`. The file backend
opens `O_TMPFILE` inodes in the replica data directory through io_uring, probes filesystem support
at startup, and uses aligned `O_DIRECT` reads and writes. There is no POSIX VFS fallback, named
scratch file, scratch recovery directory, or scratch operation in the VSR log. Reference tests
can explicitly omit the device to retain their memory-only comparison path.

All scratch memory is allocated at startup. The store supports 16 simultaneously open files,
65,536 block identities per execution attempt, and a 4 GiB logical file bound. A block is 64 KiB;
closed files' identities remain counted until the attempt ends. Expected SHA-256 hashes stay in
RAM, independent of disk contents. The fixed hash table, entries, write cache, and verification
buffer occupy 3.625 MiB plus small control structures outside the SQLite heap. A write is read
back before its checksum becomes trusted; later reads compare against that checksum. These checks
detect changed, stale, misdirected, short, and failed I/O before affected bytes can become SQL
results. Identical contents are harmless. Memory corruption and adversarial modification of
trusted process memory are outside this storage-fault model.

The main database and its temporary workspace have different lifetimes:

| Event | Database and VSR behavior |
|---|---|
| Read-only spill | Anonymous local workspace; the read request still uses VSR ordering for consistency |
| Successful write batch | Only its final private database-page overlay enters the normal VSR commit path |
| Deterministic SQL/heap/work/size rejection | Discard all staged writes; return the normal replicated error |
| Scratch I/O error, disk-full error, or corrupt read | Discard the overlay and exit the affected replica with status 74; never replicate a locally determined SQL error |
| Process killed during scratch I/O | Kernel closes anonymous files; VSR recovery replays ordered SQL using fresh scratch |
| Quorum already committed the request | Surviving/recovered replicas finish the complete transaction; one node's failure does not reverse it |

Scratch failures are sticky and checked after the SQLite connection closes, including errors
SQLite ignores from `xClose`. They take priority over page-cache-miss retries. A read-only query
with corrupt scratch cannot return a successful corrupted result. A write batch with an earlier
UPDATE and a later spilling join cannot expose a partial UPDATE. No scratch file is copied to
another replica or restored after restart.

The synchronous SQLite VFS waits for scratch completions without reentering VSR. This can delay
heartbeats and cause view changes or indeterminate client timeouts under heavy queries. Those
delays occurred in the emulated native tests; correctness passed, but this is not a claim of
production throughput or uninterrupted availability. All nodes running out of scratch space can
halt progress. Spill does not remove result, instruction, transaction, allocator, or read-set limits.

## Validation

Logs and executable/source hashes are in [test-results/spill](test-results/spill/).
Historical names were normalized during the project rename; see the
[evidence provenance note](test-results/README.md).
The tests use the pinned Zig 0.16.0 and unchanged SQLite 3.55.0 development amalgamation.

Recorded on 2026-11-08: **19/19 tests passed** in default Debug and ReleaseSafe, and in
ReleaseSafe builds with 64 MiB, 1 GiB, 2 GB, and 2,147,483,647-byte limits. The maximum-size
build also links all runtime executables successfully; it uses the x86-64 medium code model
above 2 GB to avoid relocation overflow. Ordinary-size builds retain their default code model.
Cobra reports **544 assertions in 247 named functions across 33 files** (2.20 per function).
Spill seeds 1, 42, and 777 each pass seven local fault cases alongside the upstream fault harness;
seed 1's repeated log is byte-identical. The sparse maximum-page campaign also passes.

- Unit tests exercise the hard limit independently of the pool; allocation rejection/recovery;
  the >1 GiB memsys5 sentinel; SQLite materialized joins and external sorting; scratch file limits,
  partial blocks, holes, truncation/regrowth, file reuse, and corrupted reads. Seven injected
  local fault classes cover open/read/write/close failures, corrupt reads/writes, and lost writes.
  Failed write batches preserve the original database; a subsequent successful batch commits fully.
- The VSR spill campaign uses TigerBeetle's real network and durable-storage fault simulators,
  with local scratch failures during packet loss, partitions, replay, and storage corruption.
  It crashes the affected replica outside the callback stack, restarts it, and checks replay,
  exactly-once application, agreement, and full-cluster recovery. Four successful write requests
  each add 11 to a guard row; the final value is 44.
- Native tests run three static processes over TCP on ext4 in a QEMU TCG Linux guest with 6 GiB
  RAM and two virtual CPUs. The separate test server kills itself after 48 real scratch writes
  in a read and in a write, and corrupts a real block during a write via io_uring. The corruption
  produces status 74. Surviving peers return complete results; restarting all replicas preserves
  the expected guard value 22. Both the default 512 MiB and a 64 MiB build complete a materialized
  128 MiB join, demonstrating workspace larger than the smaller build's hard heap limit.
- Cobra and Zig AST checks cover all project Zig files, function length, assertion density,
  bounded loops, initialization-only allocation, and the existing negative fixtures. Static-link
  inspection finds no dynamic ELF section. SQLite's repository is clean and amalgamation hashes
  match the original files.

Reproduce the host checks and deterministic campaign:

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.tooling/global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/.tooling/cache"
.tooling/zig-x86_64-linux-0.16.0/zig build check install spill-tests -Doptimize=ReleaseSafe
./zig-out/bin/SQLhevi-sim 1 120 spill
./zig-out/bin/SQLhevi-sim 42 120 spill
./zig-out/bin/SQLhevi-sim 777 120 spill
./zig-out/bin/SQLhevi-sim 1 120 sparse
```

On a Linux host permitting io_uring, with a fresh directory on a filesystem supporting direct I/O
and `O_TMPFILE`:

```sh
mkdir -p .tooling/native-spill-test
./zig-out/bin/SQLhevi-test-spill "$PWD/zig-out/bin/SQLhevi-fault-test" \
  "$PWD/.tooling/native-spill-test"
```

For the 64 MiB variant, build `test spill-tests -Doptimize=ReleaseSafe
-Dsqlite-memory-limit=67108864 --prefix .tooling/spill64` and use those two test executables with
another empty directory. The production `SQLhevi` binary contains neither fault hook nor the
`SQLHEVI_TEST_SCRATCH_FAULT` setting. The special server is installed only by the `spill-tests`
build step. Existing guest setup in `tests/guest.zig` lets `SQLhevi-test-spill` run as `/init`, with
`SQLhevi-fault-test` at `/SQLhevi-fault-test`, using the VM procedure in [testing.md](testing.md).
