// Native test and benchmark exports. Production binaries do not import this module.
pub const sqlite = @import("sqlite.zig");
pub const memory = @import("sqlite_memory.zig");
pub const cluster = @import("config.zig").cluster;
pub const Operation = @import("state_machine.zig")
    .StateMachineType(@import("storage.zig").Storage).Operation;
