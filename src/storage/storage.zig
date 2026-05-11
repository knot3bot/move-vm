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
    change_logs: std.ArrayList(*std.ArrayList(ChangeEntry)),

    pub fn init(allocator: std.mem.Allocator) DataStore {
        return .{
            .allocator = allocator,
            .globals = std.StringHashMap(std.StringHashMap(Value)).init(allocator),
            .modules = std.StringHashMap([]const u8).init(allocator),
            .change_logs = std.ArrayList(*std.ArrayList(ChangeEntry)).empty,
        };
    }

    pub fn deinit(self: *DataStore) void {
        // Rollback any active transactions before destroying storage
        while (self.change_logs.items.len > 0) {
            _ = self.rollbackTransaction() catch {};
        }
        self.change_logs.deinit(self.allocator);
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
        var mod_it = self.modules.iterator();
        while (mod_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.modules.deinit();
    }

    /// Begin a transaction: push a new change log onto the stack.
    pub fn beginTransaction(self: *DataStore) !void {
        const log = try self.allocator.create(std.ArrayList(ChangeEntry));
        log.* = std.ArrayList(ChangeEntry).empty;
        errdefer self.allocator.destroy(log);
        try self.change_logs.append(self.allocator, log);
    }

    /// Commit a transaction: pop the current change log.
    /// Nested transactions merge their log into the parent.
    /// The outermost commit discards the log entirely.
    pub fn commitTransaction(self: *DataStore) !void {
        if (self.change_logs.items.len == 0) return;
        const log = self.change_logs.pop().?;
        if (self.change_logs.items.len > 0) {
            // Merge into parent transaction
            const parent = self.change_logs.items[self.change_logs.items.len - 1];
            parent.appendSlice(self.allocator, log.items) catch |err| {
                // Recovery: push log back so caller can retry or rollback
                self.change_logs.append(self.allocator, log) catch {};
                return err;
            };
            // Entries are now owned by parent; free only the list structure
            log.deinit(self.allocator);
            self.allocator.destroy(log);
        } else {
            // Outermost commit: discard old values
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
        }
    }

    /// Rollback a transaction: restore all old values and pop the log.
    pub fn rollbackTransaction(self: *DataStore) !void {
        if (self.change_logs.items.len == 0) return;
        const log = self.change_logs.pop().?;
        // Apply changes in reverse order
        var i: usize = log.items.len;
        while (i > 0) {
            i -= 1;
            const entry = log.items[i];
            if (entry.old_value) |old| {
                self.setGlobalInternal(entry.address, entry.type_key, old) catch |err| {
                    var val = old;
                    val.deinit(self.allocator);
                    return err;
                };
            } else {
                _ = self.removeGlobalInternal(entry.address, entry.type_key) catch |err| {
                    return err;
                };
            }
            self.allocator.free(entry.address);
            self.allocator.free(entry.type_key);
        }
        log.deinit(self.allocator);
        self.allocator.destroy(log);
    }

    pub fn logChange(self: *DataStore, address: []const u8, type_key: []const u8) !void {
        if (self.change_logs.items.len == 0) return;
        const log = self.change_logs.items[self.change_logs.items.len - 1];
        // If this key is already logged in the current transaction, skip the redundant deep-copy.
        for (log.items) |entry| {
            if (std.mem.eql(u8, entry.address, address) and std.mem.eql(u8, entry.type_key, type_key)) {
                return;
            }
        }
        const addr_copy = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(addr_copy);
        const type_copy = try self.allocator.dupe(u8, type_key);
        errdefer self.allocator.free(type_copy);
        var old_copy: ?values.Value = null;
        if (try self.getGlobal(address, type_key)) |v| {
            old_copy = v;
        }
        errdefer {
            if (old_copy) |*v| v.deinit(self.allocator);
        }
        try log.append(self.allocator, .{
            .address = addr_copy,
            .type_key = type_copy,
            .old_value = old_copy,
        });
    }

    /// Get a pointer to the stored value (borrowed reference — do NOT deinit).
    pub fn getGlobalPtr(self: *DataStore, address: []const u8, type_key: []const u8) !?*const Value {
        const addr_map = self.globals.getPtr(address) orelse return null;
        return addr_map.getPtr(type_key);
    }

    /// Get a deep copy of the stored value (caller must deinit).
    pub fn getGlobal(self: *DataStore, address: []const u8, type_key: []const u8) !?Value {
        const ptr = try self.getGlobalPtr(address, type_key) orelse return null;
        return try ptr.copy_value(self.allocator);
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
            if (val_ptr.impl == .Container and val_ptr.impl.Container.ref_count > 0) {
                return error.BorrowedResource;
            }
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
        return try self.takeGlobalInternal(address, type_key);
    }

    fn takeGlobalInternal(self: *DataStore, address: []const u8, type_key: []const u8) !?Value {
        const addr_map_ptr = self.globals.getPtr(address) orelse return null;
        if (addr_map_ptr.getPtr(type_key)) |val_ptr| {
            if (val_ptr.impl == .Container and val_ptr.impl.Container.ref_count > 0) {
                return error.BorrowedResource;
            }
        }
        const kv = addr_map_ptr.fetchRemove(type_key) orelse return null;
        self.allocator.free(kv.key);
        if (addr_map_ptr.count() == 0) {
            if (self.globals.fetchRemove(address)) |removed| {
                self.allocator.free(removed.key);
                var inner_map = removed.value;
                inner_map.deinit();
            }
        }
        return kv.value;
    }

    pub fn exists(self: DataStore, address: []const u8, type_key: []const u8) bool {
        const addr_map = self.globals.get(address) orelse return false;
        return addr_map.contains(type_key);
    }

    pub fn removeGlobal(self: *DataStore, address: []const u8, type_key: []const u8) !bool {
        try self.logChange(address, type_key);
        return self.removeGlobalInternal(address, type_key);
    }

    fn removeGlobalInternal(self: *DataStore, address: []const u8, type_key: []const u8) !bool {
        const addr_map_ptr = self.globals.getPtr(address) orelse return false;
        if (addr_map_ptr.getPtr(type_key)) |val_ptr| {
            if (val_ptr.impl == .Container and val_ptr.impl.Container.ref_count > 0) {
                return error.BorrowedResource;
            }
        }
        const kv = addr_map_ptr.fetchRemove(type_key) orelse return false;
        var val = kv.value;
        val.deinit(self.allocator);
        self.allocator.free(kv.key);
        if (addr_map_ptr.count() == 0) {
            if (self.globals.fetchRemove(address)) |removed| {
                self.allocator.free(removed.key);
                var inner_map = removed.value;
                inner_map.deinit();
            }
        }
        return true;
    }
};

