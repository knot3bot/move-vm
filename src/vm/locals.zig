const std = @import("std");
const values = @import("values.zig");
const Value = values.Value;
const ValueImpl = values.ValueImpl;
const Container = values.Container;
const ContainerRef = values.ContainerRef;

/// Locals for a function frame.
/// Backed by a heap-allocated container so references can point into it.
pub const Locals = struct {
    container: *Container,

    /// Create new locals with `n` Invalid slots.
    pub fn new(allocator: std.mem.Allocator, n: usize) !Locals {
        const container = try Container.new(allocator, .Vec);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try container.data.append(allocator, .Invalid);
        }
        return .{ .container = container };
    }

    /// Deinitialize locals (frees the backing container).
    pub fn deinit(self: *const Locals, allocator: std.mem.Allocator) void {
        self.container.deinit(allocator);
    }

    /// Copy a local value.
    pub fn copy_loc(self: *Locals, allocator: std.mem.Allocator, idx: usize) !Value {
        if (idx >= self.container.data.items.len) return error.IndexOutOfBounds;
        const v = self.container.data.items[idx];
        switch (v) {
            .Invalid => return error.InvalidLocal,
            else => return Value.init(try v.copy_value(allocator)),
        }
    }

    /// Move a local value (replaces with Invalid).
    pub fn move_loc(self: *Locals, idx: usize) !Value {
        if (idx >= self.container.data.items.len) return error.IndexOutOfBounds;
        const v = self.container.data.items[idx];
        switch (v) {
            .Invalid => return error.InvalidLocal,
            else => {
                self.container.data.items[idx] = .Invalid;
                return Value.init(v);
            },
        }
    }

    /// Store a value into a local slot (moves value).
    pub fn store_loc(self: *Locals, allocator: std.mem.Allocator, idx: usize, value: Value) !void {
        if (idx >= self.container.data.items.len) return error.IndexOutOfBounds;
        var old = self.container.data.items[idx];
        if (old != .Invalid and !old.canDrop()) {
            return error.TypeMismatch;
        }
        old.deinit(allocator);
        self.container.data.items[idx] = value.impl;
    }

    /// Borrow a reference to a local value.
    pub fn borrow_loc(self: *Locals, idx: usize, is_mutable: bool) !Value {
        if (idx >= self.container.data.items.len) return error.IndexOutOfBounds;
        const v = self.container.data.items[idx];
        switch (v) {
            .Invalid => return error.InvalidLocal,
            .Container => |c| {
                c.addRef();
                return Value.init(.{ .ContainerRef = .{
                    .container = c,
                    .is_mutable = is_mutable,
                    .is_global = false,
                    .global_status = null,
                } });
            },
            else => {
                self.container.addRef();
                return Value.init(.{ .IndexedRef = .{
                    .container_ref = .{
                        .container = self.container,
                        .is_mutable = is_mutable,
                        .is_global = false,
                        .global_status = null,
                    },
                    .idx = idx,
                } });
            },
        }
    }

    /// Swap a value into a local slot, returning the old value.
    pub fn swap_loc(self: *Locals, idx: usize, value: ValueImpl) !ValueImpl {
        if (idx >= self.container.data.items.len) return error.IndexOutOfBounds;
        const old = self.container.data.items[idx];
        self.container.data.items[idx] = value;
        return old;
    }

    /// Check if a local slot is Invalid.
    pub fn is_invalid(self: *Locals, idx: usize) !bool {
        if (idx >= self.container.data.items.len) return error.IndexOutOfBounds;
        return switch (self.container.data.items[idx]) {
            .Invalid => true,
            else => false,
        };
    }
};

// ==================== Tests ====================

test "Locals basic operations" {
    const allocator = std.testing.allocator;
    var locals = try Locals.new(allocator, 4);
    defer locals.deinit(allocator);

    // Initially all invalid
    try std.testing.expect(try locals.is_invalid(0));
    try std.testing.expectError(error.InvalidLocal, locals.copy_loc(allocator, 0));

    // Store
    try locals.store_loc(allocator, 1, Value.makeU64(42));
    const copied = try locals.copy_loc(allocator, 1);
    try std.testing.expect(try copied.equals(Value.makeU64(42)));

    // Move
    const moved = try locals.move_loc(1);
    try std.testing.expect(try moved.equals(Value.makeU64(42)));
    try std.testing.expect(try locals.is_invalid(1));

    // Borrow
    try locals.store_loc(allocator, 2, Value.makeU64(100));
    var borrowed = try locals.borrow_loc(2, true);
    defer borrowed.deinit(allocator);
    var read = try borrowed.read_ref(allocator);
    defer read.deinit(allocator);
    try std.testing.expect(try read.equals(Value.makeU64(100)));
}
