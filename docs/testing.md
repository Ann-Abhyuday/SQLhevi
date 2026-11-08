# Testing

All project test drivers are Zig. `SQLhevi-sim` links the real SQLite state machine to
TigerBeetle's original deterministic cluster, packet simulator, storage simulator, fault atlas,
simulated clock, and journal/grid/manifest/state checkers. It does not use a toy VSR model.

## Repeatable commands

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.tooling/global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/.tooling/cache"
.tooling/zig-x86_64-linux-0.16.0/zig build install check -Doptimize=ReleaseSafe -j4
./zig-out/bin/SQLhevi-sim 1 300 > .tooling/seed-1-a.log 2>&1
./zig-out/bin/SQLhevi-sim 1 300 > .tooling/seed-1-b.log 2>&1
cmp .tooling/seed-1-a.log .tooling/seed-1-b.log
./zig-out/bin/SQLhevi-sim 42 1000
./zig-out/bin/SQLhevi-sim 1 300 sparse
./zig-out/bin/SQLhevi-sim 42 1000 sparse
```

The complete output, including progress and final simulated ticks, is reproducible for the same
binary and seed. The final digest chains every SQL request and reply; different seeds should
produce the same digest for the same logical workload while changing the schedule and faults.
The reported `faulty_sectors_max` is the maximum simultaneous stored-fault count, not the total
number of injected events. Some seeds log upstream's rejection of a newer request during
retry/view-change traffic; the checks still require eventual model-correct replies.

## Coverage

The SQLite tests exercise real SQL, schemas, triggers, views, foreign keys, empty values, NUL input,
statement/row/work bounds, output overflow, atomic rejection, deterministic time, PRNG and random
rowids. The paged fixture grows past its read cache through repeated cache-miss replay, compares
independent database byte images, rejects partially executed transactions and oversized read sets,
and verifies indexed access needs
only a small read set. A separate SQLite deserialize path tests the common SQL execution contract.

Simulation inserts 4,000-byte payloads and checks count/sum after every transaction against an
independent arithmetic model. A covering index permits bounded reads as the database grows.
The unit fixture uses deliberately smaller read/write limits to exercise exhaustion cheaply;
the production request cache is 31 MiB. Configured faults include:

- Packet loss and replay (2% each), latency, clogged paths, and asymmetric partitions.
- Read/write corruption (1% each), misdirected writes (0.1%), and crashes during pending writes.
- Faults in superblocks, WAL headers/prepares, client replies, and grid storage, constrained by
  TigerBeetle's fault atlas so recovery remains possible under the intended fault model.

The driver kills the initial primary, restores it, requires checkpoint progress and a view change,
restarts every replica from durable simulated bytes, compares the recovered SQL model and replica
read sets, then leaves one replica alone and asserts it cannot acknowledge a write. Restoring a
majority must complete the retried request once. The original upstream safety checkers run throughout.

The optional `sparse` argument supplies an arithmetic immutable base image covering SQLite's
maximum file size. Its freelist skips the pending-byte page and initially allocates the last page
as the ledger's root. Actual changed chunks are persisted through the same LSM and VSR paths,
faulted, checkpointed, and recovered. The native executable excludes this fixture entirely.
This tests high logical addresses using a small physical store; it does not simulate all the
data or physical I/O of a populated 281 TB database.

Additional unit tests cover maximum-page CREATE/INSERT/SELECT/UPDATE, the SQLite FULL allocator
guard, offsets past the maximum, fixed-pool allocation exhaustion/recovery, and the storage
budget/manifest arithmetic through 1 PiB without allocating that capacity.

This is a targeted SQL workload using comprehensive upstream fault infrastructure. It does not
exercise every TigerBeetle VOPR scheduling option, every SQL statement, all membership sizes, or
production-scale capacity. Fault rates are probabilities; a particular seed need not hit every
possible fault category. Finite campaigns are evidence, not proof of distributed-system correctness.

## Native cluster

On a Linux host permitting io_uring and direct I/O:

```sh
mkdir -p .tooling/native-test
./zig-out/bin/SQLhevi-test-cluster "$PWD/zig-out/bin/SQLhevi" "$PWD/.tooling/native-test"
```

Use a new empty directory for every run. The test creates three files, launches three actual
processes over TCP, writes 1,216,000 SQL payload bytes in bounded transactions, kills the primary,
checks a subsequent mutation, kills/restarts every replica, and checks both recovered values and
payload totals. The workload advances through checkpoints as well as journal replay.

The development sandbox rejected `io_uring_setup`, so native tests here used a Linux VM under QEMU
TCG. This executes real io_uring on ext4 in the guest; there is no synchronous-storage fallback in
SQLhevi. The VM uses an ordinary local disk image and does not need privileged host networking.

## Reproduce the native VM

Additional test tools: QEMU x86-64, gzip, cpio, and e2fsprogs. The optional Linux kernel is pinned
in `dependencies.lock.json`; it is test infrastructure, not a SQLhevi dependency. These commands
create a new test disk and unpack only within `.tooling`:

```sh
mkdir -p .tooling/alpine .tooling/guest/lib
curl --fail --location \
  https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/linux-virt-6.18.62-r0.apk \
  --output .tooling/linux-virt.apk
echo 'e121b547d9b86194a641718b52ae1c3e605085c59f31525b1649a59b3d4db0c7  .tooling/linux-virt.apk' \
  | sha256sum --check
