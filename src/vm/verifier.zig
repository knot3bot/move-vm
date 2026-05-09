const std = @import("std");
const bytecode = @import("bytecode.zig");
const Instruction = bytecode.Instruction;
const frame = @import("frame.zig");
const Function = frame.Function;
const types = @import("types.zig");
const TypeTag = types.TypeTag;
const module_mod = @import("module.zig");

pub const VerifierError = error{
    StackUnderflow,
    StackOverflow,
    InvalidLocalIndex,
    InvalidBranchTarget,
    InvalidFieldIndex,
    InvalidFunctionIndex,
    InvalidInstruction,
    MissingReturn,
    ExtraValueOnStack,
    TypeMismatch,
    OutOfMemory,
};

const StackEffect = struct {
    pop: i32,
    push: i32,
};

fn resolveGenericStructFieldCount(func: *const Function, type_inst: u16) VerifierError!u16 {
    if (type_inst >= func.struct_instantiations.len) return error.InvalidInstruction;
    const inst = func.struct_instantiations[type_inst];
    if (inst.def >= func.struct_defs.len) return error.InvalidInstruction;
    return @intCast(func.struct_defs[inst.def].fields.items.len);
}

fn instructionStackEffect(inst: Instruction, func: *const Function, functions: []const Function, instantiated_functions: []const Function) VerifierError!StackEffect {
    return switch (inst) {
        .pop => .{ .pop = 1, .push = 0 },
        .ret => .{ .pop = func.return_count, .push = 0 },
        .ld_loc, .copy_loc, .move_loc => .{ .pop = 0, .push = 1 },
        .st_loc => .{ .pop = 1, .push = 0 },
        .ld_u8, .ld_u16, .ld_u32, .ld_u64, .ld_u128, .ld_u256,
        .ld_true, .ld_false => .{ .pop = 0, .push = 1 },
        .ld_const => .{ .pop = 0, .push = 1 },
        .ld_addr => .{ .pop = 0, .push = 1 },
        .add, .sub, .mul, .div, .mod,
        .bit_and, .bit_or, .bit_xor,
        .shl, .shr => .{ .pop = 2, .push = 1 },
        .and_, .or_ => .{ .pop = 2, .push = 1 },
        .not => .{ .pop = 1, .push = 1 },
        .lt, .gt, .le, .ge, .eq, .neq => .{ .pop = 2, .push = 1 },
        .br_true, .br_false => .{ .pop = 1, .push = 0 },
        .branch => .{ .pop = 0, .push = 0 },
        .call => |call| {
            if (func.function_handles.len > 0) {
                if (call.func >= func.function_handles.len) return error.InvalidFunctionIndex;
                const handle = func.function_handles[call.func];
                const resolved = if (call.func < func.resolved_handles.len) func.resolved_handles[call.func] else null;
                const pop: i32 = if (handle.param_types.len > 0)
                    @intCast(handle.param_types.len)
                else if (resolved) |r|
                    @intCast(r.param_count)
                else if (call.func < functions.len)
                    @intCast(functions[call.func].param_count)
                else
                    0;
                const push: i32 = if (handle.return_types.len > 0)
                    @intCast(handle.return_types.len)
                else if (resolved) |r|
                    @intCast(r.return_count)
                else if (call.func < functions.len)
                    @intCast(functions[call.func].return_count)
                else
                    0;
                return .{ .pop = pop, .push = push };
            }
            if (call.func >= functions.len) return error.InvalidFunctionIndex;
            const callee = &functions[call.func];
            return .{ .pop = callee.param_count, .push = callee.return_count };
        },
        .call_generic => |call| {
            if (call.func_instantiation >= instantiated_functions.len) return error.InvalidFunctionIndex;
            const callee = &instantiated_functions[call.func_instantiation];
            return .{ .pop = callee.param_count, .push = callee.return_count };
        },
        .pack => |def_idx| {
            if (def_idx >= func.struct_defs.len) return error.InvalidFieldIndex;
            const n = func.struct_defs[def_idx].fields.items.len;
            return .{ .pop = @intCast(n), .push = 1 };
        },
        .unpack => |n| .{ .pop = 1, .push = @intCast(n) },
        .pack_generic => |type_inst| .{ .pop = try resolveGenericStructFieldCount(func, type_inst), .push = 1 },
        .unpack_generic => |type_inst| .{ .pop = 1, .push = try resolveGenericStructFieldCount(func, type_inst) },
        .mut_borrow_loc, .imm_borrow_loc => .{ .pop = 0, .push = 1 },
        .mut_borrow_field, .imm_borrow_field,
        .mut_borrow_field_generic, .imm_borrow_field_generic => .{ .pop = 1, .push = 1 },
        .read_ref => .{ .pop = 1, .push = 1 },
        .write_ref => .{ .pop = 2, .push = 0 },
        .freeze_ref => .{ .pop = 1, .push = 1 },
        .cast_u8, .cast_u16, .cast_u32, .cast_u64, .cast_u128, .cast_u256 => .{ .pop = 1, .push = 1 },
        .abort => .{ .pop = 1, .push = 0 },
        .nop => .{ .pop = 0, .push = 0 },
        .vec_pack => |vp| {
            if (vp.num > std.math.maxInt(i32)) return error.InvalidInstruction;
            return .{ .pop = @intCast(vp.num), .push = 1 };
        },
        .vec_len => .{ .pop = 1, .push = 1 },
        .vec_imm_borrow, .vec_mut_borrow => .{ .pop = 2, .push = 1 },
        .vec_push_back => .{ .pop = 2, .push = 0 },
        .vec_pop_back => .{ .pop = 1, .push = 1 },
        .vec_unpack => |vu| {
            if (vu.num > std.math.maxInt(i32)) return error.InvalidInstruction;
            return .{ .pop = 1, .push = @intCast(vu.num) };
        },
        .vec_swap => .{ .pop = 3, .push = 0 },
        .move_to => .{ .pop = 2, .push = 0 },
        .move_from => .{ .pop = 1, .push = 1 },
        .exists => .{ .pop = 1, .push = 1 },
        .move_to_generic => .{ .pop = 2, .push = 0 },
        .move_from_generic => .{ .pop = 1, .push = 1 },
        .exists_generic => .{ .pop = 1, .push = 1 },
        .mut_borrow_global, .imm_borrow_global,
        .mut_borrow_global_generic, .imm_borrow_global_generic => .{ .pop = 1, .push = 1 },
    };
}

