const std = @import("std");
const frame = @import("frame.zig");
const stack_mod = @import("stack.zig");
const gas = @import("../gas/gas.zig");
const storage = @import("../storage/storage.zig");

/// Move VM Interpreter
/// Reference: move-language/move/language/move-vm/runtime/src/interpreter.rs
pub const Interpreter = struct {
    /// Operand stack
    operand_stack: stack_mod.Stack,
    /// Call stack
    call_stack: std.ArrayList(frame.Frame),
    /// Gas meter
    gas_meter: gas.Gas,
    /// Data store
    data_store: *storage.Storage,
    /// Whether to do paranoid type checks
    paranoid_type_checks: bool,

    const Self = @This();

    /// Create a new interpreter
    pub fn init(allocator: std.mem.Allocator, initial_gas: u64, data_store: *storage.Storage) Self {
        return .{
            .operand_stack = stack_mod.Stack.init(allocator),
            .call_stack = std.ArrayList(frame.Frame).init(allocator),
            .gas_meter = gas.Gas.init(initial_gas),
            .data_store = data_store,
            .paranoid_type_checks = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.operand_stack.deinit();
        for (self.call_stack.items) |*f| {
            f.deinit();
        }
        self.call_stack.deinit();
    }

    /// Execute a function with arguments
    pub fn executeFunction(
        self: *Self,
        func: *const frame.Function,
        args: []frame.Value,
    ) !ExecutionResult {
        // Initialize locals from args
        var frame_locals = std.ArrayList(frame.Local).init(self.call_stack.allocator);
        try frame_locals.resize(func.local_count);

        // Copy args to locals
        for (args, 0..) |arg, i| {
            frame_locals.items[i] = .{ .value = arg, .is_mutable = true };
        }

        // Create initial frame
        var call_frame = frame.Frame.init(self.call_stack.allocator, func.local_count);
        call_frame.function = func;
        call_frame.pc = 0;

        // Copy locals
        for (frame_locals.items, 0..) |local, i| {
            call_frame.setLocal(@intCast(i), local.value);
        }
        frame_locals.deinit();

        try self.call_stack.append(call_frame);

        // Main execution loop
        return self.executeLoop();
    }

    /// Main execution loop
    fn executeLoop(self: *Self) !ExecutionResult {
        while (self.call_stack.items.len > 0) {
            const frame_idx = self.call_stack.items.len - 1;
            var current_frame = &self.call_stack.items[frame_idx];

            if (current_frame.function) |func| {
                if (current_frame.pc >= func.code.items.len) {
                    // Function ended, pop frame
                    const returned_frame = self.call_stack.pop();
                    if (returned_frame.function) |ret_func| {
                        if (ret_func.return_count > 0) {
                            // Return values are on stack, handled by caller
                        }
                    }
                    continue;
                }

                const inst = func.code.items[current_frame.pc];
                try self.gas_meter.consume(1); // Basic instruction cost

                try self.executeInstruction(inst, current_frame);
                current_frame.pc += 1;
            } else {
                // No function, error
                return error.NoFunctionInFrame;
            }
        }

        // Execution completed, return values from stack
        const results: []frame.Value = &.{};
        return .{ .values = results, .gas_used = self.gas_meter.getInitial() - self.gas_meter.getRemaining() };
    }

    /// Execute a single instruction
    fn executeInstruction(self: *Self, inst: frame.Instruction, frame_ref: *frame.Frame) !void {
        switch (inst) {
            // Stack operations
            .pop => {
                _ = try self.operand_stack.pop();
            },
            .ret => |ret| {
                // Return handling - pop call frame
                _ = ret;
                // Values remain on stack for caller
            },

            // Local operations
            .ld_loc => |idx| {
                const val = frame_ref.getLocal(idx) orelse return error.InvalidLocal;
                try self.operand_stack.push(val);
            },
            .st_loc => |idx| {
                const val = try self.operand_stack.pop();
                frame_ref.setLocal(idx, val);
            },
            .ld_const => |ld_const| {
                _ = ld_const; // Would load from constant pool
                try self.operand_stack.push(.{ .U64 = 0 });
            },

            // Arithmetic
            .add => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a + b;
                }
            }.f),
            .sub => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a - b;
                }
            }.f),
            .mul => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a * b;
                }
            }.f),
            .div => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a / b;
                }
            }.f),
            .mod => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a % b;
                }
            }.f),
            .bit_and => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a & b;
                }
            }.f),
            .bit_or => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a | b;
                }
            }.f),
            .bit_xor => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a ^ b;
                }
            }.f),
            .shl => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a << b;
                }
            }.f),
            .shr => try self.binopInt(u64, struct {
                fn f(a: u64, b: u64) u64 {
                    return a >> b;
                }
            }.f),

            // Comparison
            .lt => try self.cmpopInt(u64, struct {
                fn f(a: u64, b: u64) bool {
                    return a < b;
                }
            }.f),
            .gt => try self.cmpopInt(u64, struct {
                fn f(a: u64, b: u64) bool {
                    return a > b;
                }
            }.f),
            .le => try self.cmpopInt(u64, struct {
                fn f(a: u64, b: u64) bool {
                    return a <= b;
                }
            }.f),
            .ge => try self.cmpopInt(u64, struct {
                fn f(a: u64, b: u64) bool {
                    return a >= b;
                }
            }.f),
            .eq => try self.cmpop(u64, struct {
                fn f(a: frame.Value, b: frame.Value) bool {
                    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
                }
            }.f),
            .neq => try self.cmpop(u64, struct {
                fn f(a: frame.Value, b: frame.Value) bool {
                    return !std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
                }
            }.f),

            // Control flow
            .br_true => |target| {
                const cond = try self.operand_stack.pop();
                if (cond.Bool) {
                    frame_ref.pc = target;
                }
            },
            .br_false => |target| {
                const cond = try self.operand_stack.pop();
                if (!cond.Bool) {
                    frame_ref.pc = target;
                }
            },
            .branch => |target| {
                frame_ref.pc = target;
            },
            .call => |call| {
                _ = call; // Would create new frame
            },
            .call_generic => |call| {
                _ = call; // Would create new frame with type instantiation
            },

            // Pack/Unpack
            .pack => |n| {
                _ = n; // Would create struct with n fields
                try self.operand_stack.push(.{ .Struct = undefined });
            },
            .unpack => |n| {
                _ = n; // Would unpack struct
            },

            // Reference operations
            .read_ref => {
                const ref_val = try self.operand_stack.pop();
                switch (ref_val) {
                    .Reference, .MutableReference => |r| {
                        try self.operand_stack.push(r.value.*);
                    },
                    else => return error.InvalidReference,
                }
            },
            .write_ref => {
                const new_val = try self.operand_stack.pop();
                const ref_val = try self.operand_stack.pop();
                switch (ref_val) {
                    .MutableReference => |r| {
                        r.value.* = new_val;
                    },
                    else => return error.InvalidReference,
                }
            },
            .copy_loc => |idx| {
                const val = frame_ref.getLocal(idx) orelse return error.InvalidLocal;
                if (!val.canCopy()) return error.CopyResource;
                try self.operand_stack.push(val);
            },
            .move_loc => |idx| {
                const val = frame_ref.getLocal(idx) orelse return error.InvalidLocal;
                frame_ref.setLocal(idx, .Invalid);
                try self.operand_stack.push(val);
            },

            // Global operations
            .move_to => |mt| {
                _ = mt;
                // Would move value to global storage
            },
            .move_from => |mf| {
                _ = mf;
                // Would load from global storage
                try self.operand_stack.push(.{.Invalid});
            },
            .exists => |ex| {
                _ = ex;
                // Would check if global exists
                try self.operand_stack.push(.{ .Bool = false });
            },

            // Borrow global
            .borrow_global => |bg| {
                _ = bg;
                // Would borrow global
                try self.operand_stack.push(.{ .Reference = undefined });
            },
            .borrow_global_generic => |bg| {
                _ = bg;
                try self.operand_stack.push(.{ .Reference = undefined });
            },

            // Cast
            .cast => |ct| {
                _ = ct;
                // Type conversion
            },

            // Abort
            .abort => {
                return error.Aborted;
            },

            // Nop
            .nop => {},

            // Freeze reference (make immutable)
            .freeze_ref => {
                const ref_val = try self.operand_stack.pop();
                if (ref_val == .MutableReference) {
                    try self.operand_stack.push(.{ .Reference = ref_val.MutableReference });
                }
            },

            .move_to_generic, .move_from_generic, .exists_generic => {
                // Generic versions - would handle type instantiation
            },
            .move_to_generic => {},
            .move_from_generic => {},
            .exists_generic => {},
            .ld_const, .move_to_generic, .move_from_generic, .exists_generic => {},
        }
    }

    /// Binary operation for integers
    fn binopInt(self: *Self, comptime T: type, op: fn (T, T) T) !void {
        const b = try self.operand_stack.pop();
        const a = try self.operand_stack.pop();

        const a_val: T = switch (a) {
            .U8 => @as(T, a.U8),
            .U16 => @as(T, a.U16),
            .U32 => @as(T, a.U32),
            .U64 => @as(T, a.U64),
            .U128 => @as(T, a.U128),
            .U256 => @as(T, a.U256),
            else => return error.TypeMismatch,
        };

        const b_val: T = switch (b) {
            .U8 => @as(T, b.U8),
            .U16 => @as(T, b.U16),
            .U32 => @as(T, b.U32),
            .U64 => @as(T, b.U64),
            .U128 => @as(T, b.U128),
            .U256 => @as(T, b.U256),
            else => return error.TypeMismatch,
        };

        const result = op(a_val, b_val);
        try self.operand_stack.push(.{ .U64 = result });
    }

    /// Comparison for integers (returns bool)
    fn cmpopInt(self: *Self, comptime T: type, cmp: fn (T, T) bool) !void {
        const b = try self.operand_stack.pop();
        const a = try self.operand_stack.pop();

        const a_val: T = switch (a) {
            .U64 => a.U64,
            else => return error.TypeMismatch,
        };
        const b_val: T = switch (b) {
            .U64 => b.U64,
            else => return error.TypeMismatch,
        };

        try self.operand_stack.push(.{ .Bool = cmp(a_val, b_val) });
    }

    /// Equality comparison
    fn cmpop(self: *Self, comptime T: type, cmp: fn (T, T) bool) !void {
        const b = try self.operand_stack.pop();
        const a = try self.operand_stack.pop();
        try self.operand_stack.push(.{ .Bool = cmp(a, b) });
    }
};

/// Execution result
pub const ExecutionResult = struct {
    values: []frame.Value,
    gas_used: u64,
};

/// VM Errors
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
};
