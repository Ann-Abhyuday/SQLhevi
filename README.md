# SQLhevi

SQLite with TigerBeetle's Viewstamped Replication, written in Zig.

SQLhevi is a working **experimental, bounded database**, not a production-qualified database.
SQLite is its SQL and B-tree engine. The original TigerBeetle VSR replica, journal, checksummed
block storage, checkpointing, repair, and state-transfer code provides replicated durability.
Run ordinary processes on separate Linux machines; containers and orchestration are unnecessary.
Three replicas tolerate one unavailable replica; five or six tolerate two, subject to quorum
connectivity and TigerBeetle's fault model. The CLI accepts one through six replicas. With six,
the upstream replication quorum is three and the view-change quorum is four; six replicas do not
guarantee availability after three failures. A single replica provides no machine-failure tolerance.

All SQLhevi implementation, build, and test code is Zig. SQLite's C source is **unmodified**.
The runtime executables statically link SQLite and musl; TigerBeetle's Zig code is compiled directly
into them. No libsqlite3, liburing, or other shared library is needed. Cobra is a separately built,
statically linked development tool; it is not a runtime dependency. Upstream repositories retain
their original languages and licenses. Exact revisions are in [dependencies.lock.json](dependencies.lock.json).

## Database size and capacity

SQLite's theoretical file-size limit is **281,474,976,579,584 bytes: about 281 TB, or 256 TiB**,
using 4,294,967,294 pages of 65,536 bytes. **232 TB is not SQLite's documented limit.** With the
default 4,096-byte pages the theoretical limit is about 17.6 TB (16 TiB). SQLite documents that
the maximum-size configuration has not been tested at that scale. See the
[official limits, items 12 and 14](https://sqlite.org/limits.html).

SQLhevi uses **64 KiB SQLite pages** and supports that logical address range through its paged
Zig VFS. Its LSM has nine levels, 64-bit chunk keys, and capacity checks covering the maximum
address. Sparse tests create, read, update, replicate, and recover a table rooted at SQLite page
**4,294,967,294**. These tests exercise real SQLite and VSR without allocating a maximum-size file.
They do **not** establish throughput, recovery time, or correctness with 281 TB of populated data.

The native replica's backing-storage budget defaults to **16 GiB** and is configurable from
1 GiB through **1 PiB**. The larger budget provides room for chunks, LSM versions, compaction,
and replication metadata. The underlying filesystem must support the resulting container size.
Memory is reserved at startup and scales with the storage budget: the maximum configuration needs
about 21 GiB for manifest nodes alone, plus substantial hash-map, free-set, and other allocations.
It requires a suitably provisioned machine; the small sparse tests do not allocate that budget.

```sh
# Inspect capacity without opening storage or allocating the configured database memory.
./zig-out/bin/SQLhevi capacity 1125899906842624
# Optional final argument is the per-replica storage budget in bytes.
./zig-out/bin/SQLhevi start 127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003 data/0.SQLhevi 1125899906842624
```

Transactions remain bounded, independently of file capacity: 64 KiB of SQL, 65,536 cached
496-byte chunks (31 MiB including read-ahead), and 8,192 staged chunks (3.875 MiB including
size metadata). There are limits of 1,024 statements, 2,000 columns, 65,536 returned rows,
approximately 100 million SQLite VM instructions per attempt, a 512 MiB SQLite memory pool,
and a reply smaller than 128 KiB. Individual SQL values are limited to 1,015,808 bytes.
Large scans and updates must be divided into requests; indexed access can reach any database page.
All limits are in [src/limits.zig](src/limits.zig). The small whole-image reference engine is
used by tests, separately from the production paged storage path.

SQLite's pool size and hard heap limit share one Zig compile-time constant,
`limits.sqlite_heap_limit`, defaulting to **512 MiB (536,870,912 bytes)**. Memory accounting is
enabled and `sqlite3_hard_heap_limit64()` enforces the same bound. This is SQLite's heap budget,
not total process RAM: VSR, page overlays, stacks, and scratch metadata need additional memory.
Allocator bookkeeping and fragmentation reduce the pool's usable payload capacity.

**For heavier queries, increase the limit to 1–2 GB when each replica has enough RAM.** Build with
`-Dsqlite-memory-limit=1073741824` for 1 GiB or `-Dsqlite-memory-limit=2000000000` for 2 GB.
The option takes bytes; SQLite's `SQLITE_CONFIG_HEAP` API uses a signed `int`, so the maximum is
2,147,483,647 bytes (one byte below 2 GiB). SQLhevi accepts limits from 4 MiB through that maximum.
Use the same binary and limit on every replica. Changing the limit can change SQL/OOM results and
therefore replay semantics: configure it before formatting a new cluster. This experimental version
does not support changing it through a rolling upgrade or replaying old data under new settings.
`SQLhevi version` reports the compiled limit.

Spill-eligible joins, materializations, sorts, and transient indexes use local anonymous temporary
files through the Zig io_uring VFS. They can exceed the SQLite heap budget, but spilling does not
make every query fit: some allocations, rollback journals, results, and transaction bounds still
consume memory. Scratch has its own fixed limits: 16 simultaneously open files and 65,536 tracked
64 KiB block identities per execution attempt (4 GiB), with about 3.625 MiB of startup buffers and
checksum metadata outside SQLite's pool. Scratch files share the data directory's filesystem and
need free space in addition to the VSR storage budget.

The [earlier performance tests](docs/performance.md) measured the previous 64 MiB, memory-only
configuration. Their OOM counts and timings are historical, not measurements of the new default.
See [spill and memory-limit validation](docs/spill.md) for the current implementation and tests.

## Build

Use **Zig 0.16.0**, matching the pinned TigerBeetle revision. The provided build targets Linux
x86-64-v3 with AES and PCLMUL CPU support. SQLite is generated out of tree from its pinned sources.
Development prerequisites are Git, curl, tar/xz, a C compiler, make, Tcl, and yacc/bison for Cobra.

With the dependencies and generated amalgamation already present in this workspace:

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.tooling/global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/.tooling/cache"
.tooling/zig-x86_64-linux-0.16.0/zig build check install
.tooling/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseSafe install
# Optional: 1 GiB SQLite pool and hard limit, applied to all newly formatted replicas.
.tooling/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseSafe -Dsqlite-memory-limit=1073741824
```

`check` runs the SQLite contract tests, Zig formatting, and Cobra-backed TigerStyle checks.
The pinned Zig download's SHA-256 is recorded in the lock file. See
[docs/development.md](docs/development.md) for source acquisition and regeneration instructions.

## Run a three-replica cluster

Linux must allow `io_uring_setup`. The data filesystem must support direct I/O, preallocation,
and anonymous `O_TMPFILE` files. Startup probes scratch-file support.
SQLhevi fails at startup if these requirements are unavailable; it has no synchronous-I/O fallback.
Keep replica data on independent disks/machines for actual fault tolerance. These localhost examples
are for development:

```sh
mkdir -p data
./zig-out/bin/SQLhevi format 0 0 3 data/0.SQLhevi
./zig-out/bin/SQLhevi format 0 1 3 data/1.SQLhevi
./zig-out/bin/SQLhevi format 0 2 3 data/2.SQLhevi

# Run each command in a separate terminal. Address order must match replica numbering.
./zig-out/bin/SQLhevi start 127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003 data/0.SQLhevi
./zig-out/bin/SQLhevi start 127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003 data/1.SQLhevi
./zig-out/bin/SQLhevi start 127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003 data/2.SQLhevi

./zig-out/bin/SQLhevi sql 0 127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003 \
  "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO items VALUES(1,'hello'); SELECT * FROM items;"
```

Each request is one atomic transaction. Submit multiple statements in one request for atomic
batches. Both reads and writes pass through VSR, so a partitioned minority cannot serve successful
stale reads. Errors discard the private write overlay and leave replicated database pages unchanged.
Schema changes, joins, indexes, foreign keys, ordinary triggers, views, and SQLite's built-in SQL
functions use the real SQLite engine.

Responses start with `OK` and a blank line, followed by tab-separated rows; integers and floats are
printed directly, NULL is `null`, text is `t:` plus UTF-8 bytes in hex, and blobs are `b:` plus hex.
Failures return `ERR <error-name>` and a nonzero CLI exit code. Results are bounded by the VSR message
size; overflow rejects the entire request.

VSR retries preserve the session/request identity and suppress duplicates. Each CLI invocation opens
a fresh session. **A timeout is indeterminate: do not blindly rerun a timed-out write as a new CLI
invocation.** Reconcile with an application key first. This version has no persistent application
idempotency-key API.

## Storage and deterministic execution

SQLite uses `SQLITE_OS_OTHER`, a Zig VFS, and a fixed heap with a matching hard limit (512 MiB by
default). It can open only the VSR-backed main database and anonymous local scratch files, and
cannot load extensions. During VSR's commit-prefetch stage, SQLite
evaluates against an immutable snapshot and a private write overlay. On a cache miss, the adapter
closes the private connection, asynchronously fetches the missing range from TigerBeetle, and
replays using the same operation number, timestamp and PRNG seed. Successful staged writes enter
the LSM forest only in the commit callback; responses are released through VSR's normal protocol.
The forest is a durable page container; SQLite owns SQL semantics and the database's B-tree
representation. Recovery loads pages on demand and replays committed journal entries. See
[docs/architecture.md](docs/architecture.md) for the interface and failure boundaries.

Temporary files for **both reads and writes stay outside VSR**. Scratch bytes are verified against
checksums held in RAM before SQLite can consume them. A failed query discards its entire private
write overlay; a crashed process loses its anonymous files automatically. A local scratch I/O or
checksum failure stops the affected replica before applying the overlay, even if SQLite ignored a
close error. It must not become a replicated SQL rejection, since healthy peers may succeed.
VSR recovery re-executes the ordered request using fresh scratch. A quorum-committed transaction
is never reversed because one replica failed; it completes atomically through surviving/recovered
replicas. Client timeouts retain their indeterminate-outcome semantics.

All replica file reads, writes, open, allocation, metadata reads, fsync, and close use io_uring.
Durable VSR storage requires O_DIRECT and O_DSYNC. Scratch uses O_DIRECT with write read-back and
checksummed reads; disposable files require no durability fsync. A Linux advisory `flock` syscall prevents two processes owning the
same data file; Linux does not expose that lock operation through io_uring. Console output and
development tooling are outside the database storage path.

Time comes from the replicated VSR timestamp. SQLite's PRNG is reset from the replicated operation
number, including random rowid allocation. `localtime` conversion is compiled out. SQL cannot change
transaction boundaries, PRAGMAs, attach databases, create temporary objects/virtual tables, load
extensions, or inspect connection-history/build-dependent functions. This keeps replay independent
of process history and host settings. Random SQL functions are deterministic, **not cryptographic**.

## Fault testing

```sh
./zig-out/bin/SQLhevi-sim 1 300
./zig-out/bin/SQLhevi-sim 42 1000
./zig-out/bin/SQLhevi-sim 1 300 sparse
./zig-out/bin/SQLhevi-sim 1 120 spill

# On a Linux host permitting io_uring, using a new empty directory:
mkdir -p .tooling/native-test
./zig-out/bin/SQLhevi-test-cluster "$PWD/zig-out/bin/SQLhevi" "$PWD/.tooling/native-test"
```

The simulator imports TigerBeetle's real `testing/cluster.zig`, `testing/storage.zig`,
`testing/packet_simulator.zig`, simulated time, fault atlas, and journal/grid/manifest/state checkers.
It runs SQLhevi's real SQLite state machine with packet loss, replay, delay, asymmetric partitions,
read/write corruption, misdirected writes, and crash faults. It checks SQL against a reference model,
primary failure, checkpoints, complete restart, replica read-set agreement, minority rejection, and
exactly-once retry within a live client session. A seed reproduces the execution schedule.

The native test launches three actual processes over TCP, kills the primary, checks continued SQL
progress, kills all replicas, then verifies durable recovery. Deterministic simulation does not
replace native I/O testing, and passing finite campaigns is not proof of correctness. See
[docs/testing.md](docs/testing.md) for measured results and VM instructions.

The optional `container-tests` build target adds a Zig driver for **six actual OCI containers**,
random SIGKILL/restart schedules, writes during outages, quorum loss, and full-cluster recovery.
It uses the production static binary, native io_uring, persistent per-container data directories,
and one persistent VSR client session. See [the container test](docs/container-testing.md).

## Current scope

This is a research implementation with bounded transactions, a single database per
cluster, fixed membership, a CLI client, and no public authentication/TLS or rolling-upgrade API.
Use an isolated trusted network. Wire/data files are SQLhevi-specific and incompatible with
TigerBeetle account/transfer clusters. The `.SQLhevi` data file is a replicated storage container,
not a standalone file that the stock SQLite CLI can open. No sharding or distributed SQL planner is
implemented. Production use requires broader workloads, sustained simulation campaigns, independent
review, operational tooling, and qualification with much larger populated databases.
VACUUM and file truncation are not implemented; DROP/DELETE reclaim pages for reuse within SQLite.
The experimental file format has no migration guarantee across SQLhevi source revisions; use fresh
data files when changing revisions until an explicit migration path exists.

## Style and provenance

SQLhevi Zig code applies [TigerStyle](dependencies/tigerbeetle/docs/TIGER_STYLE.md), with Cobra
structural queries, Zig AST checks, meaningful assertions, bounded work, and startup allocation
in the replica adapter. Density is measured inside named function bodies; test-block and top-level
compile-time assertions cannot inflate it. Negative fixtures verify that the checkers reject
violations. See [the style and memory audit](docs/tigerstyle.md) for coverage and boundaries.

**SQLite is not stack-only and does not obey TigerStyle's startup-only allocation rule.**
TigerStyle permits startup heap allocation; it prohibits later allocation and reallocation.
SQLite allocates dynamically during queries. Its unmodified source uses `memsys5` inside a fixed
startup pool here, with `SQLITE_ZERO_MALLOC` disabling the default system allocator and
`SQLITE_OMIT_AUTOINIT` requiring explicit initialization. Zig callbacks verify allocation bounds,
and tests check exhaustion and recovery. This is a documented dependency exception, not a claim
that dynamic pool allocation satisfies the literal rule. Build tools and test harnesses also
perform bounded setup allocations outside the production request path.

SQLite is public domain; TigerBeetle is Apache-2.0; Cobra retains its Caltech/Nimble license.
See [THIRD_PARTY.md](THIRD_PARTY.md). The small [TigerBeetle patch](docs/tigerbeetle.patch) exports
configuration, initializes complete journal slots during format, sizes manifest maps against
the physical storage budget, and widens node-pool byte arithmetic past 4 GiB. The VSR consensus
and fault-injection implementations are unmodified.