fn isIntegerTag(tag: ?TypeTag) bool {
    const t = tag orelse return false;
    return switch (t) {
        .U8, .U16, .U32, .U64, .U128, .U256 => true,
        else => false,
    };
}

fn typeToTag(ty: types.Type) ?TypeTag {
    return switch (ty) {
        .Bool => .Bool,
        .U8 => .U8,
        .U16 => .U16,
        .U32 => .U32,
        .U64 => .U64,
        .U128 => .U128,
        .U256 => .U256,
        .Address => .Address,
        .Signer => .Signer,
        .Vector => .Vector,
        .Struct => .Struct,
        .Reference => .Reference,
        .MutableReference => .MutableReference,
        .TypeParameter => null,
    };
}

fn typeSignatureToTag(ts: module_mod.TypeSignature) ?TypeTag {
    return switch (ts) {
        .Bool => .Bool,
        .U8 => .U8,
        .U16 => .U16,
        .U32 => .U32,
        .U64 => .U64,
        .U128 => .U128,
        .U256 => .U256,
        .Address => .Address,
        .Signer => .Signer,
        .Vector => .Vector,
        .Struct => .Struct,
        .Reference => .Reference,
        .MutableReference => .MutableReference,
        .TypeParameter => null,
    };
}

const TypeContext = struct {
    stack: std.ArrayList(?TypeTag),
    locals: []?TypeTag,

    pub fn init(allocator: std.mem.Allocator, local_count: usize) !TypeContext {
        const locals = try allocator.alloc(?TypeTag, local_count);
        @memset(locals, null);
        return .{
            .stack = std.ArrayList(?TypeTag).empty,
            .locals = locals,
        };
    }

    pub fn deinit(self: *TypeContext, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
        allocator.free(self.locals);
    }

    pub fn clone(self: TypeContext, allocator: std.mem.Allocator) !TypeContext {
        var copy = try init(allocator, self.locals.len);
        @memcpy(copy.locals, self.locals);
        try copy.stack.appendSlice(allocator, self.stack.items);
        return copy;
    }

    pub fn push(self: *TypeContext, allocator: std.mem.Allocator, tag: ?TypeTag) !void {
        try self.stack.append(allocator, tag);
    }

    pub fn pop(self: *TypeContext) !?TypeTag {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        return self.stack.pop().?;
    }

    pub fn peek(self: TypeContext) !?TypeTag {
        if (self.stack.items.len == 0) return error.StackUnderflow;
        return self.stack.items[self.stack.items.len - 1];
    }

    pub fn depth(self: TypeContext) usize {
        return self.stack.items.len;
    }
};

