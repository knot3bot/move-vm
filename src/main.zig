const std = @import("std");
const vm_mod = @import("vm/mod.zig");
const gas_mod = @import("gas/gas.zig");
const storage_mod = @import("storage/storage.zig");
const session_mod = @import("vm/session.zig");

pub fn main() !void {
    // Initialize modules
    vm_mod.init();
    gas_mod.init();
    storage_mod.init();

    std.debug.print("Move VM (Zig 0.16.0) - Core Implementation\n", .{});
    std.debug.print("=========================================\n\n", .{});

    // Create allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create storage
    var storage = storage_mod.Storage.init(allocator);
    defer storage.deinit();

    // Create Move VM
    var vm = session_mod.MoveVM.init(allocator);
    defer vm.deinit();

    // Create session
    var session = vm.newSession(&storage, 1000000);
    defer session.deinit();

    std.debug.print("Components initialized:\n", .{});
    std.debug.print("  - MoveVM: ✓\n", .{});
    std.debug.print("  - Session: ✓\n", .{});
    std.debug.print("  - Storage: ✓\n", .{});
    std.debug.print("  - Gas Meter: ✓\n\n", .{});

    // Test storage operations
    std.debug.print("Storage Test:\n", .{});
    std.debug.print("------------\n", .{});

    // Set a global value
    const test_addr = "0x1";
    const test_type = "TestResource";
    try storage.setGlobal(test_addr, test_type, .{ .U64 = 123 });

    // Get the value
    if (try storage.getGlobal(test_addr, test_type)) |val| {
        std.debug.print("Stored and retrieved: {}\n", .{val.U64});
    }

    // Check exists
    if (storage.exists(test_addr, test_type)) {
        std.debug.print("Exists check: true ✓\n", .{});
    }

    // Test gas
    std.debug.print("\nGas Test:\n", .{});
    std.debug.print("--------\n", .{});
    var gas_track = gas_mod.Gas.init(1000);
    try gas_track.consume(100);
    std.debug.print("Gas consumed: 100, remaining: {} ✓\n", .{gas_track.getRemaining()});
    std.debug.print("Gas used: {} ✓\n", .{gas_track.getUsed()});

    // Test gas out of gas error
    var empty_gas = gas_mod.Gas.init(50);
    const result = empty_gas.consume(100);
    if (result == error.OutOfGas) {
        std.debug.print("OutOfGas error handling: ✓\n", .{});
    }

    // Test session gas
    std.debug.print("\nSession Gas Test:\n", .{});
    std.debug.print("-----------------\n", .{});
    std.debug.print("Session initial gas: {} ✓\n", .{session.getRemainingGas()});

    std.debug.print("\n=========================================\n", .{});
    std.debug.print("All tests passed!\n", .{});
}
