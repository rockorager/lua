//! The engine itself, for the standalone `lua` and the repository's tools.
//! Unstable: it changes with the engine, and nothing here is part of the
//! embedding API.

pub const Value = @import("Value.zig");
pub const gc = @import("gc.zig");
pub const String = @import("String.zig");
pub const Table = @import("Table.zig");
pub const Proto = @import("Proto.zig");
pub const Userdata = @import("Userdata.zig");
pub const State = @import("State.zig");
pub const Thread = @import("Thread.zig");
pub const opcodes = @import("opcodes.zig");
pub const vm = @import("vm.zig");
pub const debuginfo = @import("debuginfo.zig");
pub const Parser = @import("Parser.zig");
pub const Code = @import("Code.zig");
/// `string.dump`'s binary chunks: writing and loading them.
pub const dump = @import("dump.zig");
pub const undump = @import("undump.zig");
/// The standard libraries; `lib.openLibs` opens them.
pub const lib = @import("lib/init.zig");
/// What the libraries share: argument checks, buffers, conversions.
pub const auxlib = @import("lib/auxlib.zig");
