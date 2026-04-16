pub const opcodes = @import("opcodes.zig");
pub const frame = @import("frame.zig");
pub const stack = @import("stack.zig");

var initialized = false;

pub fn isInitialized() bool {
    return initialized;
}

pub fn init() void {
    initialized = true;
}
