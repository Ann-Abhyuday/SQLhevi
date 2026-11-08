# Third-party sources and notices

| Component | Use | License/notice |
|---|---|---|
| SQLite | Main SQL/B-tree engine; static C archive | [Public-domain notice](dependencies/sqlite/LICENSE.md) |
| TigerBeetle | VSR, checksummed storage, LSM page container, simulator, Zig utilities | [Apache-2.0](dependencies/tigerbeetle/LICENSE) |
| Cobra | Static analysis during development only | [Caltech/Nimble license](dependencies/cobra/doc/License) |
| Zig toolchain | Compiler and bundled standard library | `.tooling/zig-x86_64-linux-0.16.0/LICENSE` |
| musl | Statically linked C runtime | `.tooling/zig-x86_64-linux-0.16.0/lib/libc/musl/COPYRIGHT` |
| Alpine Linux kernel | Optional isolated native test VM only | Linux GPL-2.0 and per-module notices; not linked into SQLhevi |

Upstream source and copyright notices are retained. Exact source revisions and toolchain hashes are
in [dependencies.lock.json](dependencies.lock.json). The TigerBeetle modification is identified in
[docs/tigerbeetle.patch](docs/tigerbeetle.patch). It exposes configuration, initializes complete
journal slots, bounds manifest memory reservations by the physical storage budget, and widens
node-pool byte arithmetic beyond 4 GiB. Consensus
and fault-injection algorithms are unchanged.
The SQLhevi state-machine interface follows TigerBeetle's generic state-machine contract and its
testing state-machine example. SQLite source, license, and blessing comments are unchanged.

Cobra's original implementation is copyright 2016 California Institute of Technology, with U.S.
Government sponsorship acknowledged; later versions are copyright Gerard Holzmann/Nimble Research.
Its complete conditions and disclaimer accompany the source under `dependencies/cobra/doc/License`.
Include that notice when redistributing its binary. Retain the TigerBeetle and musl notices when
redistributing statically linked SQLhevi binaries. These components do not endorse SQLhevi.
