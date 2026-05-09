const std = @import("std");
const bytecode = @import("bytecode.zig");
const values = @import("values.zig");
const Value = values.Value;
const ValueImpl = values.ValueImpl;
const IntegerValue = values.IntegerValue;
const StructValue = values.StructValue;
const VectorValue = values.VectorValue;
const locals_mod = @import("locals.zig");
const Locals = locals_mod.Locals;
const stack_mod = @import("stack.zig");
const Stack = stack_mod.Stack;
const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;
const Function = frame_mod.Function;
const gas = @import("../gas/gas.zig");
const Gas = gas.Gas;
const types = @import("types.zig");
const module_mod = @import("module.zig");
const vm_loader = @import("loader.zig");
const vm_verifier = @import("verifier.zig");

/// ExitCode returned by Frame execution to the Interpreter main loop.
pub const ExitCode = union(enum) {
    Return,
    Call: u16,
    CallGeneric: u16,
};

/// Internal instruction execution result.
pub const InstrRet = union(enum) {
    Ok,
    ExitCode: ExitCode,
    Branch,
};

/// Execution result from the interpreter.
pub const ExecutionResult = struct {
    values: []Value,
    gas_used: u64,

    pub fn deinit(self: ExecutionResult, allocator: std.mem.Allocator) void {
        for (self.values) |*val| {
            val.deinit(allocator);
        }
        allocator.free(self.values);
    }
};

/// VM execution errors.
pub const VMError = error{
    OutOfGas,
    Aborted,
    TypeMismatch,
    InvalidLocal,
    InvalidReference,
    CopyResource,
    CallStackOverflow,
    NoFunctionInFrame,
    InvalidInstruction,
    DivisionByZero,
    StackOverflow,
    StackUnderflow,
    IndexOutOfBounds,
    Overflow,
    ModuleNotFound,
    FunctionNotFound,
    ExecutionFailure,
    InvalidResource,
    MissingStorage,
    MissingReturn,
    OutOfMemory,
    BorrowedResource,
};

const storage_mod = @import("../storage/storage.zig");
const native_mod = @import("native.zig");

