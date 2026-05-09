const std = @import("std");
const values = @import("values.zig");
const Value = values.Value;
const ValueImpl = values.ValueImpl;

/// Operand stack for the Move VM.
pub const Stack = struct {
    values: std.ArrayList(Value),
    max_size: u32,

    const default_max_size = 1024;

    pub fn init(allocator: std.mem.Allocator) Stack {
        _ = allocator;
        return .{
            .values = std.ArrayList(Value).empty,
            .max_size = default_max_size,
        };
    }

    pub fn initMax(allocator: std.mem.Allocator, max_size: u32) Stack {
        _ = allocator;
        return .{
            .values = std.ArrayList(Value).empty,
            .max_size = max_size,
        };
    }

    pub fn len(self: Stack) u32 {
        return @intCast(self.values.items.len);
    }

    pub fn isEmpty(self: Stack) bool {
        return self.values.items.len == 0;
    }

    pub fn push(self: *Stack, allocator: std.mem.Allocator, value: Value) !void {
        if (self.values.items.len >= self.max_size) {
            return error.StackOverflow;
        }
        try self.values.append(allocator, value);
    }

    pub fn pop(self: *Stack) !Value {
        if (self.values.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.values.pop().?;
    }

    /// Pop a value and cast it to a specific type.
    pub fn popAs(self: *Stack, comptime T: type) !T {
        const val = try self.pop();
        return switch (T) {
            u8 => switch (val.impl) { .U8 => |x| x, else => error.TypeMismatch },
            u16 => switch (val.impl) { .U16 => |x| x, else => error.TypeMismatch },
            u32 => switch (val.impl) { .U32 => |x| x, else => error.TypeMismatch },
            u64 => switch (val.impl) { .U64 => |x| x, else => error.TypeMismatch },
            u128 => switch (val.impl) { .U128 => |x| x, else => error.TypeMismatch },
            u256 => switch (val.impl) { .U256 => |x| x, else => error.TypeMismatch },
            bool => switch (val.impl) { .Bool => |x| x, else => error.TypeMismatch },
            Value => val,
            else => error.TypeMismatch,
        };
    }

    /// Pop n values from the stack, returning them in order (oldest first).
    pub fn popn(self: *Stack, allocator: std.mem.Allocator, n: u16) ![]Value {
        if (self.values.items.len < n) return error.StackUnderflow;
        const start = self.values.items.len - n;
        const result = try allocator.alloc(Value, n);
        for (0..n) |i| {
            result[i] = self.values.items[start + i];
        }
        // Deinitialize the original stack slots before shrinking
        for (self.values.items[start..]) |*val| {
            val.deinit(allocator);
        }
        self.values.shrinkRetainingCapacity(start);
        return result;
    }

    /// Peek at the last n values without removing them.
    pub fn last_n(self: Stack, n: usize) ![]const Value {
        if (self.values.items.len < n) return error.StackUnderflow;
        return self.values.items[self.values.items.len - n ..];
    }

    pub fn peek(self: Stack) !Value {
        if (self.values.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.values.items[self.values.items.len - 1];
    }

    pub fn peekOffset(self: Stack, offset: u32) !Value {
        const stack_len = self.values.items.len;
        if (offset >= stack_len) {
            return error.StackUnderflow;
        }
        return self.values.items[stack_len - 1 - offset];
    }

    pub fn clear(self: *Stack) void {
        self.values.clearRetainingCapacity();
    }

    /// Clear the stack and deinitialize all values (for error cleanup).
    /// Iterates top-down so references are dropped before their targets.
    pub fn clearAndDeinit(self: *Stack, allocator: std.mem.Allocator) void {
        var i: usize = self.values.items.len;
        while (i > 0) {
            i -= 1;
            self.values.items[i].deinit(allocator);
        }
        self.values.clearRetainingCapacity();
    }

    /// Deinitialize all values and free the stack buffer.
    /// Iterates top-down so references are dropped before their targets.
    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        var i: usize = self.values.items.len;
        while (i > 0) {
            i -= 1;
            self.values.items[i].deinit(allocator);
        }
        self.values.deinit(allocator);
    }
};

// ==================== Tests ====================

test "Stack push and pop" {
    const allocator = std.testing.allocator;
    var stack = Stack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(allocator, Value.makeU64(1));
    try stack.push(allocator, Value.makeU64(2));
    try std.testing.expectEqual(@as(u32, 2), stack.len());

    const b = try stack.popAs(u64);
    try std.testing.expectEqual(@as(u64, 2), b);
    const a = try stack.popAs(u64);
    try std.testing.expectEqual(@as(u64, 1), a);
}

test "Stack popn" {
    const allocator = std.testing.allocator;
    var stack = Stack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(allocator, Value.makeU64(1));
    try stack.push(allocator, Value.makeU64(2));
    try stack.push(allocator, Value.makeU64(3));

    const vals = try stack.popn(allocator, 2);
    defer allocator.free(vals);
    try std.testing.expectEqual(@as(u64, 2), vals[0].impl.U64);
    try std.testing.expectEqual(@as(u64, 3), vals[1].impl.U64);
    try std.testing.expectEqual(@as(u32, 1), stack.len());
}
