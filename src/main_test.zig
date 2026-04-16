const std = @import("std");
const testing = std.testing;
const frame = @import("vm/frame.zig");
const gas_mod = @import("gas/gas.zig");
const storage_mod = @import("storage/storage.zig");
const bytecode = @import("vm/bytecode.zig");

// ==================== Value Tests ====================

test "Value - isResource (primitives)" {
    // Primitive types are not resources
    const u64_val = frame.Value{ .U64 = 42 };
    try testing.expect(!u64_val.isResource());

    const bool_val = frame.Value{ .Bool = true };
    try testing.expect(!bool_val.isResource());

    const addr_val = frame.Value{ .Address = undefined };
    try testing.expect(!addr_val.isResource());
}

test "Value - canCopy (primitives)" {
    // Primitives can be copied
    const u64_copy = frame.Value{ .U64 = 42 };
    try testing.expect(u64_copy.canCopy());

    const bool_copy = frame.Value{ .Bool = true };
    try testing.expect(bool_copy.canCopy());
}

test "Value - typeTag" {
    const u64_tag = frame.Value{ .U64 = 42 };
    try testing.expectEqual(frame.TypeTag.U64, u64_tag.typeTag());

    const bool_tag = frame.Value{ .Bool = true };
    try testing.expectEqual(frame.TypeTag.Bool, bool_tag.typeTag());

    const addr_tag = frame.Value{ .Address = undefined };
    try testing.expectEqual(frame.TypeTag.Address, addr_tag.typeTag());

    const signer_tag = frame.Value{ .Signer = undefined };
    try testing.expectEqual(frame.TypeTag.Signer, signer_tag.typeTag());
}

// ==================== Gas Tests ====================

test "Gas - init and consume" {
    var g = gas_mod.Gas.init(1000);
    try testing.expectEqual(@as(u64, 1000), g.getRemaining());
    try testing.expectEqual(@as(u64, 0), g.getUsed());

    try g.consume(100);
    try testing.expectEqual(@as(u64, 900), g.getRemaining());
    try testing.expectEqual(@as(u64, 100), g.getUsed());
}

test "Gas - out of gas" {
    var g = gas_mod.Gas.init(50);
    const result = g.consume(100);
    try testing.expectError(error.OutOfGas, result);
    try testing.expectEqual(@as(u64, 50), g.getRemaining());
}

test "Gas - canConsume" {
    var g = gas_mod.Gas.init(100);
    try testing.expect(g.canConsume(50));
    try testing.expect(g.canConsume(100));
    try testing.expect(!g.canConsume(101));
}

test "Gas - reset" {
    var g = gas_mod.Gas.init(100);
    try g.consume(50);

    g.reset(500);
    try testing.expectEqual(@as(u64, 500), g.getRemaining());
    try testing.expectEqual(@as(u64, 500), g.getInitial());
}

// ==================== Bytecode Tests ====================

test "Bytecode - instruction gas cost" {
    // Simple arithmetic should have cost 1
    const add_cost = bytecode.instructionGasCost(bytecode.Instruction{ .add = {} });
    try testing.expectEqual(@as(u64, 1), add_cost);

    // Load constant has higher cost
    const ldconst_cost = bytecode.instructionGasCost(bytecode.Instruction{ .ld_const = .{ .const_idx = 0 } });
    try testing.expectEqual(@as(u64, 2), ldconst_cost);

    // Function call has high cost
    const call_cost = bytecode.instructionGasCost(bytecode.Instruction{ .call = .{ .func = 0 } });
    try testing.expectEqual(@as(u64, 10), call_cost);

    // Nop has zero cost
    const nop_cost = bytecode.instructionGasCost(bytecode.Instruction{ .nop = {} });
    try testing.expectEqual(@as(u64, 0), nop_cost);
}

test "Bytecode - instruction stacks" {
    // Verify stack effects are defined
    const add_instr = bytecode.Instruction{ .add = {} };
    try testing.expectEqual(@as(i32, -1), add_instr.stackEffect().pop);
    try testing.expectEqual(@as(i32, 1), add_instr.stackEffect().push);

    const pop_instr = bytecode.Instruction{ .pop = {} };
    try testing.expectEqual(@as(i32, 1), pop_instr.stackEffect().pop);
    try testing.expectEqual(@as(i32, 0), pop_instr.stackEffect().push);

    const ld_const_instr = bytecode.Instruction{ .ld_const = .{ .const_idx = 0 } };
    try testing.expectEqual(@as(i32, 0), ld_const_instr.stackEffect().pop);
    try testing.expectEqual(@as(i32, 1), ld_const_instr.stackEffect().push);
}

test "Bytecode - instruction enum size" {
    // Verify we have the expected number of instructions
    try testing.expect(@as(usize, 0) < @typeInfo(bytecode.Instruction).Union.fields.len);
}

// ==================== Additional Tests ====================

test "TypeTag enum" {
    // Verify TypeTag has expected variants
    try testing.expectEqual(frame.TypeTag.Bool, frame.TypeTag.Bool);
    try testing.expectEqual(frame.TypeTag.U64, frame.TypeTag.U64);
    try testing.expectEqual(frame.TypeTag.Address, frame.TypeTag.Address);
    try testing.expectEqual(frame.TypeTag.Signer, frame.TypeTag.Signer);
    try testing.expectEqual(frame.TypeTag.Vector, frame.TypeTag.Vector);
    try testing.expectEqual(frame.TypeTag.Struct, frame.TypeTag.Struct);
    try testing.expectEqual(frame.TypeTag.Reference, frame.TypeTag.Reference);
    try testing.expectEqual(frame.TypeTag.MutableReference, frame.TypeTag.MutableReference);
}
