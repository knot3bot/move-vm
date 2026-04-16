const std = @import("std");
const frame = @import("frame.zig");
const bytecode = @import("bytecode.zig");
const module_mod = @import("module.zig");
const storage = @import("../storage/storage.zig");
const gas = @import("../gas/gas.zig");
const interpreter = @import("interpreter.zig");

/// VM Session - executes transactions
/// Reference: move-language/move/language/move-vm/runtime/src/session.rs
pub const Session = struct {
    allocator: std.mem.Allocator,
    /// Storage interface
    storage: *storage.Storage,
    /// Module cache
    module_cache: module_mod.ModuleCache,
    /// Gas meter
    gas_meter: gas.Gas,
    /// Events emitted during execution (placeholder)
    events: []const u8,
    /// Return values from last execution (placeholder)
    return_values: []frame.Value,
    /// Whether session is valid
    valid: bool,

    const Self = @This();

    /// Create a new session
    pub fn init(allocator: std.mem.Allocator, store: *storage.Storage, initial_gas: u64) Self {
        return .{
            .allocator = allocator,
            .storage = store,
            .module_cache = module_mod.ModuleCache.init(allocator),
            .gas_meter = gas.Gas.init(initial_gas),
            .events = &.{},
            .return_values = &.{},
            .valid = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.module_cache.deinit(self.allocator);
        self.valid = false;
    }

    /// Helper to get remaining gas
    pub fn getRemainingGas(self: Self) u64 {
        return self.gas_meter.getRemaining();
    }

    /// Execute a Move script (entry point)
    pub fn executeScript(
        self: *Self,
        script: *const module_mod.FunctionDef,
        args: []frame.Value,
    ) !ExecutionResult {
        // Create interpreter
        var interp = interpreter.Interpreter.init(
            self.allocator,
            self.gas_meter.getRemaining(),
            self.storage,
        );
        defer interp.deinit();

        // Execute the function
        const result = try interp.executeFunction(
            &self.scriptToFunction(script),
            args,
        );

        // Copy return values
        self.return_values.clearRetainingCapacity();
        try self.return_values.appendSlice(result.values);

        return .{
            .status = .Success,
            .return_values = self.return_values.items,
            .events = self.events.items,
            .gas_used = result.gas_used,
        };
    }

    /// Execute a function in a module
    pub fn executeFunction(
        self: *Self,
        module_id: *const module_mod.ModuleId,
        function_name: []const u8,
        type_args: []const frame.Type,
        args: []frame.Value,
    ) !ExecutionResult {
        _ = type_args; // Not yet implemented
        // Find the module
        const mod = self.module_cache.getModule(module_id) orelse {
            return error.ModuleNotFound;
        };

        // Find the function
        const func = self.findFunction(mod, function_name) orelse {
            return error.FunctionNotFound;
        };

        return self.executeScript(&func, args);
    }

    /// Publish a module to storage
    pub fn publishModule(self: *Self, module: *module_mod.Module) !void {
        // Validate module (basic checks)
        try self.validateModule(module);

        // Store in module cache
        try self.module_cache.addModule(module);
    }

    /// Validate a module
    fn validateModule(self: *Self, module: *module_mod.Module) !void {
        _ = self;
        // Basic validation - check struct abilities
        for (module.struct_defs.items) |struct_def| {
            // Resources must have key ability
            for (struct_def.fields.items) |field| {
                if (field.type_signature == .Signer and !struct_def.abilities.is_key) {
                    return error.InvalidResource;
                }
            }
        }
    }

    /// Find a function by name in a module
    fn findFunction(self: *Self, module: *module_mod.Module, name: []const u8) ?module_mod.FunctionDef {
        _ = self;
        for (module.function_defs.items) |func_def| {
            if (module.getFunction(func_def.handle)) |handle| {
                if (std.mem.eql(u8, handle.name, name)) {
                    return func_def;
                }
            }
        }
        return null;
    }

    /// Convert script FunctionDef to Function for interpreter
    fn scriptToFunction(self: *Self, script: *const module_mod.FunctionDef) frame.Function {
        var func = frame.Function.init(self.allocator, "script");
        func.param_count = script.params;
        func.return_count = script.returns;
        func.local_count = script.params + script.returns;
        func.is_native = script.is_native;
        func.code = script.code;
        return func;
    }
};

/// Execution result
pub const ExecutionResult = struct {
    status: Status,
    /// Return values from execution
    return_values: []frame.Value,
    /// Events emitted
    events: []Event,
    /// Gas used
    gas_used: u64,
};

/// Execution status
pub const Status = enum {
    Success,
    Aborted,
    OutOfGas,
    ExecutionFailure,
    ModuleNotFound,
    FunctionNotFound,
    TypeError,
    InvalidResource,
};

/// Event emitted during execution
pub const Event = struct {
    /// Event type (0 = burn, 1 = mint, etc.)
    type_id: u64,
    /// Event data
    data: []const u8,
};

/// Move VM - main entry point
/// Reference: move-language/move/language/move-vm/runtime/src/move_vm.rs
pub const MoveVM = struct {
    allocator: std.mem.Allocator,
    /// VM config
    config: VMConfig,

    const Self = @This();

    /// Create a new Move VM
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .config = VMConfig.default(),
        };
    }

    /// Create a new session
    pub fn newSession(self: *Self, store: *storage.Storage, initial_gas: u64) Session {
        return Session.init(self.allocator, store, initial_gas);
    }

    /// Deinitialize
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// VM Configuration
pub const VMConfig = struct {
    /// Gas schedule (use default)
    use_native_gas_schedule: bool = true,
    /// Maximum stack size
    max_stack_size: u32 = 1024,
    /// Maximum call stack depth
    max_call_stack_depth: u32 = 1024,
    /// Enable paranoid type checks (debug)
    paranoid_type_checks: bool = false,

    pub fn default() VMConfig {
        return .{};
    }
};
