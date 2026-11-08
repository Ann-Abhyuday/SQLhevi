# Six-container replication test

The Zig driver in [container_chaos.zig](../tests/container_chaos.zig) runs the production SQLhevi
binary in six OCI containers using `runc`. Each has separate PID, mount, UTS, IPC, and cgroup
namespaces, a read-only root filesystem containing only the static SQLhevi executable, and a
persistent private data-directory bind mount. The driver verifies those namespaces and checks
that each SQLhevi process is PID 1 inside its container, including after each restart.

All containers use the Linux guest's network namespace, with TCP ports 3601–3606. This is
equivalent to container host networking; it tests process failures and reconnection, not network
partitions or independent-machine failures. Each data directory is on the same guest ext4 disk.
Keep disks and machines independent for deployment fault tolerance.

The host Docker socket was inaccessible and host io_uring was restricted, so this test runs
inside the existing Alpine-kernel QEMU guest. Container lifecycle uses the installed runc 1.5.2
test tool. runc, its host libraries, QEMU, and the guest kernel are test infrastructure outside
the container root filesystems, not linked SQLhevi dependencies. The database and Zig test
executables remain statically linked. The default 512 MiB SQLite pool is unchanged; each replica
uses a 1 GiB VSR storage budget. The guest has 11 GiB RAM and four virtual CPUs, using software
emulation. Timings from this environment are not throughput measurements.

## Recorded result — 2026-11-08

Historical names in the following evidence were normalized during the project rename; see the
[evidence provenance note](test-results/README.md). This campaign predates the renamed build.

**All three campaigns passed.** The production change was accepting the upstream's full range
of one through six replicas in `format`, `start`, and `sql`. Neither SQLite source nor VSR
consensus code changed for this test.

| Seed | Acknowledged workload transactions | Injected SIGKILLs | Full-data checks | Atomic rejections | Final view |
|---|---:|---:|---:|---:|---:|
| 7 | 488 | 55 | 31 | 4 | 19 |
| 42 | 488 | 55 | 31 | 4 | 25 |
| 777 | 488 | 55 | 31 | 4 | 25 |
| **Total** | **1,464** | **165** | **93** | **12** | — |

No missing, duplicated, extra, incorrect, or partially applied acknowledged writes were detected.
Every random failure round had a write awaiting acknowledgement at its first kill: 48 such
rounds across the three seeds. All intentional SQL rejections left the model unchanged.
Writes progressed with two replicas down, waited with only two alive, and completed once after
quorum returned. All three complete-cluster restarts preserved acknowledged data.

There were 183 verified container starts and 183 successful kills including final cleanup;
the table excludes the 18 cleanup kills. All containers were stopped after testing. The audit
examined all 183 per-start replica logs (1,094,041 aggregate bytes including file labels) and
found no panic, failed-assertion, fatal, segmentation, or `error:` matches. Expected connection
refusal/reset warnings during shutdown and startup remain in the logs.

The native run used ReleaseSafe. The build checks passed all 19 unit tests, formatting, and
Cobra/AST positive and negative checks: 37 Zig files, 613 function-body assertions, and 284
named functions (2.16 assertions per function). ELF inspection found no dynamic section or
interpreter in either SQLhevi or the Zig container driver. SQLite's source checkout remained
unchanged; the generated amalgamation and header retained their prior checksums.

Evidence: [campaign log](test-results/containers/campaign.log),
[compressed replica logs](test-results/containers/replica-logs.log.gz),
[log audit](test-results/containers/replica-log-audit.txt),
[build checks](test-results/containers/check.log),
[sample OCI bundle configuration](test-results/containers/sample-oci-config.json),
[executable/kernel/runtime hashes](test-results/containers/artifacts.sha256), and
[tested source hashes](test-results/containers/source.sha256).
The local persistent test disk is `.tooling/containers/campaign.ext4`.

## Workload and oracle

Each campaign has one client session that stays alive throughout the failures. A pending request
keeps its original VSR request identity and is retried by the upstream client. The harness never
resubmits an indeterminate write in a new session.

Each acknowledged write inserts an identified row in `ledger`, inserts its negative value into
`audit`, and adds the value to `balances` in one atomic request. Its returned balance must equal
the independent Zig model. Full verification checks every ordered row, both values in the join,
the audit count, and the balance. Missing, duplicated, extra, partially applied, and incorrect
rows fail the test. Intentional uniqueness failures first stage a balance change and a new row;
the harness checks that the entire rejected request was rolled back.

