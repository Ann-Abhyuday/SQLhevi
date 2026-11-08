# SQLhevi rename validation

These checks ran on the renamed sources and executables with Zig 0.16.0,
`ReleaseSafe`, and the default 512 MiB SQLite memory limit.

```sh
zig build install benchmarks spill-tests container-tests check \
  -Doptimize=ReleaseSafe -j4 --summary all
```

- All 36 build steps succeeded, including all nine runtime and test executables.
- All 19 unit tests, formatting checks, and Cobra-backed TigerStyle checks passed.
- The style check counted 613 function-body assertions across 284 named functions.
- The main executable reports SQLhevi and has no dynamic section.
- The native three-replica test passed on ext4 using io_uring and TCP in a Linux
  QEMU guest. It checked primary failure, continued writes, and recovery after
  all replicas restarted. The final result is in `native.log`.
- SQLite's source checkout and generated amalgamation were not changed.

`artifacts.sha256` identifies the newly built executables; `source.sha256`
identifies the checked Zig files. `sqlite.sha256` records the unchanged SQLite
amalgamation. Binaries, VM images, build caches, and dependency checkouts are
local build artifacts and are excluded from the repository.

The six-container campaign, performance benchmarks, and scratch fault campaigns
were not rerun for this rename. Their historical evidence and qualifications are
described in [the evidence index](../README.md).