fn mergeTypeContext(dst: *TypeContext, src: TypeContext) bool {
    if (dst.stack.items.len != src.stack.items.len) return false;
    for (dst.stack.items, src.stack.items) |*a, b| {
        if (a.* == null) {
            a.* = b;
        } else if (b != null and a.* != b) {
            return false;
        }
    }
    for (dst.locals, src.locals) |*a, b| {
        if (a.* == null) {
            a.* = b;
        } else if (b != null and a.* != b) {
            return false;
        }
    }
    return true;
}

fn applyTypeEffect(
    ctx: *TypeContext,
    allocator: std.mem.Allocator,
    inst: Instruction,
    func: *const Function,
    functions: []const Function,
    instantiated_functions: []const Function,
) VerifierError!void {
    switch (inst) {
        .pop => _ = try ctx.pop(),
        .ret => {
            var i: usize = func.return_count;
            while (i > 0) {
                i -= 1;
                const actual = try ctx.pop();
                if (func.return_types.items.len > i) {
                    const expected = typeToTag(func.return_types.items[i]);
                    if (actual != null and actual != expected) return error.TypeMismatch;
                }
            }
        },
        .ld_loc => |idx| try ctx.push(allocator, ctx.locals[idx]),
        .copy_loc => |idx| try ctx.push(allocator, ctx.locals[idx]),
        .move_loc => |idx| {
            try ctx.push(allocator, ctx.locals[idx]);
            ctx.locals[idx] = null;
        },
        .st_loc => |idx| {
            const ty = try ctx.pop();
            ctx.locals[idx] = ty;
        },
        .ld_u8 => try ctx.push(allocator, .U8),
        .ld_u16 => try ctx.push(allocator, .U16),
        .ld_u32 => try ctx.push(allocator, .U32),
        .ld_u64 => try ctx.push(allocator, .U64),
        .ld_u128 => try ctx.push(allocator, .U128),
        .ld_u256 => try ctx.push(allocator, .U256),
        .ld_true, .ld_false => try ctx.push(allocator, .Bool),
        .ld_const => |lc| {
            if (lc.const_idx >= func.constants.len) return error.InvalidInstruction;
            const tag = typeSignatureToTag(func.constants[lc.const_idx].type_signature);
            try ctx.push(allocator, tag);
        },
        .ld_addr => try ctx.push(allocator, .Address),
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .shl, .shr => {
            const b = try ctx.pop();
            const a = try ctx.pop();
            if (a == null or b == null) {
                try ctx.push(allocator, null);
            } else if (!isIntegerTag(a) or a != b) {
                return error.TypeMismatch;
            } else {
                try ctx.push(allocator, a);
            }
        },
        .and_, .or_ => {
            const b = try ctx.pop();
            const a = try ctx.pop();
            if (a == null or b == null) {
                try ctx.push(allocator, null);
            } else if (a != .Bool or b != .Bool) {
                return error.TypeMismatch;
            } else {
                try ctx.push(allocator, .Bool);
            }
        },
        .not => {
            const a = try ctx.pop();
            if (a == null) {
                try ctx.push(allocator, null);
            } else if (a != .Bool) {
                return error.TypeMismatch;
            } else {
                try ctx.push(allocator, .Bool);
            }
        },
        .lt, .gt, .le, .ge => {
            const b = try ctx.pop();
            const a = try ctx.pop();
            if (a == null or b == null) {
                try ctx.push(allocator, null);
            } else if (!isIntegerTag(a) or a != b) {
                return error.TypeMismatch;
            } else {
                try ctx.push(allocator, .Bool);
            }
        },
        .eq, .neq => {
            _ = try ctx.pop();
            _ = try ctx.pop();
            try ctx.push(allocator, .Bool);
        },
        .br_true, .br_false => {
            const a = try ctx.pop();
            if (a != .Bool) return error.TypeMismatch;
        },
        .branch => {},
        .call => |call| {
            if (func.function_handles.len > 0) {
                if (call.func >= func.function_handles.len) return error.InvalidFunctionIndex;
                const handle = func.function_handles[call.func];
                const resolved = if (call.func < func.resolved_handles.len) func.resolved_handles[call.func] else null;
                const pop_count = if (handle.param_types.len > 0)
                    handle.param_types.len
                else if (resolved) |r|
                    r.param_count
                else if (call.func < functions.len)
                    functions[call.func].param_count
                else
                    0;
                const push_count = if (handle.return_types.len > 0)
                    handle.return_types.len
                else if (resolved) |r|
                    r.return_count
                else if (call.func < functions.len)
                    functions[call.func].return_count
                else
                    0;
                // Type-check arguments when callee is resolved or available in functions array
                var i: usize = pop_count;
                while (i > 0) {
                    i -= 1;
                    const actual = try ctx.pop();
                    if (resolved) |r| {
                        if (r.param_types.items.len > i) {
                            const expected = typeToTag(r.param_types.items[i]);
                            if (actual != null and actual != expected) return error.TypeMismatch;
                        }
                    } else if (call.func < functions.len) {
                        const callee = &functions[call.func];
                        if (callee.param_types.items.len > i) {
                            const expected = typeToTag(callee.param_types.items[i]);
                            if (actual != null and actual != expected) return error.TypeMismatch;
                        }
                    }
                }
                if (resolved) |r| {
                    for (0..push_count) |j| {
                        const ret_tag = if (r.return_types.items.len > j)
                            typeToTag(r.return_types.items[j])
                        else
                            null;
                        try ctx.push(allocator, ret_tag);
                    }
                } else {
                    for (0..push_count) |_| {
                        try ctx.push(allocator, null);
                    }
                }
            } else {
                if (call.func >= functions.len) return error.InvalidFunctionIndex;
                const callee = &functions[call.func];
                var i: usize = callee.param_count;
                while (i > 0) {
                    i -= 1;
                    const actual = try ctx.pop();
                    if (callee.param_types.items.len > i) {
                        const expected = typeToTag(callee.param_types.items[i]);
                        if (actual != expected) return error.TypeMismatch;
                    }
                }
                for (0..callee.return_count) |j| {
                    const ret_tag = if (callee.return_types.items.len > j)
                        typeToTag(callee.return_types.items[j])
                    else
                        null;
                    try ctx.push(allocator, ret_tag);
                }
            }
        },
        .call_generic => |call| {
            if (call.func_instantiation >= instantiated_functions.len) return error.InvalidFunctionIndex;
            const callee = &instantiated_functions[call.func_instantiation];
            var i: usize = callee.param_count;
            while (i > 0) {
                i -= 1;
                const actual = try ctx.pop();
                if (callee.param_types.items.len > i) {
                    const expected = typeToTag(callee.param_types.items[i]);
                    if (actual != null and actual != expected) return error.TypeMismatch;
                }
            }
            for (0..callee.return_count) |j| {
                const ret_tag = if (callee.return_types.items.len > j)
                    typeToTag(callee.return_types.items[j])
                else
                    null;
                try ctx.push(allocator, ret_tag);
            }
        },
        .pack => |def_idx| {
            if (def_idx >= func.struct_defs.len) return error.InvalidFieldIndex;
            const def = func.struct_defs[def_idx];
            const n = def.fields.items.len;
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                const actual = try ctx.pop();
                const expected = typeSignatureToTag(def.fields.items[i].type_signature);
                if (actual != null and actual != expected) return error.TypeMismatch;
            }
            try ctx.push(allocator, .Struct);
        },
        .unpack => |n| {
            const ty = try ctx.pop();
            if (ty != null and ty != .Struct) return error.TypeMismatch;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try ctx.push(allocator, null);
            }
        },
        .pack_generic => |type_inst| {
            const field_count = try resolveGenericStructFieldCount(func, type_inst);
            const resolved_field_types = if (type_inst < func.resolved_struct_field_types.len)
                func.resolved_struct_field_types[type_inst].field_types
            else
                &.{};
            var i: usize = field_count;
            while (i > 0) {
                i -= 1;
                const actual = try ctx.pop();
                if (resolved_field_types.len > i) {
                    const expected = typeToTag(resolved_field_types[i]);
                    if (actual != null and actual != expected) return error.TypeMismatch;
                }
            }
            try ctx.push(allocator, .Struct);
        },
        .unpack_generic => |type_inst| {
            const field_count = try resolveGenericStructFieldCount(func, type_inst);
            const ty = try ctx.pop();
            if (ty != null and ty != .Struct) return error.TypeMismatch;
            const resolved_field_types = if (type_inst < func.resolved_struct_field_types.len)
                func.resolved_struct_field_types[type_inst].field_types
            else
                &.{};
            var i: usize = 0;
            while (i < field_count) : (i += 1) {
                const tag = if (resolved_field_types.len > i) typeToTag(resolved_field_types[i]) else null;
                try ctx.push(allocator, tag);
            }
        },
        .mut_borrow_loc => try ctx.push(allocator, .MutableReference),
        .imm_borrow_loc => try ctx.push(allocator, .Reference),
        .mut_borrow_field => {
            const ref = try ctx.pop();
            if (ref != .MutableReference and ref != .Reference) return error.TypeMismatch;
            try ctx.push(allocator, .MutableReference);
        },
        .imm_borrow_field => {
            const ref = try ctx.pop();
            if (ref != .MutableReference and ref != .Reference) return error.TypeMismatch;
            try ctx.push(allocator, .Reference);
        },
        .mut_borrow_field_generic, .imm_borrow_field_generic => {
            const ref = try ctx.pop();
            if (ref != .MutableReference and ref != .Reference) return error.TypeMismatch;
            try ctx.push(allocator, .MutableReference);
        },
        .read_ref => {
            const ref = try ctx.pop();
            if (ref != .Reference and ref != .MutableReference) return error.TypeMismatch;
            try ctx.push(allocator, null);
        },
        .write_ref => {
            _ = try ctx.pop(); // value
            const ref = try ctx.pop();
            if (ref != .MutableReference) return error.TypeMismatch;
        },
        .freeze_ref => {
            const ref = try ctx.pop();
            if (ref != .MutableReference) return error.TypeMismatch;
            try ctx.push(allocator, .Reference);
        },
        .cast_u8 => { _ = try ctx.pop(); try ctx.push(allocator, .U8); },
        .cast_u16 => { _ = try ctx.pop(); try ctx.push(allocator, .U16); },
        .cast_u32 => { _ = try ctx.pop(); try ctx.push(allocator, .U32); },
        .cast_u64 => { _ = try ctx.pop(); try ctx.push(allocator, .U64); },
        .cast_u128 => { _ = try ctx.pop(); try ctx.push(allocator, .U128); },
        .cast_u256 => { _ = try ctx.pop(); try ctx.push(allocator, .U256); },
        .abort => { _ = try ctx.pop(); },
        .nop => {},
        .vec_pack => |vp| {
            var i: usize = 0;
            while (i < vp.num) : (i += 1) {
                _ = try ctx.pop();
            }
            try ctx.push(allocator, .Vector);
        },
        .vec_len => {
            const ty = try ctx.pop();
            if (ty != .Vector) return error.TypeMismatch;
            try ctx.push(allocator, .U64);
        },
        .vec_imm_borrow => {
            _ = try ctx.pop(); // index
            const ty = try ctx.pop();
            if (ty != .Reference and ty != .MutableReference) return error.TypeMismatch;
            try ctx.push(allocator, .Reference);
        },
        .vec_mut_borrow => {
            _ = try ctx.pop(); // index
            const ty = try ctx.pop();
            if (ty != .Reference and ty != .MutableReference) return error.TypeMismatch;
            try ctx.push(allocator, .MutableReference);
        },
        .vec_push_back => {
            _ = try ctx.pop(); // elem
            const ty = try ctx.pop();
            if (ty != .MutableReference) return error.TypeMismatch;
        },
        .vec_pop_back => {
            const ty = try ctx.pop();
            if (ty != .MutableReference) return error.TypeMismatch;
            try ctx.push(allocator, null);
        },
        .vec_unpack => |vu| {
            const ty = try ctx.pop();
            if (ty != .Vector) return error.TypeMismatch;
            var i: usize = 0;
            while (i < vu.num) : (i += 1) {
                try ctx.push(allocator, null);
            }
        },
        .vec_swap => {
            _ = try ctx.pop(); // idx2
            _ = try ctx.pop(); // idx1
            const ty = try ctx.pop();
            if (ty != .MutableReference) return error.TypeMismatch;
        },
        .move_to => {
            _ = try ctx.pop(); // resource
            const ty = try ctx.pop();
            if (ty != .Signer and ty != .Address) return error.TypeMismatch;
        },
        .move_from => {
            const ty = try ctx.pop();
            if (ty != .Address) return error.TypeMismatch;
            try ctx.push(allocator, null);
        },
        .exists => {
            const ty = try ctx.pop();
            if (ty != .Address) return error.TypeMismatch;
            try ctx.push(allocator, .Bool);
        },
        .move_to_generic => {
            _ = try ctx.pop(); // resource
            const ty = try ctx.pop();
            if (ty != .Signer and ty != .Address) return error.TypeMismatch;
        },
        .move_from_generic => {
            const ty = try ctx.pop();
            if (ty != .Address) return error.TypeMismatch;
            try ctx.push(allocator, null);
        },
        .exists_generic => {
            const ty = try ctx.pop();
            if (ty != .Address) return error.TypeMismatch;
            try ctx.push(allocator, .Bool);
        },
        .mut_borrow_global => {
            const ty = try ctx.pop();
            if (ty != .Address) return error.TypeMismatch;
            try ctx.push(allocator, .MutableReference);
        },
        .imm_borrow_global => {
            const ty = try ctx.pop();
            if (ty != .Address) return error.TypeMismatch;
            try ctx.push(allocator, .Reference);
        },
        .mut_borrow_global_generic => {
            const ty = try ctx.pop();
            if (ty != .Address) return error.TypeMismatch;
            try ctx.push(allocator, .MutableReference);
        },
        .imm_borrow_global_generic => {
            const ty = try ctx.pop();
            if (ty != .Address) return error.TypeMismatch;
            try ctx.push(allocator, .Reference);
        }
    }
}