Three fresh clusters use seeds 7, 42, and 777. Each performs:

1. 64 initial writes, then 16 rounds of random double failures with 16 writes per round.
   Half the rounds deliberately include the client's last observed primary. Crash timing,
   other victims, and restart order vary. Requests are submitted before the first kill.
2. One replica held down for 160 writes, exceeding the 128-slot journal's length.
3. Four replicas killed, leaving two. A write must receive no acknowledgement during 300 client
   ticks. Restoring two nodes must complete that same request exactly once.
4. All six replicas killed. A pending write stays unacknowledged with no servers; restarting
   from the same files must preserve all previous acknowledgements and complete that request.
5. Six more double-failure combinations, checking every prior row and accepting another write
   with each set of four survivors.

Six replicas use the upstream quorums without consensus changes: three for replication and four
for view change. Availability with any two failures is tested. Three survivors can sometimes
continue in an established view; this is not a guarantee of failover with three nodes down.

Seeds control randomized choices. Native OS scheduling, TCP timing, and election timing remain
nondeterministic; use `SQLhevi-sim` for deterministic simulation. A passing finite campaign
does not establish correctness for every possible failure, power loss, disk corruption, or
network partition. Queries verify replicated results through VSR; they are not offline bytewise
comparisons of six storage images.

## Reproduce

Prepare the pinned kernel and five modules using [testing.md](testing.md). Build and stage:

```sh
export ZIG_GLOBAL_CACHE_DIR="$PWD/.tooling/global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/.tooling/cache"
.tooling/zig-x86_64-linux-0.16.0/zig build install container-tests check -Doptimize=ReleaseSafe -j4
mkdir -p .tooling/containers/guest/lib .tooling/containers/guest/usr/lib \
  .tooling/containers/guest/lib64
cp .tooling/guest/lib/*.ko .tooling/containers/guest/lib/
cp zig-out/bin/SQLhevi .tooling/containers/guest/SQLhevi
cp zig-out/bin/SQLhevi-test-containers .tooling/containers/guest/init
cp /usr/bin/runc .tooling/containers/guest/runc
# These paths match the installed runc used for this run; inspect ldd on another system.
cp -L /usr/lib/libseccomp.so.2 /usr/lib/libpathrs.so /usr/lib/libc.so.6 \
  /usr/lib/libgcc_s.so.1 .tooling/containers/guest/usr/lib/
cp -L /usr/lib64/ld-linux-x86-64.so.2 .tooling/containers/guest/lib64/
(cd .tooling/containers/guest && find . -print0 | cpio --null --quiet -o -H newc \
  | gzip -1 > ../guest.cpio.gz)
```

A static runc binary can instead be copied without its shared libraries. The container runtime
is an external development tool; no library is copied into any SQLhevi container. The harness
uses runc's documented `--no-pivot` mode because the guest boots from initramfs. It creates
cgroups in its disposable guest, has no external network, and does not access the host daemon.

Use a **new** disposable disk for each campaign run. All three seeds run sequentially with fresh
directories. Existing directories cause failure rather than overwriting databases.

```sh
set -e
test ! -e .tooling/containers/reproduction.ext4
truncate -s 8G .tooling/containers/reproduction.ext4
mkfs.ext4 -q -F .tooling/containers/reproduction.ext4
timeout 1800 qemu-system-x86_64 -accel tcg -machine q35 -cpu max -m 11264 -smp 4 \
  -display none -serial file:.tooling/containers/reproduction.log -monitor none -no-reboot \
  -kernel .tooling/alpine/boot/vmlinuz-virt -initrd .tooling/containers/guest.cpio.gz \
  -append 'console=ttyS0 rdinit=/init panic=1 quiet' \
  -drive file=.tooling/containers/reproduction.ext4,format=raw,if=virtio -nic none
rg 'CONTAINER CHAOS|quorum unavailable|all six SIGKILL' .tooling/containers/reproduction.log
```

Require three `CONTAINER CHAOS PASS` lines and `CONTAINER CHAOS ALL PASS`, and reject any
`FAIL`, panic, or timeout. A QEMU exit status of zero alone does not mean the workload passed.
Per-start replica logs and generated OCI bundles remain on the ext4 image at
`/seed-<seed>/<replica>/`; the harness syncs test logs before powering off.
