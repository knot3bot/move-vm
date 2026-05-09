const std = @import("std");
const vm = @import("vm/mod.zig");
const bytecode = vm.bytecode;
const Instruction = bytecode.Instruction;
const Function = vm.frame.Function;
const Interpreter = vm.interpreter.Interpreter;
const Gas = @import("gas/gas.zig").Gas;
const Value = vm.values.Value;
const DataStore = @import("storage/storage.zig").DataStore;

pub fn main() !void {
    std.debug.print("Move VM (Zig 0.16.0) - Core Implementation\n", .{});
    std.debug.print("=========================================\n\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Demo 1: Simple arithmetic (10 + 32 = 42)
    std.debug.print("Demo 1: Simple Arithmetic (10 + 32)\n", .{});
    std.debug.print("------------------------------------\n", .{});

    var add_func = Function.init(allocator, "add");
    defer add_func.deinit(allocator);
    add_func.param_count = 2;
    add_func.local_count = 3;
    add_func.return_count = 1;

    try add_func.code.push(allocator, Instruction{ .copy_loc = 0 });
    try add_func.code.push(allocator, Instruction{ .copy_loc = 1 });
    try add_func.code.push(allocator, Instruction{ .add = {} });
    try add_func.code.push(allocator, Instruction{ .st_loc = 2 });
    try add_func.code.push(allocator, Instruction{ .copy_loc = 2 });
    try add_func.code.push(allocator, Instruction{ .ret = .{ .num_vals = 1 } });

    var gas1 = Gas.init(10000);
    var interp1 = Interpreter.init(allocator);
    defer interp1.deinit(allocator);

    const args1 = [_]Value{ Value.makeU64(10), Value.makeU64(32) };
    const result1 = try interp1.executeFunction(allocator, &add_func, &.{}, &.{}, &args1, &gas1);
    defer allocator.free(result1.values);

    std.debug.print("Result: {} (expected 42)\n", .{result1.values[0].impl.U64});
    std.debug.print("Gas used: {}\n\n", .{result1.gas_used});

    // Demo 2: Fibonacci(10) = 55
    std.debug.print("Demo 2: Fibonacci(10)\n", .{});
    std.debug.print("---------------------\n", .{});

    var fib_func = Function.init(allocator, "fib");
    defer fib_func.deinit(allocator);
    fib_func.param_count = 1;
    fib_func.local_count = 5;
    fib_func.return_count = 1;

    // locals: 0=n, 1=a, 2=b, 3=i, 4=temp
    try fib_func.code.push(allocator, Instruction{ .ld_u64 = 0 });
    try fib_func.code.push(allocator, Instruction{ .st_loc = 1 });
    try fib_func.code.push(allocator, Instruction{ .ld_u64 = 1 });
    try fib_func.code.push(allocator, Instruction{ .st_loc = 2 });
    try fib_func.code.push(allocator, Instruction{ .ld_u64 = 0 });
    try fib_func.code.push(allocator, Instruction{ .st_loc = 3 });

    // loop start (pc=6)
    try fib_func.code.push(allocator, Instruction{ .copy_loc = 3 });
    try fib_func.code.push(allocator, Instruction{ .copy_loc = 0 });
    try fib_func.code.push(allocator, Instruction{ .lt = {} });
    try fib_func.code.push(allocator, Instruction{ .br_false = 23 });

    try fib_func.code.push(allocator, Instruction{ .copy_loc = 1 });
    try fib_func.code.push(allocator, Instruction{ .copy_loc = 2 });
    try fib_func.code.push(allocator, Instruction{ .add = {} });
    try fib_func.code.push(allocator, Instruction{ .st_loc = 4 });

    try fib_func.code.push(allocator, Instruction{ .move_loc = 2 });
    try fib_func.code.push(allocator, Instruction{ .st_loc = 1 });

    try fib_func.code.push(allocator, Instruction{ .move_loc = 4 });
    try fib_func.code.push(allocator, Instruction{ .st_loc = 2 });

    try fib_func.code.push(allocator, Instruction{ .copy_loc = 3 });
    try fib_func.code.push(allocator, Instruction{ .ld_u64 = 1 });
    try fib_func.code.push(allocator, Instruction{ .add = {} });
    try fib_func.code.push(allocator, Instruction{ .st_loc = 3 });

    try fib_func.code.push(allocator, Instruction{ .branch = 6 });

    try fib_func.code.push(allocator, Instruction{ .copy_loc = 1 });
    try fib_func.code.push(allocator, Instruction{ .ret = .{ .num_vals = 1 } });

    var gas2 = Gas.init(100000);
    var interp2 = Interpreter.init(allocator);
    defer interp2.deinit(allocator);

    const args2 = [_]Value{Value.makeU64(10)};
    const result2 = try interp2.executeFunction(allocator, &fib_func, &.{}, &.{}, &args2, &gas2);
    defer allocator.free(result2.values);

    std.debug.print("Result: {} (expected 55)\n", .{result2.values[0].impl.U64});
    std.debug.print("Gas used: {}\n\n", .{result2.gas_used});

    // Demo 3: Storage
    std.debug.print("Demo 3: Storage Operations\n", .{});
    std.debug.print("-------------------------\n", .{});

    var store = DataStore.init(allocator);
    defer store.deinit();

    try store.setGlobal("0x1", "Coin", Value.makeU64(1000));
    if (try store.getGlobal("0x1", "Coin")) |val| {
        defer val.deinit(allocator);
        std.debug.print("Stored Coin value: {}\n", .{val.impl.U64});
    }
    std.debug.print("Exists check: {}\n\n", .{store.exists("0x1", "Coin")});

    std.debug.print("=========================================\n", .{});
    std.debug.print("All demos completed successfully!\n", .{});
}