// ==================== Tests ====================

test "DataStore basic" {
    var store = DataStore.init(std.testing.allocator);
    defer store.deinit();

    try store.setGlobal("0x1", "Coin", values.Value.makeU64(100));
    var val = (try store.getGlobal("0x1", "Coin")).?;
    defer val.deinit(std.testing.allocator);
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
    var modified = (try store.getGlobal("0x1", "Coin")).?;
    defer modified.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 200), modified.impl.U64);
    try std.testing.expect(store.exists("0x1", "NewCoin"));

    // Rollback
    try store.rollbackTransaction();

    // Verify original state restored
    var restored = (try store.getGlobal("0x1", "Coin")).?;
    defer restored.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 100), restored.impl.U64);
    try std.testing.expect(!store.exists("0x1", "NewCoin"));
}

test "DataStore transaction commit" {
    const allocator = std.testing.allocator;
    var store = DataStore.init(allocator);
    defer store.deinit();

    try store.beginTransaction();
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(100));
    try store.commitTransaction();

    var val = (try store.getGlobal("0x1", "Coin")).?;
    defer val.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 100), val.impl.U64);
}

test "DataStore nested transaction commit" {
    const allocator = std.testing.allocator;
    var store = DataStore.init(allocator);
    defer store.deinit();

    try store.beginTransaction();
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(100));

    // Begin nested transaction
    try store.beginTransaction();
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(200));
    try store.setGlobal("0x1", "NewCoin", values.Value.makeU64(300));

    // Commit inner transaction — changes should persist (merged to outer)
    try store.commitTransaction();

    // Outer transaction still active
    var val = (try store.getGlobal("0x1", "Coin")).?;
    defer val.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 200), val.impl.U64);
    try std.testing.expect(store.exists("0x1", "NewCoin"));

    // Commit outer transaction
    try store.commitTransaction();

    // Verify changes are permanent
    var final = (try store.getGlobal("0x1", "Coin")).?;
    defer final.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 200), final.impl.U64);
    try std.testing.expect(store.exists("0x1", "NewCoin"));
}

