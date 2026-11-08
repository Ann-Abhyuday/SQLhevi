# Reproducible development

The project uses three source checkouts and a pinned Zig toolchain. No package manager or system
SQLite library participates in the runtime build. Run commands from the SQLhevi root.

## Source acquisition

For a fresh workspace, clone and check out the exact commits:

```sh
mkdir -p dependencies .tooling/sqlite
git clone https://github.com/tigerbeetle/tigerbeetle.git dependencies/tigerbeetle
git -C dependencies/tigerbeetle checkout 68958eb757747d0fc96a79d1f9c2fa6766b67b48
git clone https://github.com/sqlite/sqlite.git dependencies/sqlite
git -C dependencies/sqlite checkout 85814474e5c49fdb706d98410696e3efc162b978
git clone https://github.com/nimble-code/Cobra.git dependencies/cobra
git -C dependencies/cobra checkout ce7d8c6a39c7c3917df9acc8cf6a59c3c685c2f5
(cd dependencies/tigerbeetle && git apply ../../docs/tigerbeetle.patch)
```

The TigerBeetle patch exports configuration, initializes full journal slots during format, and
bounds manifest maps by the physical storage budget without changing compaction pacing, and widens
node-pool byte arithmetic beyond 4 GiB. No VSR
algorithm or fault-injection changes are needed. SQLite has no patches. Its Fossil identifier is recorded
in the lock file because its Git hash is an identifier for the mirror, not the canonical repository.

## Toolchain and generated SQLite

```sh
curl --fail --location \
  https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
  --output .tooling/zig.tar.xz
echo '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  .tooling/zig.tar.xz' \
  | sha256sum --check
tar -xf .tooling/zig.tar.xz -C .tooling
(cd .tooling/sqlite && ../../dependencies/sqlite/configure --disable-shared --disable-readline)
make -C .tooling/sqlite -j4 sqlite3.c
make -C dependencies/cobra/src -j4 all F='-O2 -static'
export ZIG_GLOBAL_CACHE_DIR="$PWD/.tooling/global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/.tooling/cache"
.tooling/zig-x86_64-linux-0.16.0/zig build check install
```

Expected generated-source hashes at this revision:

| File | SHA-256 |
|---|---|
| `sqlite3.c` | `c10c0a3df44c43f445387e465dd880c10cf6ee0ba47e416f7f48116ea757b55e` |
| `sqlite3.h` | `7edd3751a1948786cc24b83ec17b73cb599676120fd0863dbf12bd944de68393` |

Do not hand-edit generated files. SQLite's source is a 3.55.0 development snapshot; the pin is
intentional and should be revisited before any production qualification.

## Mechanical style checks

`zig build style` runs the actual Cobra analyzer. The Zig wrapper discovers all project Zig files,
masks string/character literals with Zig's tokenizer, preserves line numbers, then submits the
sanitized source to Cobra with preprocessing disabled. This avoids misreading Zig multiline strings
as C code. It checks forbidden control/allocation tokens, unqualified direct recursion, function
length, line width, formatting, and function-body assertion density. Zig AST checks also enforce
loop bounds, assertion forms, naming, and known allocation boundaries. Type factories are exempt from
the function-length rule because they contain declarations rather than a single execution path.

The checker first runs deliberately failing examples for recursion, overlong functions, and heap
allocation. A silent/broken rule invocation therefore fails the check rather than reporting success.
Cobra findings refer to `.tooling/style/<index>.zig`; these preserve original source line numbers.
`.tooling/style/sources.txt` maps each sanitized file to its original path.

The remaining TigerStyle properties require human review: fixed runtime memory, indirect recursion,
callback scheduling, meaningful assertions, finite work, and complete error handling. SQLite's own
dynamic allocations are contained in the statically reserved heap and do not satisfy the literal
startup-only allocation rule; see [the memory audit](tigerstyle.md). New production Zig allocation
occurs during initialization; development tools and test teardown may allocate/free normally.

## Static linkage

```sh
file zig-out/bin/SQLhevi zig-out/bin/SQLhevi-sim dependencies/cobra/src/cobra
readelf -l zig-out/bin/SQLhevi
readelf -d zig-out/bin/SQLhevi
```

The runtime ELF has no interpreter and no dynamic dependencies. The project links SQLite as an
archive, musl statically, and uses Zig's native io_uring implementation; no liburing is involved.
The build accepts only Debug or ReleaseSafe so assertions and runtime safety remain enabled.