pub const Interpreter = struct {
    operand_stack: Stack,
    call_stack: std.ArrayList(Frame),
    paranoid_type_checks: bool,
    storage: ?*storage_mod.DataStore,
    native_functions: ?*native_mod.NativeFunctions,
    instantiated_functions: []const Function,
    instantiated_function_ty_args: []const []const types.Type,
    max_call_depth: u32,
    events: ?*std.ArrayList(native_mod.Event),
    loader: ?*vm_loader.Loader,
    last_abort_code: u64,
    verified_set: std.AutoHashMap(usize, void),

    const Self = @This();
    const DEFAULT_MAX_CALL_DEPTH: u32 = 256;
    const DEFAULT_MAX_STACK_SIZE: u32 = 1024;

    pub fn init(allocator: std.mem.Allocator) Self {
        return initWithConfig(allocator, DEFAULT_MAX_STACK_SIZE, DEFAULT_MAX_CALL_DEPTH, false);
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, max_stack_size: u32, max_call_depth: u32, paranoid_type_checks: bool) Self {
        return .{
            .operand_stack = Stack.initMax(allocator, max_stack_size),
            .call_stack = std.ArrayList(Frame).empty,
            .paranoid_type_checks = paranoid_type_checks,
            .storage = null,
            .native_functions = null,
            .instantiated_functions = &.{},
            .instantiated_function_ty_args = &.{},
            .max_call_depth = max_call_depth,
            .events = null,
            .loader = null,
            .last_abort_code = 0,
            .verified_set = std.AutoHashMap(usize, void).init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.operand_stack.deinit(allocator);
        self.call_stack.deinit(allocator);
        self.verified_set.deinit();
    }

    pub fn setStorage(self: *Self, store: *storage_mod.DataStore) void {
        self.storage = store;
    }

    pub fn setNativeFunctions(self: *Self, natives: *native_mod.NativeFunctions) void {
        self.native_functions = natives;
    }

    pub fn setInstantiatedFunctions(self: *Self, funcs: []const Function) void {
        self.instantiated_functions = funcs;
    }

    pub fn setInstantiatedFunctionTyArgs(self: *Self, ty_args: []const []const types.Type) void {
        self.instantiated_function_ty_args = ty_args;
    }

    pub fn setEvents(self: *Self, events: *std.ArrayList(native_mod.Event)) void {
        self.events = events;
    }

    pub fn setLoader(self: *Self, loader: *vm_loader.Loader) void {
        self.loader = loader;
    }

    /// Parse a constant from module constant pool data.
    fn parseConstant(constant: module_mod.Constant) VMError!Value {
        const data = constant.data;
        return switch (constant.type_signature) {
            .Bool => {
                if (data.len < 1) return error.TypeMismatch;
                return Value.makeBool(data[0] != 0);
            },
            .U8 => {
                if (data.len < 1) return error.TypeMismatch;
                return Value.makeU8(data[0]);
            },
            .U16 => {
                if (data.len < 2) return error.TypeMismatch;
                return Value.makeU16(std.mem.readInt(u16, data[0..2], .little));
            },
            .U32 => {
                if (data.len < 4) return error.TypeMismatch;
                return Value.makeU32(std.mem.readInt(u32, data[0..4], .little));
            },
            .U64 => {
                if (data.len < 8) return error.TypeMismatch;
                return Value.makeU64(std.mem.readInt(u64, data[0..8], .little));
            },
            .U128 => {
                if (data.len < 16) return error.TypeMismatch;
                return Value.makeU128(std.mem.readInt(u128, data[0..16], .little));
            },
            .U256 => {
                if (data.len < 32) return error.TypeMismatch;
                return Value.makeU256(std.mem.readInt(u256, data[0..32], .little));
            },
            .Address => {
                if (data.len < 32) return error.TypeMismatch;
                var addr: [32]u8 = undefined;
                @memcpy(&addr, data[0..32]);
                return Value.address(addr);
            },
            else => error.TypeMismatch,
        };
    }

    /// Resolve generic struct info from a type instantiation index.
    /// Returns field count and abilities if module context is available.
    pub fn resolveGenericStruct(func: *const Function, type_inst: u16) VMError!struct { field_count: u16, abilities: types.AbilitySet, field_types: []const types.Type } {
        if (type_inst >= func.struct_instantiations.len) {
            return error.InvalidInstruction;
        }
        const inst = func.struct_instantiations[type_inst];
        if (inst.def >= func.struct_defs.len) {
            return error.InvalidInstruction;
        }
        const def = func.struct_defs[inst.def];
        const resolved_field_types = if (type_inst < func.resolved_struct_field_types.len)
            func.resolved_struct_field_types[type_inst].field_types
        else
            &.{};
        return .{
            .field_count = @intCast(def.fields.items.len),
            .abilities = def.abilities,
            .field_types = resolved_field_types,
        };
    }

    /// Execute a native function and return the result.
    fn executeNative(
        self: *Self,
        allocator: std.mem.Allocator,
        native_func: native_mod.NativeFunc,
        ty_args: []const types.Type,
        native_args: []Value,
        gas_meter: *Gas,
    ) VMError![]Value {
        var ctx = native_mod.NativeContext{ .gas_remaining = gas_meter.getRemaining(), .events = self.events };
        const native_result = native_func(allocator, &ctx, ty_args, native_args) catch |err| {
            // Charge minimum overhead on failure to prevent free computation
            gas_meter.consume(1) catch {};
            return err;
        };
        try gas_meter.consume(native_result.cost);
        if (native_result.is_abort) {
            self.last_abort_code = native_result.abort_code;
            allocator.free(native_result.values);
            return error.Aborted;
        }
        const results = try allocator.dupe(Value, native_result.values);
        allocator.free(native_result.values);
        return results;
    }

    /// Charge additional gas for data-size-dependent operations.
    fn chargeDataSizeGas(self: *Self, inst: bytecode.Instruction, gas_meter: *Gas) VMError!void {
        switch (inst) {
            .eq, .neq => {
                if (self.operand_stack.values.items.len >= 2) {
                    const rhs = self.operand_stack.values.items[self.operand_stack.values.items.len - 1];
                    const lhs = self.operand_stack.values.items[self.operand_stack.values.items.len - 2];
                    var extra: u64 = 0;
                    if (rhs.impl == .Container) extra += @as(u64, rhs.impl.Container.data.items.len) * 2;
                    if (lhs.impl == .Container) extra += @as(u64, lhs.impl.Container.data.items.len) * 2;
                    try gas_meter.consume(extra);
                }
            },
            .pack => |n| try gas_meter.consume(@as(u64, n) * 2),
            .pack_generic => |type_inst| {
                if (self.call_stack.items.len > 0) {
                    const frame_func = self.call_stack.items[self.call_stack.items.len - 1].function;
                    if (type_inst >= frame_func.struct_instantiations.len) return error.InvalidInstruction;
                    const si = frame_func.struct_instantiations[type_inst];
                    if (si.def >= frame_func.struct_defs.len) return error.InvalidInstruction;
                    const n_fields = frame_func.struct_defs[si.def].fields.items.len;
                    try gas_meter.consume(@as(u64, n_fields) * 2);
                }
            },
            .vec_pack => |vp| try gas_meter.consume(@as(u64, vp.num) * 2),
            .move_to => {
                if (self.operand_stack.values.items.len >= 1) {
                    const res = self.operand_stack.values.items[self.operand_stack.values.items.len - 1];
                    if (res.impl == .Container) {
                        try gas_meter.consume(@as(u64, res.impl.Container.data.items.len) * 2);
                    }
                }
            },
            .move_to_generic => {
                if (self.operand_stack.values.items.len >= 1) {
                    const res = self.operand_stack.values.items[self.operand_stack.values.items.len - 1];
                    if (res.impl == .Container) {
                        try gas_meter.consume(@as(u64, res.impl.Container.data.items.len) * 2);
                    }
                }
            },
            .read_ref => {
                if (self.operand_stack.values.items.len >= 1) {
                    const ref = self.operand_stack.values.items[self.operand_stack.values.items.len - 1];
                    if (ref.impl == .ContainerRef) {
                        try gas_meter.consume(@as(u64, ref.impl.ContainerRef.container.data.items.len) * 2);
                    }
                }
            },
            .write_ref => {
                if (self.operand_stack.values.items.len >= 2) {
                    const val = self.operand_stack.values.items[self.operand_stack.values.items.len - 1];
                    if (val.impl == .Container) {
                        try gas_meter.consume(@as(u64, val.impl.Container.data.items.len) * 2);
                    }
                }
            },
            else => {},
        }
    }

    /// Entry point: execute a function with arguments.
    pub fn executeFunction(
        self: *Self,
        allocator: std.mem.Allocator,
        func: *const Function,
        functions: []const Function,
        ty_args: []const types.Type,
        args: []const Value,
        gas_meter: *Gas,
    ) VMError!ExecutionResult {
        // Mandatory bytecode verification before execution (cached to avoid repeated gas consumption)
        const func_ptr = @intFromPtr(func);
        if (!self.verified_set.contains(func_ptr)) {
            vm_verifier.verifyFunction(allocator, func, functions, self.instantiated_functions, self.operand_stack.max_size) catch |verr| {
                return switch (verr) {
                    error.StackUnderflow => error.StackUnderflow,
                    error.StackOverflow => error.StackOverflow,
                    error.TypeMismatch => error.TypeMismatch,
                    error.InvalidLocalIndex => error.InvalidLocal,
                    error.InvalidBranchTarget => error.InvalidInstruction,
                    error.InvalidFieldIndex => error.InvalidInstruction,
                    error.InvalidFunctionIndex => error.FunctionNotFound,
                    error.InvalidInstruction => error.InvalidInstruction,
                    error.ExtraValueOnStack => error.InvalidInstruction,
                    error.MissingReturn => error.MissingReturn,
                    error.OutOfMemory => error.OutOfMemory,
                };
            };
            try self.verified_set.put(func_ptr, {});
        }

        // Handle native entry functions directly
        if (func.is_native) {
            if (args.len != func.param_count) return error.TypeMismatch;
            const native_registry = self.native_functions orelse return error.FunctionNotFound;
            const native_func = if (func.native_idx) |idx|
                native_registry.lookupByIdx(idx) orelse return error.FunctionNotFound
            else
                native_registry.lookup(func.module, func.name) orelse return error.FunctionNotFound;

            var native_args = try allocator.alloc(Value, func.param_count);
            defer allocator.free(native_args);
            var i: usize = func.param_count;
            while (i > 0) {
                i -= 1;
                native_args[i] = args[i];
            }

            const results = try self.executeNative(allocator, native_func, ty_args, native_args, gas_meter);
            defer allocator.free(results);
            const out = try allocator.dupe(Value, results);
            return .{ .values = out, .gas_used = gas_meter.getUsed() };
        }

        // Validate argument count
        if (args.len != func.param_count) return error.TypeMismatch;

        // Initialize locals from args (charge gas proportional to local count)
        try gas_meter.consume(@as(u64, func.local_count));
        var locals = try Locals.new(allocator, func.local_count);

        for (args, 0..) |arg, i| {
            try locals.store_loc(allocator, @intCast(i), arg);
        }

        const initial_frame = Frame.init(locals, func, ty_args);
        try self.call_stack.append(allocator, initial_frame);

        const result = self.executeMain(allocator, functions, gas_meter) catch |err| {
            // Clean up operand stack FIRST to decrement ref_counts, then free locals
            self.operand_stack.clearAndDeinit(allocator);
            while (self.call_stack.pop()) |frame| {
                frame.locals.deinit(allocator);
            }
            return err;
        };

        // On success, executeMain should have emptied the call stack
        std.debug.assert(self.call_stack.items.len == 0);

        return result;
    }

    /// Main execution loop.
    fn executeMain(self: *Self, allocator: std.mem.Allocator, functions: []const Function, gas_meter: *Gas) VMError!ExecutionResult {
        while (self.call_stack.items.len > 0) {
            const frame_idx = self.call_stack.items.len - 1;
            const current_frame = &self.call_stack.items[frame_idx];

            const exit_code = self.executeCode(allocator, current_frame, gas_meter) catch |err| {
                return err;
            };

            switch (exit_code) {
                .Return => {
                    const returned_frame = self.call_stack.pop().?;

                    if (self.call_stack.items.len > 0) {
                        // Intermediate return: deinit locals after caller consumes values
                        returned_frame.locals.deinit(allocator);
                        // Return to caller: advance PC past the Call instruction
                        const caller = &self.call_stack.items[self.call_stack.items.len - 1];
                        caller.pc += 1;
                    } else {
                        // End of execution: pop return values BEFORE freeing locals
                        const return_count = returned_frame.function.return_count;
                        var results = try allocator.alloc(Value, return_count);
                        var popped: usize = 0;
                        errdefer {
                            var j: usize = 0;
                            while (j < popped) : (j += 1) {
                                results[j].deinit(allocator);
                            }
                            allocator.free(results);
                        }
                        while (popped < return_count) {
                            results[return_count - 1 - popped] = try self.operand_stack.pop();
                            popped += 1;
                        }
                        returned_frame.locals.deinit(allocator);
                        return .{
                            .values = results,
                            .gas_used = gas_meter.getUsed(),
                        };
                    }
                },
                .Call => |func_idx| {
                    if (self.call_stack.items.len >= self.max_call_depth) {
                        return error.CallStackOverflow;
                    }

                    const caller_frame = &self.call_stack.items[self.call_stack.items.len - 1];
                    const callee = blk: {
                        if (caller_frame.function.function_handles.len > 0) {
                            if (func_idx >= caller_frame.function.function_handles.len) {
                                return error.InvalidInstruction;
                            }

                            // Use resolved_handles if available (set by Loader during module compilation)
                            if (func_idx < caller_frame.function.resolved_handles.len) {
                                if (caller_frame.function.resolved_handles[func_idx]) |r| {
                                    break :blk r;
                                }
                            }

                            const handle = caller_frame.function.function_handles[func_idx];

                            // Fallback: try loader
                            if (self.loader) |loader| {
                                const resolved = try loader.resolveFunction(handle.module, handle.name);
                                if (resolved) |r| break :blk r;
                            }

                            // Fallback: search functions array by name
                            for (functions) |*f| {
                                if (std.mem.eql(u8, f.name, handle.name)) {
                                    break :blk f;
                                }
                            }
                            return error.FunctionNotFound;
                        } else {
                            // Backward compatibility: local index
                            if (func_idx >= functions.len) {
                                return error.FunctionNotFound;
                            }
                            break :blk &functions[func_idx];
                        }
                    };

                    if (callee.is_native) {
                        const native_registry = self.native_functions orelse return error.FunctionNotFound;
                        const native_func = if (callee.native_idx) |idx|
                            native_registry.lookupByIdx(idx) orelse return error.FunctionNotFound
                        else
                            native_registry.lookup(callee.module, callee.name) orelse return error.FunctionNotFound;

                        var native_args = try allocator.alloc(Value, callee.param_count);
                        defer allocator.free(native_args);
                        var i: usize = callee.param_count;
                        while (i > 0) {
                            i -= 1;
                            native_args[i] = try self.operand_stack.pop();
                        }

                        const results = try self.executeNative(allocator, native_func, &.{}, native_args, gas_meter);
                        defer allocator.free(results);
                        for (results) |val| {
                            try self.operand_stack.push(allocator, val);
                        }

                        // Advance caller PC since native call is synchronous
                        if (self.call_stack.items.len > 0) {
                            const caller = &self.call_stack.items[self.call_stack.items.len - 1];
                            caller.pc += 1;
                        }
                    } else {
                        // Pop arguments from operand stack (last arg is on top)
                        try gas_meter.consume(@as(u64, callee.local_count));
                        var callee_locals = try Locals.new(allocator, callee.local_count);
                        errdefer callee_locals.deinit(allocator);
                        var i: usize = callee.param_count;
                        while (i > 0) {
                            i -= 1;
                            const arg = try self.operand_stack.pop();
                            try callee_locals.store_loc(allocator, @intCast(i), arg);
                        }

                        const new_frame = Frame.init(callee_locals, callee, &.{});
                        errdefer new_frame.locals.deinit(allocator);
                        try self.call_stack.append(allocator, new_frame);
                    }
                },
                .CallGeneric => |func_inst| {
                    if (self.call_stack.items.len >= self.max_call_depth) {
                        return error.CallStackOverflow;
                    }
                    const func_idx = func_inst;
                    if (func_idx >= self.instantiated_functions.len) {
                        return error.FunctionNotFound;
                    }
                    const callee = &self.instantiated_functions[func_idx];

                    if (callee.is_native) {
                        const native_registry = self.native_functions orelse return error.FunctionNotFound;
                        const native_func = if (callee.native_idx) |idx|
                            native_registry.lookupByIdx(idx) orelse return error.FunctionNotFound
                        else
                            native_registry.lookup(callee.module, callee.name) orelse return error.FunctionNotFound;

                        var native_args = try allocator.alloc(Value, callee.param_count);
                        defer allocator.free(native_args);
                        var i: usize = callee.param_count;
                        while (i > 0) {
                            i -= 1;
                            native_args[i] = try self.operand_stack.pop();
                        }

                        const generic_ty_args = if (func_idx < self.instantiated_function_ty_args.len)
                            self.instantiated_function_ty_args[func_idx]
                        else
                            &.{};
                        const results = try self.executeNative(allocator, native_func, generic_ty_args, native_args, gas_meter);
                        defer allocator.free(results);
                        for (results) |val| {
                            try self.operand_stack.push(allocator, val);
                        }

                        if (self.call_stack.items.len > 0) {
                            const caller = &self.call_stack.items[self.call_stack.items.len - 1];
                            caller.pc += 1;
                        }
                    } else {
                        var callee_locals = try Locals.new(allocator, callee.local_count);
                        errdefer callee_locals.deinit(allocator);
                        var i: usize = callee.param_count;
                        while (i > 0) {
                            i -= 1;
                            const arg = try self.operand_stack.pop();
                            try callee_locals.store_loc(allocator, @intCast(i), arg);
                        }

                        const new_frame = Frame.init(callee_locals, callee, &.{});
                        errdefer new_frame.locals.deinit(allocator);
                        try self.call_stack.append(allocator, new_frame);
                    }
                },
            }
        }

        return .{ .values = &.{}, .gas_used = gas_meter.getUsed() };
    }

    /// Execute a single function's bytecode until Return/Call/CallGeneric.
    fn executeCode(self: *Self, allocator: std.mem.Allocator, frame: *Frame, gas_meter: *Gas) VMError!ExitCode {
        const code = &frame.function.code.instructions;
        while (frame.pc < code.items.len) {
            const inst = code.items[frame.pc];
            try gas_meter.consume(instructionGasCost(inst));
            try self.chargeDataSizeGas(inst, gas_meter);

            const instr_ret = try self.executeInstruction(allocator, frame, inst);
            switch (instr_ret) {
                .Ok => frame.pc += 1,
                .ExitCode => |ec| return ec,
                .Branch => {}, // pc already set by the instruction
            }
        }
        return error.MissingReturn;
    }

    /// Execute a single instruction.
    fn executeInstruction(self: *Self, allocator: std.mem.Allocator, frame: *Frame, inst: bytecode.Instruction) VMError!InstrRet {
        switch (inst) {
            // Stack operations
            .pop => {
                var val = try self.operand_stack.pop();
                if (!val.impl.canDrop()) {
                    try self.operand_stack.push(allocator, val);
                    return error.TypeMismatch;
                }
                val.deinit(allocator);
            },
            .ret => |r| {
                if (r.num_vals != frame.function.return_count) return error.TypeMismatch;
                if (self.operand_stack.values.items.len < r.num_vals) return error.StackUnderflow;
                return .{ .ExitCode = .Return };
            },

            // Constant loading
            .ld_u8 => |x| try self.operand_stack.push(allocator, Value.makeU8(x)),
            .ld_u16 => |x| try self.operand_stack.push(allocator, Value.makeU16(x)),
            .ld_u32 => |x| try self.operand_stack.push(allocator, Value.makeU32(x)),
            .ld_u64 => |x| try self.operand_stack.push(allocator, Value.makeU64(x)),
            .ld_u128 => |x| try self.operand_stack.push(allocator, Value.makeU128(x)),
            .ld_u256 => |x| try self.operand_stack.push(allocator, Value.makeU256(x)),
            .ld_true => try self.operand_stack.push(allocator, Value.makeBool(true)),
            .ld_false => try self.operand_stack.push(allocator, Value.makeBool(false)),
            .ld_const => |lc| {
                if (lc.const_idx >= frame.function.constants.len) return error.InvalidInstruction;
                const constant = frame.function.constants[lc.const_idx];
                const val = try Self.parseConstant(constant);
                try self.operand_stack.push(allocator, val);
            },
            .ld_addr => |la| {
                if (la.addr_idx >= frame.function.constants.len) return error.InvalidInstruction;
                const constant = frame.function.constants[la.addr_idx];
                if (constant.type_signature != .Address) return error.TypeMismatch;
                if (constant.data.len < 32) return error.TypeMismatch;
                var addr: [32]u8 = undefined;
                @memcpy(&addr, constant.data[0..32]);
                try self.operand_stack.push(allocator, Value.address(addr));
            },

            // Local operations
            .ld_loc => |idx| {
                const val = try frame.locals.copy_loc(allocator, idx);
                try self.operand_stack.push(allocator, val);
            },
            .copy_loc => |idx| {
                const val = try frame.locals.copy_loc(allocator, idx);
                if (!val.canCopy()) {
                    var v = val;
                    v.deinit(allocator);
                    return error.CopyResource;
                }
                try self.operand_stack.push(allocator, val);
            },
            .move_loc => |idx| {
                const val = try frame.locals.move_loc(idx);
                try self.operand_stack.push(allocator, val);
            },
            .st_loc => |idx| {
                const val = try self.operand_stack.pop();
                try frame.locals.store_loc(allocator, idx, val);
            },

            // Reference operations
            .mut_borrow_loc => |idx| {
                const ref = try frame.locals.borrow_loc(idx, true);
                try self.operand_stack.push(allocator, ref);
            },
            .imm_borrow_loc => |idx| {
                const ref = try frame.locals.borrow_loc(idx, false);
                try self.operand_stack.push(allocator, ref);
            },
            .read_ref => {
                var ref = try self.operand_stack.pop();
                defer ref.deinit(allocator);
                const val = try ref.read_ref(allocator);
                try self.operand_stack.push(allocator, val);
            },
            .write_ref => {
                var val = try self.operand_stack.pop();
                defer val.deinit(allocator);
                var ref = try self.operand_stack.pop();
                defer ref.deinit(allocator);
                if (!val.canStore()) {
                    return error.TypeMismatch;
                }
                // Log change before writing to a borrowed global so rollback can restore it
                const is_global_ref = switch (ref.impl) {
                    .ContainerRef => |r| r.is_global,
                    .IndexedRef => |r| r.container_ref.is_global,
                    else => false,
                };
                if (is_global_ref) {
                    const addr = switch (ref.impl) {
                        .ContainerRef => |r| r.global_address,
                        .IndexedRef => |r| r.container_ref.global_address,
                        else => null,
                    };
                    const tk = switch (ref.impl) {
                        .ContainerRef => |r| r.global_type_key,
                        .IndexedRef => |r| r.container_ref.global_type_key,
                        else => null,
                    };
                    if (addr) |a| {
                        if (tk) |t| {
                            if (self.storage) |store| {
                                try store.logChange(a, t);
                            }
                        }
                    }
                }
                try ref.write_ref(allocator, val);
            },
            .freeze_ref => {
                var ref = try self.operand_stack.pop();
                switch (ref.impl) {
                    .ContainerRef => |*r| r.is_mutable = false,
                    .IndexedRef => |*r| r.container_ref.is_mutable = false,
                    else => return error.TypeMismatch,
                }
                try self.operand_stack.push(allocator, ref);
            },

            // Arithmetic
            .add => try self.binopInt(allocator, IntegerValue.add_checked),
            .sub => try self.binopInt(allocator, IntegerValue.sub_checked),
            .mul => try self.binopInt(allocator, IntegerValue.mul_checked),
            .div => try self.binopInt(allocator, IntegerValue.div_checked),
            .mod => try self.binopInt(allocator, IntegerValue.rem_checked),
            .bit_and => try self.binopInt(allocator, IntegerValue.bit_and),
            .bit_or => try self.binopInt(allocator, IntegerValue.bit_or),
            .bit_xor => try self.binopInt(allocator, IntegerValue.bit_xor),
            .shl => {
                var b = try self.operand_stack.pop();
                defer b.deinit(allocator);
                var a = try self.operand_stack.pop();
                defer a.deinit(allocator);
                const rhs = try IntegerValue.fromValue(b);
                const lhs = try IntegerValue.fromValue(a);
                const result = try IntegerValue.shl_checked(lhs, rhs);
                try self.operand_stack.push(allocator, result.toValue());
            },
            .shr => {
                var b = try self.operand_stack.pop();
                defer b.deinit(allocator);
                var a = try self.operand_stack.pop();
                defer a.deinit(allocator);
                const rhs = try IntegerValue.fromValue(b);
                const lhs = try IntegerValue.fromValue(a);
                const result = try IntegerValue.shr_checked(lhs, rhs);
                try self.operand_stack.push(allocator, result.toValue());
            },

            // Logical
            .and_ => {
                const b = try self.operand_stack.popAs(bool);
                const a = try self.operand_stack.popAs(bool);
                try self.operand_stack.push(allocator, Value.makeBool(a and b));
            },
            .or_ => {
                const b = try self.operand_stack.popAs(bool);
                const a = try self.operand_stack.popAs(bool);
                try self.operand_stack.push(allocator, Value.makeBool(a or b));
            },
            .not => {
                const a = try self.operand_stack.popAs(bool);
                try self.operand_stack.push(allocator, Value.makeBool(!a));
            },

            // Comparison
            .lt => try self.cmpopInt(allocator, IntegerValue.lt),
            .gt => try self.cmpopInt(allocator, IntegerValue.gt),
            .le => try self.cmpopInt(allocator, IntegerValue.le),
            .ge => try self.cmpopInt(allocator, IntegerValue.ge),
            .eq => {
                var b = try self.operand_stack.pop();
                defer b.deinit(allocator);
                var a = try self.operand_stack.pop();
                defer a.deinit(allocator);
                const a_is_ref = switch (a.impl) { .ContainerRef, .IndexedRef => true, else => false };
                const b_is_ref = switch (b.impl) { .ContainerRef, .IndexedRef => true, else => false };
                const result = if (a_is_ref and b_is_ref) blk: {
                    var a_val = try a.read_ref(allocator);
                    defer a_val.deinit(allocator);
                    var b_val = try b.read_ref(allocator);
                    defer b_val.deinit(allocator);
                    break :blk try a_val.equals(b_val);
                } else if (!a_is_ref and !b_is_ref) blk: {
                    break :blk try a.equals(b);
                } else {
                    return error.TypeMismatch;
                };
                try self.operand_stack.push(allocator, Value.makeBool(result));
            },
            .neq => {
                var b = try self.operand_stack.pop();
                defer b.deinit(allocator);
                var a = try self.operand_stack.pop();
                defer a.deinit(allocator);
                const a_is_ref = switch (a.impl) { .ContainerRef, .IndexedRef => true, else => false };
                const b_is_ref = switch (b.impl) { .ContainerRef, .IndexedRef => true, else => false };
                const result = if (a_is_ref and b_is_ref) blk: {
                    var a_val = try a.read_ref(allocator);
                    defer a_val.deinit(allocator);
                    var b_val = try b.read_ref(allocator);
                    defer b_val.deinit(allocator);
                    break :blk try a_val.equals(b_val);
                } else if (!a_is_ref and !b_is_ref) blk: {
                    break :blk try a.equals(b);
                } else {
                    return error.TypeMismatch;
                };
                try self.operand_stack.push(allocator, Value.makeBool(!result));
            },

            // Control flow
            .br_true => |offset| {
                const cond = try self.operand_stack.popAs(bool);
                if (cond) {
                    frame.pc = offset;
                    return .Branch;
                }
            },
            .br_false => |offset| {
                const cond = try self.operand_stack.popAs(bool);
                if (!cond) {
                    frame.pc = offset;
                    return .Branch;
                }
            },
            .branch => |offset| {
                frame.pc = offset;
                return .Branch;
            },
            .call => |call| {
                return .{ .ExitCode = .{ .Call = call.func } };
            },
            .call_generic => |call| {
                return .{ .ExitCode = .{ .CallGeneric = call.func_instantiation } };
            },

            // Pack/Unpack
            .pack => |def_idx| {
                if (def_idx >= frame.function.struct_defs.len) return error.InvalidInstruction;
                const def = &frame.function.struct_defs[def_idx];
                const n = def.fields.items.len;
                const fields = try self.operand_stack.popn(allocator, @intCast(n));
                defer {
                    for (fields) |*field| field.deinit(allocator);
                    allocator.free(fields);
                }
                const s = try StructValue.pack(allocator, fields, def.abilities);
                try self.operand_stack.push(allocator, s);
            },
            .pack_generic => |type_inst| {
                const info = try Self.resolveGenericStruct(frame.function, type_inst);
                const fields = try self.operand_stack.popn(allocator, info.field_count);
                defer {
                    for (fields) |*field| field.deinit(allocator);
                    allocator.free(fields);
                }
                const s = try StructValue.pack(allocator, fields, info.abilities);
                try self.operand_stack.push(allocator, s);
            },
            .unpack => |n| {
                var val = try self.operand_stack.pop();
                if (val.impl == .Container and val.impl.Container.ref_count > 0) return error.InvalidReference;
                var unpacked = try StructValue.unpack(val, allocator);
                defer {
                    for (unpacked.items) |*item| item.deinit(allocator);
                    unpacked.deinit(allocator);
                }
                if (unpacked.items.len != n) return error.TypeMismatch;
                for (unpacked.items) |field| {
                    try self.operand_stack.push(allocator, field);
                }
                val.deinit(allocator);
            },
            .unpack_generic => |type_inst| {
                const info = try Self.resolveGenericStruct(frame.function, type_inst);
                var val = try self.operand_stack.pop();
                if (val.impl == .Container and val.impl.Container.ref_count > 0) return error.InvalidReference;
                var unpacked = try StructValue.unpack(val, allocator);
                defer {
                    for (unpacked.items) |*item| item.deinit(allocator);
                    unpacked.deinit(allocator);
                }
                if (unpacked.items.len != info.field_count) return error.TypeMismatch;
                for (unpacked.items) |field| {
                    try self.operand_stack.push(allocator, field);
                }
                val.deinit(allocator);
            },

            // Cast
            .cast_u8 => {
                var v = try self.operand_stack.pop();
                defer v.deinit(allocator);
                const int = try IntegerValue.fromValue(v);
                const result = try IntegerValue.cast_u8(int);
                try self.operand_stack.push(allocator, Value.makeU8(result));
            },
            .cast_u16 => {
                var v = try self.operand_stack.pop();
                defer v.deinit(allocator);
                const int = try IntegerValue.fromValue(v);
                const result = try IntegerValue.cast_u16(int);
                try self.operand_stack.push(allocator, Value.makeU16(result));
            },
            .cast_u32 => {
                var v = try self.operand_stack.pop();
                defer v.deinit(allocator);
                const int = try IntegerValue.fromValue(v);
                const result = try IntegerValue.cast_u32(int);
                try self.operand_stack.push(allocator, Value.makeU32(result));
            },
            .cast_u64 => {
                var v = try self.operand_stack.pop();
                defer v.deinit(allocator);
                const int = try IntegerValue.fromValue(v);
                const result = try IntegerValue.cast_u64(int);
                try self.operand_stack.push(allocator, Value.makeU64(result));
            },
            .cast_u128 => {
                var v = try self.operand_stack.pop();
                defer v.deinit(allocator);
                const int = try IntegerValue.fromValue(v);
                const result = try IntegerValue.cast_u128(int);
                try self.operand_stack.push(allocator, Value.makeU128(result));
            },
            .cast_u256 => {
                var v = try self.operand_stack.pop();
                defer v.deinit(allocator);
                const int = try IntegerValue.fromValue(v);
                const result = try IntegerValue.cast_u256(int);
                try self.operand_stack.push(allocator, Value.makeU256(result));
            },

            // Abort
            .abort => {
                var v = try self.operand_stack.pop();
                defer v.deinit(allocator);
                const int = try IntegerValue.fromValue(v);
                self.last_abort_code = try int.cast_u64();
                return VMError.Aborted;
            },

            // Nop
            .nop => {},

            // Vector operations (simplified)
            .vec_pack => |vp| {
                if (vp.num > std.math.maxInt(u16)) return error.InvalidInstruction;
                const elems = try self.operand_stack.popn(allocator, @intCast(vp.num));
                defer {
                    for (elems) |*elem| elem.deinit(allocator);
                    allocator.free(elems);
                }
                const vec = try VectorValue.pack(allocator, elems, .{ .can_copy = true, .can_drop = true, .can_store = true, .is_key = false });
                try self.operand_stack.push(allocator, vec);
            },
            .vec_len => {
                var val = try self.operand_stack.pop();
                defer val.deinit(allocator);
                const len = try VectorValue.len(val);
                try self.operand_stack.push(allocator, Value.makeU64(@intCast(len)));
            },
            .vec_push_back => {
                var elem = try self.operand_stack.pop();
                defer elem.deinit(allocator);
                var vec_ref = try self.operand_stack.pop();
                defer vec_ref.deinit(allocator);
                try VectorValue.push_back(vec_ref, allocator, elem);
            },
            .vec_pop_back => {
                var vec_ref = try self.operand_stack.pop();
                defer vec_ref.deinit(allocator);
                const elem = try VectorValue.pop_back(vec_ref, allocator);
                try self.operand_stack.push(allocator, elem);
            },
            .vec_swap => {
                const idx2 = try self.operand_stack.popAs(u64);
                const idx1 = try self.operand_stack.popAs(u64);
                if (idx1 > std.math.maxInt(usize) or idx2 > std.math.maxInt(usize)) return error.IndexOutOfBounds;
                var vec_ref = try self.operand_stack.pop();
                defer vec_ref.deinit(allocator);
                try VectorValue.swap(vec_ref, @intCast(idx1), @intCast(idx2));
            },
            .vec_imm_borrow => |type_idx| {
                _ = type_idx;
                const idx = try self.operand_stack.popAs(u64);
                if (idx > std.math.maxInt(usize)) return error.IndexOutOfBounds;
                var vec_ref = try self.operand_stack.pop();
                defer vec_ref.deinit(allocator);
                const ref = try vec_ref.borrow_elem(@intCast(idx));
                try self.operand_stack.push(allocator, ref);
            },
            .vec_mut_borrow => |type_idx| {
                _ = type_idx;
                const idx = try self.operand_stack.popAs(u64);
                if (idx > std.math.maxInt(usize)) return error.IndexOutOfBounds;
                var vec_ref = try self.operand_stack.pop();
                defer vec_ref.deinit(allocator);
                const ref = try vec_ref.borrow_elem(@intCast(idx));
                try self.operand_stack.push(allocator, ref);
            },
            .vec_unpack => |vu| {
                if (vu.num > std.math.maxInt(usize)) return error.InvalidInstruction;
                var vec = try self.operand_stack.pop();
                if (vec.impl == .Container and vec.impl.Container.ref_count > 0) return error.InvalidReference;
                var elems = try VectorValue.unpack(vec, allocator, @intCast(vu.num));
                defer elems.deinit(allocator);
                for (elems.items) |elem| {
                    try self.operand_stack.push(allocator, elem);
                }
                vec.deinit(allocator);
            },

            // Field borrowing
            .mut_borrow_field, .mut_borrow_field_generic => |field_idx| {
                var val = try self.operand_stack.pop();
                defer val.deinit(allocator);
                const ref = try val.borrow_field(@intCast(field_idx));
                try self.operand_stack.push(allocator, ref);
            },
            .imm_borrow_field, .imm_borrow_field_generic => |field_idx| {
                var val = try self.operand_stack.pop();
                defer val.deinit(allocator);
                const ref = try val.borrow_field(@intCast(field_idx));
                try self.operand_stack.push(allocator, ref);
            },

            .move_to => |mt| {
                const store = self.storage orelse return error.MissingStorage;
                var resource = try self.operand_stack.pop();
                defer resource.deinit(allocator);
                if (!resource.isKey()) {
                    return error.InvalidResource;
                }
                var signer = try self.operand_stack.pop();
                defer signer.deinit(allocator);
                const addr = switch (signer.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{mt.type_});
                defer allocator.free(type_key);
                var resource_copy = try resource.copy_value(allocator);
                errdefer resource_copy.deinit(allocator);
                try store.setGlobal(addr_key, type_key, resource_copy);
            },
            .move_from => |mf| {
                const store = self.storage orelse return error.MissingStorage;
                var addr_val = try self.operand_stack.pop();
                defer addr_val.deinit(allocator);
                const addr = switch (addr_val.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{mf.type_});
                defer allocator.free(type_key);
                const stored = (try store.takeGlobal(addr_key, type_key)) orelse return error.TypeMismatch;
                try self.operand_stack.push(allocator, stored);
            },
            .exists => |ex| {
                const store = self.storage orelse return error.MissingStorage;
                var addr_val = try self.operand_stack.pop();
                defer addr_val.deinit(allocator);
                const addr = switch (addr_val.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{ex.type_});
                defer allocator.free(type_key);
                const exists_ = store.exists(addr_key, type_key);
                try self.operand_stack.push(allocator, Value.makeBool(exists_));
            },
            .mut_borrow_global => |bg| {
                const store = self.storage orelse return error.MissingStorage;
                var addr_val = try self.operand_stack.pop();
                defer addr_val.deinit(allocator);
                const addr = switch (addr_val.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{bg.type_});
                defer allocator.free(type_key);
                const stored = (try store.getGlobalPtr(addr_key, type_key)) orelse return error.InvalidReference;
                const container = switch (stored.impl) {
                    .Container => |c| c,
                    else => return error.TypeMismatch,
                };
                container.ref_count += 1;
                const addr_copy = try allocator.dupe(u8, addr_key);
                errdefer allocator.free(addr_copy);
                const type_copy = try allocator.dupe(u8, type_key);
                errdefer allocator.free(type_copy);
                try self.operand_stack.push(allocator, Value.init(.{ .ContainerRef = .{
                    .container = container,
                    .is_mutable = true,
                    .is_global = true,
                    .global_status = null,
                    .global_address = addr_copy,
                    .global_type_key = type_copy,
                } }));
            },
            .imm_borrow_global => |bg| {
                const store = self.storage orelse return error.MissingStorage;
                var addr_val = try self.operand_stack.pop();
                defer addr_val.deinit(allocator);
                const addr = switch (addr_val.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{bg.type_});
                defer allocator.free(type_key);
                const stored = (try store.getGlobalPtr(addr_key, type_key)) orelse return error.InvalidReference;
                const container = switch (stored.impl) {
                    .Container => |c| c,
                    else => return error.TypeMismatch,
                };
                container.ref_count += 1;
                const addr_copy = try allocator.dupe(u8, addr_key);
                errdefer allocator.free(addr_copy);
                const type_copy = try allocator.dupe(u8, type_key);
                errdefer allocator.free(type_copy);
                try self.operand_stack.push(allocator, Value.init(.{ .ContainerRef = .{
                    .container = container,
                    .is_mutable = false,
                    .is_global = true,
                    .global_status = null,
                    .global_address = addr_copy,
                    .global_type_key = type_copy,
                } }));
            },
            .move_to_generic => |mt| {
                const store = self.storage orelse return error.MissingStorage;
                var resource = try self.operand_stack.pop();
                defer resource.deinit(allocator);
                const info = try Self.resolveGenericStruct(frame.function, mt.type_instantiation);
                if (!info.abilities.is_key) {
                    return error.InvalidResource;
                }
                var signer = try self.operand_stack.pop();
                defer signer.deinit(allocator);
                const addr = switch (signer.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{mt.type_instantiation});
                defer allocator.free(type_key);
                const resource_copy = try resource.copy_value(allocator);
                try store.setGlobal(addr_key, type_key, resource_copy);
            },
            .move_from_generic => |mf| {
                const store = self.storage orelse return error.MissingStorage;
                var addr_val = try self.operand_stack.pop();
                defer addr_val.deinit(allocator);
                const addr = switch (addr_val.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{mf.type_instantiation});
                defer allocator.free(type_key);
                const stored = (try store.takeGlobal(addr_key, type_key)) orelse return error.TypeMismatch;
                try self.operand_stack.push(allocator, stored);
            },
            .exists_generic => |ex| {
                const store = self.storage orelse return error.MissingStorage;
                var addr_val = try self.operand_stack.pop();
                defer addr_val.deinit(allocator);
                const addr = switch (addr_val.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{ex.type_instantiation});
                defer allocator.free(type_key);
                const exists_ = store.exists(addr_key, type_key);
                try self.operand_stack.push(allocator, Value.makeBool(exists_));
            },
            .mut_borrow_global_generic => |bg| {
                const store = self.storage orelse return error.MissingStorage;
                var addr_val = try self.operand_stack.pop();
                defer addr_val.deinit(allocator);
                const addr = switch (addr_val.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{bg.type_instantiation});
                defer allocator.free(type_key);
                const stored = (try store.getGlobalPtr(addr_key, type_key)) orelse return error.InvalidReference;
                const container = switch (stored.impl) {
                    .Container => |c| c,
                    else => return error.TypeMismatch,
                };
                container.ref_count += 1;
                try self.operand_stack.push(allocator, Value.init(.{ .ContainerRef = .{
                    .container = container,
                    .is_mutable = true,
                    .is_global = true,
                    .global_status = null,
                } }));
            },
            .imm_borrow_global_generic => |bg| {
                const store = self.storage orelse return error.MissingStorage;
                var addr_val = try self.operand_stack.pop();
                defer addr_val.deinit(allocator);
                const addr = switch (addr_val.impl) {
                    .Address => |a| a,
                    else => return error.TypeMismatch,
                };
                const addr_hex = std.fmt.bytesToHex(addr, .lower);
                const addr_key = try std.fmt.allocPrint(allocator, "0x{s}", .{&addr_hex});
                defer allocator.free(addr_key);
                const type_key = try std.fmt.allocPrint(allocator, "type_{}", .{bg.type_instantiation});
                defer allocator.free(type_key);
                const stored = (try store.getGlobalPtr(addr_key, type_key)) orelse return error.InvalidReference;
                const container = switch (stored.impl) {
                    .Container => |c| c,
                    else => return error.TypeMismatch,
                };
                container.ref_count += 1;
                try self.operand_stack.push(allocator, Value.init(.{ .ContainerRef = .{
                    .container = container,
                    .is_mutable = false,
                    .is_global = true,
                    .global_status = null,
                } }));
            },
        }
        return .Ok;
    }

    fn binopInt(self: *Self, allocator: std.mem.Allocator, op: fn (IntegerValue, IntegerValue) VMError!IntegerValue) VMError!void {
        var b = try self.operand_stack.pop();
        defer b.deinit(allocator);
        var a = try self.operand_stack.pop();
        defer a.deinit(allocator);
        const rhs = try IntegerValue.fromValue(b);
        const lhs = try IntegerValue.fromValue(a);
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return error.TypeMismatch;
        const result = try op(lhs, rhs);
        try self.operand_stack.push(allocator, result.toValue());
    }

    fn cmpopInt(self: *Self, allocator: std.mem.Allocator, cmp: fn (IntegerValue, IntegerValue) VMError!bool) VMError!void {
        var b = try self.operand_stack.pop();
        defer b.deinit(allocator);
        var a = try self.operand_stack.pop();
        defer a.deinit(allocator);
        const rhs = try IntegerValue.fromValue(b);
        const lhs = try IntegerValue.fromValue(a);
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return error.TypeMismatch;
        const result = try cmp(lhs, rhs);
        try self.operand_stack.push(allocator, Value.makeBool(result));
    }
};

fn instructionGasCost(inst: bytecode.Instruction) u64 {
    return bytecode.instructionGasCost(inst);
}
