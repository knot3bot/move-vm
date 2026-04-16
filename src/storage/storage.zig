const std = @import("std");
const frame = @import("../vm/frame.zig");

/// Storage interface for the Move VM
pub const Storage = struct {
    allocator: std.mem.Allocator,
    /// Global state: address -> (type_key -> value)
    globals: std.StringHashMap(std.StringHashMap(frame.Value)),
    /// Module cache
    modules: std.StringHashMap([]const u8),

    /// Initialize storage with allocator
    pub fn init(allocator: std.mem.Allocator) Storage {
        return .{
            .allocator = allocator,
            .globals = std.StringHashMap(std.StringHashMap(frame.Value)).init(allocator),
            .modules = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Get a global resource
    pub fn getGlobal(self: *Storage, address: []const u8, type_key: []const u8) !?frame.Value {
        const addr_map = self.globals.get(address) orelse return null;
        return addr_map.get(type_key);
    }

    /// Set a global resource
    pub fn setGlobal(self: *Storage, address: []const u8, type_key: []const u8, value: frame.Value) !void {
        var entry = try self.globals.getOrPut(address);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.StringHashMap(frame.Value).init(self.allocator);
        }
        try entry.value_ptr.put(type_key, value);
    }

    /// Remove a global resource
    pub fn removeGlobal(self: *Storage, address: []const u8, type_key: []const u8) bool {
        const addr_map = self.globals.get(address) orelse return false;
        return addr_map.remove(type_key);
    }

    /// Check if a global resource exists
    pub fn exists(self: Storage, address: []const u8, type_key: []const u8) bool {
        const addr_map = self.globals.get(address) orelse return false;
        return addr_map.contains(type_key);
    }

    /// Deallocate storage
    pub fn deinit(self: *Storage) void {
        var it = self.globals.valueIterator();
        while (it.next()) |inner_map| {
            inner_map.deinit();
        }
        self.globals.deinit();
        self.modules.deinit();
    }
};

var initialized = false;

pub fn isInitialized() bool {
    return initialized;
}

pub fn init() void {
    initialized = true;
}
