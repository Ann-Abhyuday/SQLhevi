const std = @import("std");
const assert = std.debug.assert;
const vsr = @import("vsr");
const stdx = @import("stdx");
const constants = vsr.constants;
const sqlite = @import("sqlite.zig");
const limits = @import("limits.zig");
const root = @import("root");
const fixture_compiled = @hasDecl(root, "simulation_sparse");
const Fixture = if (fixture_compiled) @import("sparse_fixture.zig").Source else void;

// The original VSR replica, grid, LSM, repair, and checkpoint machinery owns durability.
// SQLite remains the SQL engine and owns every byte of the logical database image.
pub fn StateMachineType(comptime Storage: type) type {
    return struct {
        options: Options,
        forest: Forest,
        engine: sqlite.Engine,
        pager: sqlite.pager.Pager,
        fixture: Fixture = if (fixture_compiled) .{} else {},
        request: []const u8 = &.{},
        request_op: u64 = 0,
        snapshot: u64 = 0,
        fetch_keys: [limits.chunks_changed_max]u64 = undefined,
        fetch_count: u32 = 0,
        prepared: bool = false,
        response: [constants.message_body_size_max]u8 = undefined,
        response_size: u32 = 0,
        failure: ?anyerror = null,
        prefetch_timestamp: u64 = 0,
        prepare_timestamp: u64 = 0,
        commit_timestamp: u64 = 0,
        prefetch_context: Pages.PrefetchContext = undefined,
        callback: ?*const fn (*StateMachine) void = null,

        const StateMachine = @This();
        const Grid = vsr.GridType(Storage);
        const Page = sqlite.pager.Chunk;
        const Pages = vsr.lsm.groove.GrooveType(Storage, Page, .{
            .ids = .{ .timestamp = 1 },
            .batch_value_count_max = .{ .timestamp = limits.chunks_changed_max },
            .primary_key = "timestamp",
            .primary_key_orphaned = false,
            .unique_keys = &[_][:0]const u8{},
            .ignored = &[_][:0]const u8{ "image_size", "bytes" },
            .optional = &[_][:0]const u8{},
            .derived = .{},
            .objects_cache = true,
        });
        pub const Forest = vsr.lsm.forest.ForestType(Storage, .{ .pages = Pages });
        comptime {
            assert(@sizeOf(Pages.ObjectTree.Manifest.TreeTableInfo) == 64);
            assert(Pages.ObjectTree.Table.value_count_max ==
                limits.chunks_changed_max * constants.lsm_compaction_ops);
        }
        pub const Options = struct {
            scratch_store: ?*sqlite.scratch.Store = null,
            scratch_fault: ?*const fn (*StateMachine) void = null,
            batch_size_limit: u32 = limits.sql_size_max,
            lsm_forest_compaction_block_count: u32 = Forest.Options.compaction_block_count_min,
            lsm_forest_node_count: u32 = 1024,
        };
        pub const Operation = enum(u8) {
            sql = constants.vsr_operations_reserved,

            pub fn EventType(comptime _: Operation) type {
                return u8;
            }
            pub fn ResultType(comptime _: Operation) type {
                return u8;
            }
            pub fn result_size(_: Operation) u32 {
                return 1;
            }
            pub fn event_size(_: Operation) u32 {
                return 1;
            }
            pub fn from_vsr(operation: vsr.Operation) ?Operation {
                if (operation.vsr_reserved()) return null;
                return vsr.Operation.to(Operation, operation);
            }
            pub fn to_vsr(operation: Operation) vsr.Operation {
                return vsr.Operation.from(Operation, operation);
            }
        };

        pub fn init(
            self: *StateMachine,
            allocator: std.mem.Allocator,
            _: stdx.Time,
            grid: *Grid,
            options: Options,
        ) !void {
            assert(options.batch_size_limit <= limits.sql_size_max);
            assert(@sizeOf(Page) == 512);
            self.* = .{
                .options = options,
                .forest = undefined,
                .engine = undefined,
                .pager = undefined,
            };
            try self.pager.init(allocator);
            errdefer self.pager.deinit(allocator);
            try self.engine.init(allocator);
            self.engine.scratch_store = options.scratch_store;
            errdefer self.engine.deinit(allocator);
            if (fixture_compiled) {
                if (root.simulation_sparse) try self.fixture.init(&self.engine);
            }
            try self.forest.init(allocator, grid, .{
                .compaction_block_count = options.lsm_forest_compaction_block_count,
                .node_count = options.lsm_forest_node_count,
            }, .{ .pages = .{
                .cache_entries_max = limits.read_chunks_max,
                .prefetch_entries_for_read_max = limits.read_chunks_max,
                .prefetch_entries_for_update_max = limits.chunks_changed_max,
                .tree_options_object = .{ .batch_value_count_limit = limits.chunks_changed_max },
                .tree_options_index = .{},
            } });
        }

        pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
            assert(self.pager.entries.len == limits.read_chunks_max);
            assert(self.options.batch_size_limit <= limits.sql_size_max);
            self.forest.deinit(allocator);
            self.engine.deinit(allocator);
            self.pager.deinit(allocator);
        }

        pub fn reset(self: *StateMachine) void {
            assert(self.pager.entries.len == limits.read_chunks_max);
            assert(self.engine.memory.len == limits.database_size_max);
            self.forest.reset();
            self.pager.reset();
            self.request = &.{};
            self.request_op = 0;
            self.snapshot = 0;
            self.fetch_count = 0;
            self.prepared = false;
            self.response_size = 0;
            self.failure = null;
            self.prefetch_timestamp = 0;
            self.prepare_timestamp = 0;
            self.commit_timestamp = 0;
            self.callback = null;
        }

        pub fn open(self: *StateMachine, callback: *const fn (*StateMachine) void) void {
            assert(self.callback == null);
            assert(self.pager.count == 0);
            self.callback = callback;
            self.forest.open(forest_callback);
        }

        fn forest_callback(forest: *Forest) void {
            const self: *StateMachine = @fieldParentPtr("forest", forest);
            assert(self.callback != null);
            const callback = self.callback.?;
            self.callback = null;
            assert(self.pager.entries.len == limits.read_chunks_max);
            callback(self);
        }

        pub fn pulse_needed(self: *const StateMachine, _: u64) bool {
            assert(self.pager.entries.len == limits.read_chunks_max);
            assert(self.engine.memory.len == limits.database_size_max);
            return false;
        }

        pub fn input_valid(
            self: *const StateMachine,
            operation: Operation,
            input: []align(constants.cache_line_size) const u8,
        ) bool {
            assert(operation == .sql);
            assert(self.options.batch_size_limit <= limits.sql_size_max);
            return input.len > 0 and input.len <= self.options.batch_size_limit;
        }

        pub fn prepare(
            self: *StateMachine,
            operation: Operation,
            input: []align(constants.cache_line_size) const u8,
        ) void {
            assert(operation == .sql);
            assert(self.input_valid(operation, input));
        }

        pub fn prefetch(
            self: *StateMachine,
            callback: *const fn (*StateMachine) void,
            op: u64,
            snapshot: u64,
            operation: Operation,
            input: []align(constants.cache_line_size) const u8,
        ) void {
            assert(op > 0);
            assert(self.callback == null);
            assert(self.input_valid(operation, input));
            self.callback = callback;
            self.pager.reset();
            self.request = input;
            self.request_op = op;
            self.snapshot = snapshot;
            self.prepared = false;
            self.failure = null;
            self.fetch_keys[0] = 1;
            self.fetch_count = 1;
            self.fetch();
        }

        fn prefetch_callback(context: *Pages.PrefetchContext) void {
            const self: *StateMachine = @alignCast(@fieldParentPtr("prefetch_context", context));
            assert(self.callback != null);
            self.forest.grooves.pages.prefetch_finish();
            if (self.prepared) return self.prefetch_done();
            for (self.fetch_keys[0..self.fetch_count]) |key| {
                const page = self.forest.grooves.pages.get(key);
                var chunk: Page = if (page == .found_object) page.found_object else .{
                    .timestamp = key,
                    .image_size = 0,
                    .bytes = @splat(0),
                };
                if (fixture_compiled) {
                    if (root.simulation_sparse and page != .found_object) self.fixture.fill(&chunk);
                }
                self.pager.supply(&chunk, page == .found_object) catch |err| {
                    self.failure = err;
                    return self.prefetch_done();
                };
            }
            assert(self.pager.count > 0);
            self.evaluate();
        }

        fn evaluate(self: *StateMachine) void {
            assert(self.callback != null);
            assert(!self.prepared);
            self.engine.execute_paged(&self.pager, self.request, .{
                .op = self.request_op,
                .timestamp = self.prefetch_timestamp,
            }, self.response[4..]) catch |err| {
                if (err == error.ScratchIO) return self.scratch_fault();
                if (self.pager.failure) |failure| {
                    self.failure = failure;
                } else if (self.pager.missing) |key| {
                    return self.fetch_missing(key);
                } else self.failure = err;
                return self.prefetch_done();
            };
            self.pager.finish() catch |err| {
                self.failure = err;
                return self.prefetch_done();
            };
            self.prepared = true;
            self.response_size = 4 + self.engine.output_size;
            @memcpy(self.response[0..4], "OK\n\n");
            self.fetch_count = self.pager.write_count;
            for (self.pager.writes[0..self.fetch_count], 0..) |*chunk, index| {
                self.fetch_keys[index] = chunk.timestamp;
            }
            // Re-pin every write in the original groove cache before its update assertions run.
            self.fetch();
        }

        fn scratch_fault(self: *StateMachine) void {
            assert(!self.prepared);
            assert(self.pager.write_count == 0);
            assert(self.engine.scratch_store.?.failure != null);
            // Local faults cannot become SQL replies: peers may execute successfully. Never
            // invoke commit-prefetch's callback here. Recovery replays the ordered request.
            if (self.options.scratch_fault) |callback| return callback(self);
            std.log.err("local scratch failure: {s}; stopping replica before applying SQL", .{
                @errorName(self.engine.scratch_store.?.failure.?),
            });
            std.process.exit(74);
        }

        fn fetch_missing(self: *StateMachine, key: u64) void {
            assert(key >= 2);
            assert(self.pager.get(key) == null);
            self.fetch_count = 0;
            // Fetch enough chunks for a SQLite page, including unaligned endpoints.
            for (key..key + limits.page_size / limits.chunk_size + 2) |next| {
                if (self.pager.get(next) != null) continue;
                if (self.pager.count + self.fetch_count == limits.read_chunks_max) break;
                self.fetch_keys[self.fetch_count] = next;
                self.fetch_count += 1;
            }
            if (self.fetch_count == 0) {
                self.failure = error.ReadSetLimit;
                return self.prefetch_done();
            }
            self.fetch();
        }

        fn fetch(self: *StateMachine) void {
            assert(self.callback != null);
            assert(self.fetch_count <= self.fetch_keys.len);
            self.forest.grooves.pages.prefetch_begin(self.snapshot);
            for (self.fetch_keys[0..self.fetch_count]) |key| {
                self.forest.grooves.pages.prefetch_enqueue(.{ .timestamp = key });
            }
            // Upstream always schedules this callback asynchronously, including cache-only reads.
            self.forest.grooves.pages.prefetch(prefetch_callback, &self.prefetch_context);
        }

        fn prefetch_done(self: *StateMachine) void {
            assert(self.callback != null);
            assert(self.prepared or self.failure != null);
            const callback = self.callback.?;
            self.callback = null;
            callback(self);
        }

        pub fn commit(
            self: *StateMachine,
            _: u128,
            op: u64,
            timestamp: u64,
            operation: Operation,
            input: []align(constants.cache_line_size) const u8,
            output: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            assert(op > 0);
            assert(self.callback == null);
            assert(self.input_valid(operation, input));
            assert(op == self.request_op);
            assert(timestamp == self.prefetch_timestamp);
            assert(std.mem.eql(u8, input, self.request));
            if (self.failure) |err| {
                const reply = std.fmt.bufPrint(output, "ERR {s}\n", .{
                    @errorName(err),
                }) catch unreachable;
                return reply.len;
            }
            assert(self.prepared);
            self.commit_pages();
            @memcpy(output[0..self.response_size], self.response[0..self.response_size]);
            return self.response_size;
        }

        fn commit_pages(self: *StateMachine) void {
            assert(self.prepared);
            assert(self.pager.write_count <= limits.chunks_changed_max);
            for (self.pager.writes[0..self.pager.write_count]) |*page| {
                const previous = self.forest.grooves.pages.get(page.timestamp);
                switch (previous) {
                    .found_object => |old| {
                        assert(self.pager.get(page.timestamp).?.found);
                        if (stdx.equal_bytes(Page, &old, page)) continue;
                        self.forest.grooves.pages.update(.{ .old = &old, .new = page });
                    },
                    .not_found => self.forest.grooves.pages.insert(page),
                }
            }
        }

        pub fn compact(
            self: *StateMachine,
            callback: *const fn (*StateMachine) void,
            op: u64,
        ) void {
            assert(op > 0);
            assert(self.callback == null);
            self.callback = callback;
            self.forest.compact(forest_callback, op);
        }

        pub fn checkpoint(self: *StateMachine, callback: *const fn (*StateMachine) void) void {
            assert(self.callback == null);
            assert(self.pager.entries.len == limits.read_chunks_max);
            self.callback = callback;
            self.forest.checkpoint(forest_callback);
        }
    };
}