test "DataStore nested transaction rollback inner" {
    const allocator = std.testing.allocator;
    var store = DataStore.init(allocator);
    defer store.deinit();

    try store.beginTransaction();
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(100));

    // Begin nested transaction
    try store.beginTransaction();
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(200));
    try store.setGlobal("0x1", "NewCoin", values.Value.makeU64(300));

    // Rollback inner transaction
    try store.rollbackTransaction();

    // Outer transaction still active — should see outer state
    var val = (try store.getGlobal("0x1", "Coin")).?;
    defer val.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 100), val.impl.U64);
    try std.testing.expect(!store.exists("0x1", "NewCoin"));

    // Commit outer transaction
    try store.commitTransaction();

    // Verify outer state is permanent
    var final = (try store.getGlobal("0x1", "Coin")).?;
    defer final.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 100), final.impl.U64);
    try std.testing.expect(!store.exists("0x1", "NewCoin"));
}

test "DataStore nested transaction rollback outer" {
    const allocator = std.testing.allocator;
    var store = DataStore.init(allocator);
    defer store.deinit();

    try store.beginTransaction();
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(100));

    // Begin nested transaction
    try store.beginTransaction();
    try store.setGlobal("0x1", "Coin", values.Value.makeU64(200));

    // Commit inner transaction (merged to outer)
    try store.commitTransaction();

    // Rollback outer transaction
    try store.rollbackTransaction();

    // Everything should be reverted
    try std.testing.expect(!store.exists("0x1", "Coin"));
}

test "DataStore rollback restores global after IndexedRef write_ref" {
    const allocator = std.testing.allocator;
    var store = DataStore.init(allocator);
    defer store.deinit();

    // Create a struct container with two U64 fields: [10, 20]
    var container = try values.Container.newWithAbilities(allocator, .Struct, .{ .can_copy = true, .can_drop = true, .can_store = true, .is_key = true });
    try container.data.append(allocator, .{ .U64 = 10 });
    try container.data.append(allocator, .{ .U64 = 20 });
    const global_val = values.Value.init(.{ .Container = container });

    try store.setGlobal("0x1", "MyStruct", global_val);

    // Begin transaction
    try store.beginTransaction();

    // Get mutable pointer to the stored value
    const addr_map = store.globals.getPtr("0x1").?;
    const val_ptr = addr_map.getPtr("MyStruct").?;
    const global_container = val_ptr.impl.Container;

    // Log change before modifying (simulating interpreter write_ref behavior)
    try store.logChange("0x1", "MyStruct");

    // Create IndexedRef to field 0
    global_container.addRef();
    const addr_copy = try allocator.dupe(u8, "0x1");
    errdefer allocator.free(addr_copy);
    const tk_copy = try allocator.dupe(u8, "MyStruct");
    errdefer allocator.free(tk_copy);
    var idx_val = values.Value.init(.{ .IndexedRef = .{
        .container_ref = .{
            .container = global_container,
            .is_mutable = true,
            .is_global = true,
            .global_address = addr_copy,
            .global_type_key = tk_copy,
        },
        .idx = 0,
    } });

    // Write new value to field 0
    var new_val = values.Value.makeU64(99);
    defer new_val.deinit(allocator);
    try idx_val.write_ref(allocator, new_val);

    // Verify modification
    try std.testing.expectEqual(@as(u64, 99), global_container.data.items[0].U64);
    try std.testing.expectEqual(@as(u64, 20), global_container.data.items[1].U64);

    // Drop the reference before rollback so setGlobalInternal can replace the container
    idx_val.deinit(allocator);
    allocator.free(addr_copy);
    allocator.free(tk_copy);

    // Rollback
    try store.rollbackTransaction();

    // Verify restoration
    var restored = (try store.getGlobal("0x1", "MyStruct")).?;
    defer restored.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 10), restored.impl.Container.data.items[0].U64);
    try std.testing.expectEqual(@as(u64, 20), restored.impl.Container.data.items[1].U64);
}
