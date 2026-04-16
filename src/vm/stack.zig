const std = @import("std");
const frame = @import("frame.zig");

/// Operand stack for the Move VM
pub const Stack = struct {
    /// Stack values
    data: std.ArrayList(frame.Value),
    /// Maximum stack size (for safety checks)
    max_size: u32,

    const default_max_size = 1024;

    /// Initialize a new stack
    pub fn init(allocator: std.mem.Allocator) Stack {
        return .{
            .data = std.ArrayList(frame.Value).empty,
            .max_size = default_max_size,
        };
    }

    /// Initialize with custom max size
    pub fn initMax(allocator: std.mem.Allocator, max_size: u32) Stack {
        return .{
            .data = std.ArrayList(frame.Value).empty,
            .max_size = max_size,
        };
    }

    /// Get current stack size
    pub fn len(self: Stack) u32 {
        return @intCast(self.data.items.len);
    }

    /// Check if stack is empty
    pub fn isEmpty(self: Stack) bool {
        return self.data.items.len == 0;
    }

    /// Push a value onto the stack
    pub fn push(self: *Stack, allocator: std.mem.Allocator, value: frame.Value) !void {
        if (self.data.items.len >= self.max_size) {
            return error.StackOverflow;
        }
        try self.data.append(allocator, value);
    }

    /// Pop a value from the stack
    pub fn pop(self: *Stack) !frame.Value {
        if (self.data.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.data.pop();
    }

    /// Peek at top value without removing
    pub fn peek(self: Stack) !frame.Value {
        if (self.data.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.data.items[self.data.items.len - 1];
    }

    /// Peek at value at offset from top
    pub fn peekOffset(self: Stack, offset: u32) !frame.Value {
        const stack_len = self.data.items.len;
        if (offset >= stack_len) {
            return error.StackUnderflow;
        }
        return self.data.items[stack_len - 1 - offset];
    }

    /// Set value at offset from top
    pub fn setOffset(self: *Stack, offset: u32, value: frame.Value) !void {
        const stack_len = self.data.items.len;
        if (offset >= stack_len) {
            return error.StackUnderflow;
        }
        self.data.items[stack_len - 1 - offset] = value;
    }

    /// Clear the stack
    pub fn clear(self: *Stack) void {
        self.data.clearRetainingCapacity();
    }

    /// Deallocate
    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }
};
