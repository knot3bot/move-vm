const std = @import("std");
const values = @import("../vm/values.zig");
const Value = values.Value;
const types = @import("../vm/types.zig");

/// Change log entry for transaction rollback.
const ChangeEntry = struct {
    address: []const u8,
    type_key: []const u8,
    old_value: ?Value,
};

/// DataStore interface for the Move VM.
pub const DataStore = struct {
    allocator: std.mem.Allocator,
    globals: std.StringHashMap(std.StringHashMap(Value)),
    modules: std.StringHashMap([]const u8),
    change_log: ?*std.ArrayList(ChangeEntry),

    pub fn init(allocator: std.mem.Allocator) DataStore {
        return .{
            .allocator = allocator,
            .globals = std.StringHashMap(std.StringHashMap(Value)).init(allocator),
            .modules = std.StringHashMap([]const u8).init(allocator),
            .change_log = null,
        };
    }

    pub fn deinit(self: *DataStore) void {
        var it = self.globals.iterator();
        while (it.next()) |entry| {
            var inner_it = entry.value_ptr.iterator();
            while (inner_it.next()) |inner_entry| {
                inner_entry.value_ptr.deinit(self.allocator);
                self.allocator.free(inner_entry.key_ptr.*);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.globals.deinit();
        self.modules.deinit();
    }

    /// Begin a transaction: enable change logging.
    pub fn beginTransaction(self: *DataStore) !void {
        if (self.change_log != null) return;
        const log = try self.allocator.create(std.ArrayList(ChangeEntry));
        log.* = std.ArrayList(ChangeEntry).empty;
        self.change_log = log;
    }

    /// Commit a transaction: discard change log.
    pub fn commitTransaction(self: *DataStore) void {
        const log = self.change_log orelse return;
        for (log.items) |entry| {
            self.allocator.free(entry.address);
            self.allocator.free(entry.type_key);
            if (entry.old_value) |v| {
                var val = v;
                val.deinit(self.allocator);
            }
        }
        log.deinit(self.allocator);
        self.allocator.destroy(log);
        self.change_log = null;
    }

    /// Rollback a transaction: restore all old values.
    pub fn rollbackTransaction(self: *DataStore) !void {
        const log = self.change_log orelse return;
        // Apply changes in reverse order
        var i: usize = log.items.len;
        while (i > 0) {
            i -= 1;
            const entry = log.items[i];
            if (entry.old_value) |old| {
                try self.setGlobalInternal(entry.address, entry.type_key, old);
            } else {
                _ = self.removeGlobalInternal(entry.address, entry.type_key);
            }
            self.allocator.free(entry.address);
            self.allocator.free(entry.type_key);
        }
        log.deinit(self.allocator);
        self.allocator.destroy(log);
        self.change_log = null;
    }

    fn logChange(self: *DataStore, address: []const u8, type_key: []const u8) !void {
        const log = self.change_log orelse return;
        const addr_copy = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(addr_copy);
        const type_copy = try self.allocator.dupe(u8, type_key);
        errdefer self.allocator.free(type_copy);
        const old = try self.getGlobal(address, type_key);
        var old_copy: ?values.Value = null;
        if (old) |v| {
            old_copy = try v.copy_value(self.allocator);
        }
        try log.append(self.allocator, .{
            .address = addr_copy,
            .type_key = type_copy,
            .old_value = old_copy,
        });
    }

    pub fn getGlobal(self: *DataStore, address: []const u8, type_key: []const u8) !?Value {
        const addr_map = self.globals.get(address) orelse return null;
        return addr_map.get(type_key);
    }

    pub fn setGlobal(self: *DataStore, address: []const u8, type_key: []const u8, value: Value) !void {
        try self.logChange(address, type_key);
        try self.setGlobalInternal(address, type_key, value);
    }

    fn setGlobalInternal(self: *DataStore, address: []const u8, type_key: []const u8, value: Value) !void {
        var entry = try self.globals.getOrPut(address);
        if (!entry.found_existing) {
            const addr_copy = try self.allocator.dupe(u8, address);
            errdefer self.allocator.free(addr_copy);
            entry.key_ptr.* = addr_copy;
            entry.value_ptr.* = std.StringHashMap(Value).init(self.allocator);
        }
        if (entry.value_ptr.contains(type_key)) {
            const val_ptr = entry.value_ptr.getPtr(type_key).?;
            val_ptr.deinit(self.allocator);
            val_ptr.* = value;
        } else {
            const type_copy = try self.allocator.dupe(u8, type_key);
            errdefer self.allocator.free(type_copy);
            try entry.value_ptr.put(type_copy, value);
        }
    }

    pub fn takeGlobal(self: *DataStore, address: []const u8, type_key: []const u8) !?Value {
        try self.logChange(address, type_key);
        return self.takeGlobalInternal(address, type_key);
    }

    fn takeGlobalInternal(self: *DataStore, address: []const u8, type_key: []const u8) ?Value {
        const addr_map = self.globals.getPtr(address) orelse return null;
        const kv = addr_map.fetchRemove(type_key) orelse return null;
        self.allocator.free(kv.key);
        return kv.value;
    }

    pub fn exists(self: DataStore, address: []const u8, type_key: []const u8) bool {
        const addr_map = self.globals.get(address) orelse return false;
        return addr_map.contains(type_key);
    }

    pub fn removeGlobal(self: *DataStore, address: []const u8, type_key: []const u8) bool {
        self.logChange(address, type_key) catch {};
        return self.removeGlobalInternal(address, type_key);
    }

    fn removeGlobalInternal(self: *DataStore, address: []const u8, type_key: []const u8) bool {
        const addr_map = self.globals.getPtr(address) orelse return false;
        const kv = addr_map.fetchRemove(type_key) orelse return false;
        var val = kv.value;
        val.deinit(self.allocator);
        self.allocator.free(kv.key);
        return true;
    }
};

// ==================== Tests ====================

test "DataStore basic" {
    var store = DataStore.init(std.testing.allocator);
    defer store.deinit();

    try store.setGlobal("0x1", "Coin", values.Value.makeU64(100));
    const val = (try store.getGlobal("0x1", "Coin")).?;
    try std.testing.expectEqual(@as(u64, 100), val.impl.U64);
    try std.testing.expect(store.exists("0x1", "Coin"));
}

test "DataStore transaction rollback" {
    const allocator = std.testing.allocator;
    var store = DataStore.init(allocator);
    defer store.deinit();

    // Setup initial state
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(100));

    // Begin transaction
    try store.beginTransaction();

    // Modify within transaction
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(200));
    try store.setGlobal("0x1", "NewCoin", values.Value.makeU64(300));

    // Verify modified state
    const modified = (try store.getGlobal("0x1", "Coin")).?;
    try std.testing.expectEqual(@as(u64, 200), modified.impl.U64);
    try std.testing.expect(store.exists("0x1", "NewCoin"));

    // Rollback
    try store.rollbackTransaction();

    // Verify original state restored
    const restored = (try store.getGlobal("0x1", "Coin")).?;
    try std.testing.expectEqual(@as(u64, 100), restored.impl.U64);
    try std.testing.expect(!store.exists("0x1", "NewCoin"));
}

test "DataStore transaction commit" {
    const allocator = std.testing.allocator;
    var store = DataStore.init(allocator);
    defer store.deinit();

    try store.beginTransaction();
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(100));
    store.commitTransaction();

    const val = (try store.getGlobal("0x1", "Coin")).?;
    try std.testing.expectEqual(@as(u64, 100), val.impl.U64);
}