tar -xzf .tooling/linux-virt.apk -C .tooling/alpine
gzip -dc .tooling/alpine/lib/modules/6.18.62-0-virt/kernel/drivers/block/virtio_blk.ko.gz \
  > .tooling/guest/lib/virtio_blk.ko
gzip -dc .tooling/alpine/lib/modules/6.18.62-0-virt/kernel/lib/crc/crc16.ko.gz \
  > .tooling/guest/lib/crc16.ko
gzip -dc .tooling/alpine/lib/modules/6.18.62-0-virt/kernel/fs/mbcache.ko.gz \
  > .tooling/guest/lib/mbcache.ko
gzip -dc .tooling/alpine/lib/modules/6.18.62-0-virt/kernel/fs/jbd2/jbd2.ko.gz \
  > .tooling/guest/lib/jbd2.ko
gzip -dc .tooling/alpine/lib/modules/6.18.62-0-virt/kernel/fs/ext4/ext4.ko.gz \
  > .tooling/guest/lib/ext4.ko
cp zig-out/bin/SQLhevi .tooling/guest/SQLhevi
cp zig-out/bin/SQLhevi-test-cluster .tooling/guest/init
(cd .tooling/guest && find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > ../guest.cpio.gz)
test ! -e .tooling/native-run.ext4
truncate -s 1G .tooling/native-run.ext4
mkfs.ext4 -q -F .tooling/native-run.ext4
timeout 360 qemu-system-x86_64 -accel tcg -machine q35 -cpu max -m 6144 -smp 2 \
  -display none -serial file:.tooling/native-vm.log -monitor none -no-reboot \
  -kernel .tooling/alpine/boot/vmlinuz-virt -initrd .tooling/guest.cpio.gz \
  -append 'console=ttyS0 rdinit=/init panic=1 quiet' \
  -drive file=.tooling/native-run.ext4,format=raw,if=virtio -nic none
rg 'NATIVE PASS|NATIVE FAIL|panic' .tooling/native-vm.log
```

The Zig test driver is PID 1 in this initramfs. It loads the five kernel modules, mounts ext4,
enables loopback, runs the same process test, and powers off. Require an explicit `NATIVE PASS`
marker; QEMU's exit status alone does not distinguish a test failure from clean poweroff.

## Recorded evidence

Historical names were normalized during the project rename. See the
[evidence provenance note](test-results/README.md) for the scope of retained hashes and logs.

Read/write performance and join-memory-pressure measurements are documented in
[performance.md](performance.md), with reproducible Zig drivers and
[raw results](test-results/performance/). They include allocator controls, the real SQL/Pager,
and the native three-replica io_uring cluster compared with durable plain SQLite.

Current results are in [test-results/capacity](test-results/capacity/), with build mode, command output,
simulator seeds and executable hashes. Binary hashes identify local artifacts, not a signed release
or a claim of byte-for-byte reproducibility across different build directories.

The final runtime binaries passed these checks:

| Check | Result |
|---|---|
| SQLite, sparse-boundary, allocator, and capacity tests | 12/12 in Debug and ReleaseSafe |
| Maximum manifest reservation | Actual upstream allocator requested 22,089,007,104 bytes; recording allocator rejected it without allocating that memory |
| Formatting, Cobra, and Zig AST | 17 Zig files; 304 function-body assertions across 137 functions; positive and negative checks passed |
| Seed 1, 300 inserts | 7,414 ticks; view 3; checkpoint 231; 10 simultaneous faulty sectors |
| Seed 1 replay | Byte-identical output, SHA-256 `b4d4b0357c4a2bee8a334460482c525161d34ed7e78fc87c66296fa269c1f289` |
| Seed 42, 1,000 inserts | 19,421 ticks; view 7; checkpoint 927; 9 simultaneous faulty sectors |
| Sparse seed 1, 300 inserts | 6,930 ticks; view 3; checkpoint 231; 9 simultaneous faulty sectors |
| Sparse seed 42, 1,000 inserts | 19,000 ticks; view 3; checkpoint 927; 9 simultaneous faulty sectors |
| Native final ReleaseSafe | PASS: ext4, real io_uring, TCP, primary failure and full restart after 1,216,000 payload bytes |
| Static linking | ELF has no interpreter or dynamic section; Cobra is static too |
| SQLite source | No changes to the pinned source checkout or generated amalgamation |

The simulator has a 768 MiB physical budget per replica so the upstream fault atlas can enumerate
its blocks; wire constants, SQLite page size, LSM geometry, and VSR implementation match native.
The native capacity ceiling is 1 PiB. Maximum populated capacity and its startup memory footprint
were not tested. Older 4 KiB-page prototype evidence remains in the parent `test-results/` directory
for provenance and is superseded by the capacity results above.
The retained native Debug log is an earlier capacity build; the native ReleaseSafe log matches
the final executable hashes. `project-source.sha256` records the corresponding Zig sources.

## Heap limit and temporary-file spill

See [spill.md](spill.md) for the shared compile-time heap/pool limit, native io_uring scratch
crash/corruption tests, deterministic VSR replay campaigns, and their raw evidence. The previous
64 MiB memory-only performance results remain historical; the current default is 512 MiB.

## Six-container replication test

See [container-testing.md](container-testing.md) for the native six-replica OCI chaos harness,
its write correctness model, quorum checks, logs, and reproduction instructions.