/// Verify a single function's bytecode.
/// Checks: stack balance, local index bounds, branch target bounds, type consistency.
/// Uses a simplified worklist approach for control flow.
pub fn verifyFunction(
    allocator: std.mem.Allocator,
    func: *const Function,
    functions: []const Function,
    instantiated_functions: []const Function,
    max_stack: u32,
) VerifierError!void {
    // Native functions have no bytecode, but we still verify signature consistency
    if (func.is_native) {
        if (func.param_types.items.len > 0 and func.param_count != func.param_types.items.len) return error.TypeMismatch;
        if (func.return_types.items.len > 0 and func.return_count != func.return_types.items.len) return error.TypeMismatch;
        if (func.local_count < func.param_count) return error.InvalidLocalIndex;
        return;
    }

    const code = func.code.instructions.items;
    if (code.len == 0) {
        if (func.return_count != 0) return error.MissingReturn;
        return;
    }

    var visited = try allocator.alloc(bool, code.len);
    defer allocator.free(visited);
    @memset(visited, false);

    var stack_depths = try allocator.alloc(i32, code.len);
    defer allocator.free(stack_depths);
    @memset(stack_depths, 0);

    var type_states = try allocator.alloc(?TypeContext, code.len);
    defer {
        for (type_states) |*ts| {
            if (ts.*) |*state| state.deinit(allocator);
        }
        allocator.free(type_states);
    }
    @memset(type_states, null);

    var worklist = std.ArrayList(usize).empty;
    defer worklist.deinit(allocator);

    try worklist.append(allocator, 0);
    stack_depths[0] = 0;
    var initial_state = try TypeContext.init(allocator, func.local_count);
    for (func.param_types.items, 0..) |ty, i| {
        initial_state.locals[i] = typeToTag(ty);
    }
    type_states[0] = initial_state;

    while (worklist.items.len > 0) {
        const pc = worklist.orderedRemove(0);
        if (visited[pc]) continue;

        var depth = stack_depths[pc];
        var state = try type_states[pc].?.clone(allocator);
        defer state.deinit(allocator);
        var current_pc = pc;

        while (current_pc < code.len) {
            if (visited[current_pc]) {
                if (!mergeTypeContext(&type_states[current_pc].?, state)) {
                    return error.TypeMismatch;
                }
                break;
            }
            visited[current_pc] = true;

            const inst = code[current_pc];

            // Check local index bounds
            switch (inst) {
                .ld_loc, .st_loc, .copy_loc, .move_loc,
                .mut_borrow_loc, .imm_borrow_loc => |idx| {
                    if (idx >= func.local_count) return error.InvalidLocalIndex;
                },
                else => {},
            }

            // Check constant pool index bounds
            switch (inst) {
                .ld_const => |lc| {
                    if (lc.const_idx >= func.constants.len) return error.InvalidInstruction;
                },
                .ld_addr => |la| {
                    if (la.addr_idx >= func.constants.len) return error.InvalidInstruction;
                },
                else => {},
            }

            // Check branch target bounds
            switch (inst) {
                .br_true, .br_false, .branch => |target| {
                    if (target >= code.len) return error.InvalidBranchTarget;
                },
                else => {},
            }

            // Apply stack effect
            const effect = try instructionStackEffect(inst, func, functions, instantiated_functions);
            depth -= effect.pop;
            if (depth < 0) return error.StackUnderflow;
            depth += effect.push;
            if (depth > max_stack) return error.StackOverflow;

            // Apply type effect
            try applyTypeEffect(&state, allocator, inst, func, functions, instantiated_functions);

            // Verify stack depth matches type stack length
            if (depth != @as(i32, @intCast(state.depth()))) {
                return error.StackUnderflow;
            }

            // Determine control flow
            switch (inst) {
                .ret => |r| {
                    if (r.num_vals != func.return_count) return error.TypeMismatch;
                    if (depth != 0) return error.ExtraValueOnStack;
                    break;
                },
                .branch => |target| {
                    if (target < code.len and type_states[target] != null and !visited[target]) {
                        if (stack_depths[target] != depth) {
                            return error.TypeMismatch;
                        }
                        if (!mergeTypeContext(&type_states[target].?, state)) {
                            return error.TypeMismatch;
                        }
                        break;
                    }
                    if (!visited[target]) {
                        stack_depths[target] = depth;
                        const target_state = try state.clone(allocator);
                        if (type_states[target]) |*old| old.deinit(allocator);
                        type_states[target] = target_state;
                        try worklist.append(allocator, target);
                    } else if (stack_depths[target] != depth) {
                        return error.StackUnderflow;
                    }
                    break;
                },
                .br_true, .br_false => |target| {
                    const next_pc = current_pc + 1;
                    if (next_pc < code.len and type_states[next_pc] != null and !visited[next_pc]) {
                        if (stack_depths[next_pc] != depth) {
                            return error.TypeMismatch;
                        }
                        if (!mergeTypeContext(&type_states[next_pc].?, state)) {
                            return error.TypeMismatch;
                        }
                    } else if (next_pc < code.len and !visited[next_pc]) {
                        stack_depths[next_pc] = depth;
                        const next_state = try state.clone(allocator);
                        if (type_states[next_pc]) |*old| old.deinit(allocator);
                        type_states[next_pc] = next_state;
                        try worklist.append(allocator, next_pc);
                    } else if (next_pc < code.len and visited[next_pc] and stack_depths[next_pc] != depth) {
                        return error.StackUnderflow;
                    }
                    if (target < code.len and type_states[target] != null and !visited[target]) {
                        if (stack_depths[target] != depth) {
                            return error.TypeMismatch;
                        }
                        if (!mergeTypeContext(&type_states[target].?, state)) {
                            return error.TypeMismatch;
                        }
                        break;
                    }
                    if (!visited[target]) {
                        stack_depths[target] = depth;
                        const target_state = try state.clone(allocator);
                        if (type_states[target]) |*old| old.deinit(allocator);
                        type_states[target] = target_state;
                        try worklist.append(allocator, target);
                    } else if (stack_depths[target] != depth) {
                        return error.StackUnderflow;
                    }
                    break;
                },
                .call, .call_generic => {
                    const next_pc = current_pc + 1;
                    if (next_pc < code.len and type_states[next_pc] != null and !visited[next_pc]) {
                        if (stack_depths[next_pc] != depth) {
                            return error.TypeMismatch;
                        }
                        if (!mergeTypeContext(&type_states[next_pc].?, state)) {
                            return error.TypeMismatch;
                        }
                    } else if (next_pc < code.len and !visited[next_pc]) {
                        stack_depths[next_pc] = depth;
                        const next_state = try state.clone(allocator);
                        if (type_states[next_pc]) |*old| old.deinit(allocator);
                        type_states[next_pc] = next_state;
                        try worklist.append(allocator, next_pc);
                    }
                    break;
                },
                else => {
                    const next_pc = current_pc + 1;
                    if (next_pc < code.len and type_states[next_pc] != null and !visited[next_pc]) {
                        if (stack_depths[next_pc] != depth) {
                            return error.TypeMismatch;
                        }
                        if (!mergeTypeContext(&type_states[next_pc].?, state)) {
                            return error.TypeMismatch;
                        }
                        break;
                    }
                    current_pc += 1;
                },
            }
        }
    }
}
