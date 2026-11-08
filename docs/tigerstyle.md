# TigerStyle and SQLite memory audit

The reference is the pinned [TigerStyle](../dependencies/tigerbeetle/docs/TIGER_STYLE.md).
The project's checks apply to `build.zig`, `src/`, `tools/`, and `tests/`; third-party sources
retain their upstream style and licenses. SQLite is an explicit dependency exception and its
source remains unchanged. A style checker cannot certify design quality or absence of bugs.

## SQLite is not stack-only

TigerStyle permits memory allocation at startup. It prohibits allocation, freeing, and
reallocation after initialization. SQLite uses heap allocations during connection setup,
statement preparation, execution, page caching, and cleanup. Thus unmodified SQLite does not
meet the literal allocation rule. Restricting those allocations to a fixed arena bounds memory
use, but does not turn them into stack allocation or eliminate runtime suballocation.

The build uses SQLite's supported configuration mechanisms:

| Control | Effect |
|---|---|
| `SQLITE_ENABLE_MEMSYS5` | Makes SQLite's fixed-pool buddy allocator available |
| `SQLITE_CONFIG_HEAP` | Supplies the startup-reserved pool (512 MiB by default) before initialization |
| `SQLITE_ZERO_MALLOC` | Compiles a failing default allocator instead of system malloc |
| `SQLITE_OMIT_AUTOINIT` | Prevents implicit initialization before the heap is configured |
| `SQLITE_CONFIG_GETMALLOC` / `SQLITE_CONFIG_MALLOC` | Installs Zig auditing callbacks around memsys5 |
| `SQLITE_DEFAULT_MEMSTATUS=1`, `SQLITE_CONFIG_MEMSTATUS` | Enables allocation accounting for the hard limit |
| `sqlite3_hard_heap_limit64()` | Enforces the same compile-time limit used for the fixed pool |
| `SQLITE_OS_OTHER`, `SQLITE_TEMP_STORE=1` | Restricts I/O to the Zig main-page and scratch VFS |
| `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_MAX_MMAP_SIZE=0` | Prevents external extensions and mapped I/O |

`sqlite_memory.zig` checks that every returned allocation and its entire reported size fit
inside the pool. It tracks allocations, failures, live bytes, and high-water usage without
allocating memory itself. Exhaustion tests request more than the pool can supply, require a
null result, then verify subsequent allocation and freeing work with unchanged live bytes.
The wrapper also accepts memsys5's zero-size sentinel for requests larger than 1 GiB, and tests
that a rejected resize preserves its original allocation. Hard-limit tests verify rejection
before the pool allocator is called; they restore both hard and soft limits afterwards.
The SQL contract tests continue to run with this configuration in Debug and ReleaseSafe.

Relevant unchanged SQLite sources are `src/main.c` (configuration and initialization),
`src/sqliteInt.h` (allocator selection), `src/mem5.c` (pool allocation), and `src/mem0.c`
(the zero allocator). See also SQLite's [memory documentation](https://sqlite.org/malloc.html)
and [configuration API](https://sqlite.org/c3ref/c_config_covering_index_scan.html).

## Automated checks

Run `zig build check` using the pinned toolchain and caches described in the README.
`style` builds a Zig driver which invokes the downloaded Cobra executable with a rule file.
The Zig tokenizer masks literals without changing line locations before Cobra sees the source.
The original source is independently parsed with Zig's AST.

Checks include:

- Zig formatting, 100-column lines, and no tab indentation.
- A 70-line function limit, independently checked by Cobra and Zig's AST.
- Direct recursion, forbidden C allocation/control-flow tokens, and snake_case function names.
- Repeated positional integer types require named options; prescribed C and VSR callback
  signatures retain their upstream ABI.
- A fixed-bound requirement for ordinary loops; the sole replica event loop has an explicit
  `unreachable` assertion after it. Finite slice/range loops remain subject to manual bound review.
- Separate compound assertions and rejection of `assert(true)` in function bodies.
- At least two assertions per named function on average. Type-producing factories are excluded;
  their member functions are counted. Assertions in test blocks and top-level `comptime` blocks
  are excluded, so those cannot raise the reported density.
- Known Zig allocation APIs rejected in `src/` outside reviewed initialization/teardown
  functions. This syntactic check cannot prove properties of arbitrary indirect/library calls.
- Negative self-tests for recursion, function length, C allocation, loop bounds, assertion
  form, runtime allocation, naming, ambiguous integer parameters, and exclusion of non-function
  assertions from density.

Only Debug and ReleaseSafe builds are accepted; release modes that remove safety checks are
rejected. Assertion predicates encode invariants rather than being added solely to meet density.

## Manual review boundaries

| Area | Reviewed property and remaining boundary |
|---|---|
| Replica adapter allocation | Pager, forest, engine, scratch cache/hash/checksum buffers allocated before serving; request paths use fixed storage. SQLite's pool suballocation is the explicit exception above. |
| Loops and queues | Probe tables never exceed half occupancy; reads/writes have page and chunk bounds; SQL has statement/row/work limits; prefetch retries increase a bounded read set. |
| Callback cycles | Cache-only prefetch completion is queued through the upstream next-tick queue, preventing synchronous recursive retry growth. |
| Large values | Owned large structs initialize through pointers; chunks are passed by pointer. Explicit snapshot copies in tests preserve expected results. Upstream APIs retain their prescribed value semantics. |
| Integer widths | Persisted lengths, offsets, and keys are `u64`; capacities/counts use `u32`. `usize` remains at mandated VSR/syscall/allocator interfaces and pointer conversion boundaries. The capacity command exercises the actual upstream node allocator through a recording allocator to detect narrowed multiplication without reserving gigabytes. |
| Failure atomicity | SQL errors, output overflow, read/write-set exhaustion, and SQLite FULL discard the private overlay. Local scratch faults discard the overlay and stop the replica, so they cannot create divergent replicated error results. Paired commit assertions match operation, SQL, timestamp, and prefetched state. |
| Storage | Native content and lifecycle I/O use io_uring. Advisory ownership locking uses Linux flock, which has no io_uring operation. |
| Build/test tools | Bounded setup allocations and process creation are allowed outside replica request execution; tooling is not claimed to have the replica's startup-only allocation lifecycle. |

Reviewing indirect recursion, every external call, and assertion meaning requires human judgment;
passing these checks is not a claim of comprehensive formal TigerStyle compliance. The project
also intentionally differs from TigerBeetle's zero-dependency policy by depending on SQLite,
as required by SQLhevi's design.
