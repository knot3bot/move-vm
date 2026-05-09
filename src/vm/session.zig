const std = @import("std");
const values = @import("values.zig");
const Value = values.Value;
const bytecode = @import("bytecode.zig");
const module_mod = @import("module.zig");
const storage = @import("../storage/storage.zig");
const gas = @import("../gas/gas.zig");
const Gas = gas.Gas;
const interpreter = @import("interpreter.zig");
const types = @import("types.zig");
const Function = @import("frame.zig").Function;
const vm_loader = @import("loader.zig");
const native_mod = @import("native.zig");
const Event = native_mod.Event;

pub const Session = struct {
    allocator: std.mem.Allocator,
    storage: *storage.DataStore,
    module_cache: module_mod.ModuleCache,
    loader: *vm_loader.Loader,
    native_functions: *native_mod.NativeFunctions,
    gas_meter: Gas,
    events: std.ArrayList(Event),
    config: VMConfig,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        store: *storage.DataStore,
        loader: *vm_loader.Loader,
        natives: *native_mod.NativeFunctions,
        initial_gas: u64,
        config: VMConfig,
    ) Session {
        return .{
            .allocator = allocator,
            .storage = store,
            .module_cache = module_mod.ModuleCache.init(allocator),
            .loader = loader,
            .native_functions = natives,
            .gas_meter = Gas.init(initial_gas),
            .events = std.ArrayList(Event).empty,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.module_cache.deinit();
        for (self.events.items) |*evt| {
            self.allocator.free(evt.data);
        }
        self.events.deinit(self.allocator);
    }

    fn takeEvents(self: *Self) ![]Event {
        const slice = try self.events.toOwnedSlice(self.allocator);
        self.events = std.ArrayList(Event).empty;
        return slice;
    }

    pub fn getRemainingGas(self: Self) u64 {
        return self.gas_meter.getRemaining();
    }

    pub fn executeScript(
        self: *Self,
        script: *const Function,
        args: []Value,
    ) !ExecutionResult {
        var interp = interpreter.Interpreter.initWithConfig(self.allocator, self.config.max_stack_size, self.config.max_call_stack_depth, self.config.paranoid_type_checks);
        defer interp.deinit(self.allocator);
        interp.setStorage(self.storage);
        interp.setNativeFunctions(self.native_functions);
        interp.setEvents(&self.events);

        // Resolve module functions if script belongs to a loaded module
        const module_funcs = if (script.module.len > 0) blk: {
            const mod_id = types.ModuleId{
                .address = [_]u8{0} ** 32,
                .name = script.module,
            };
            break :blk (self.loader.getFunctions(mod_id) catch &.{}) orelse &.{};
        } else &[0]Function{};

        const inst_funcs = if (script.module.len > 0) blk: {
            const mod_id = types.ModuleId{
                .address = [_]u8{0} ** 32,
                .name = script.module,
            };
            break :blk (self.loader.getInstantiatedFunctions(mod_id) catch &.{}) orelse &.{};
        } else &[0]Function{};

        const inst_ty_args = if (script.module.len > 0) blk: {
            const mod_id = types.ModuleId{
                .address = [_]u8{0} ** 32,
                .name = script.module,
            };
            break :blk (self.loader.getInstantiatedFunctionTyArgs(mod_id) catch &.{}) orelse &.{};
        } else &[0][]types.Type{};

        interp.setInstantiatedFunctions(inst_funcs);
        interp.setInstantiatedFunctionTyArgs(inst_ty_args);
        interp.setLoader(self.loader);

        // Begin transaction for atomic execution
        try self.storage.beginTransaction();
        errdefer self.storage.rollbackTransaction() catch {};
        const prev_event_count = self.events.items.len;
        errdefer {
            // Rollback events emitted during this transaction
            while (self.events.items.len > prev_event_count) {
                if (self.events.pop()) |evt| {
                    self.allocator.free(evt.data);
                }
            }
        }

        const result = interp.executeFunction(
            self.allocator,
            script,
            module_funcs,
            &.{},
            args,
            &self.gas_meter,
        ) catch |err| {
            if (err == error.Aborted) {
                self.storage.rollbackTransaction() catch {};
                while (self.events.items.len > prev_event_count) {
                    if (self.events.pop()) |evt| {
                        self.allocator.free(evt.data);
                    }
                }
                return .{
                    .status = .Aborted,
                    .return_values = &.{},
                    .events = &.{},
                    .gas_used = self.gas_meter.getUsed(),
                    .abort_code = interp.last_abort_code,
                };
            }
            return err;
        };
        errdefer result.deinit(self.allocator);

        // Capture events before commit so OOM doesn't leave committed storage without events
        const events = try self.takeEvents();
        errdefer {
            for (events) |*evt| self.allocator.free(evt.data);
            self.allocator.free(events);
        }

        // Commit transaction on success
        try self.storage.commitTransaction();

        return .{
            .status = .Success,
            .return_values = result.values,
            .events = events,
            .gas_used = result.gas_used,
            .abort_code = null,
        };
    }

    pub fn executeFunction(
        self: *Self,
        module_id: types.ModuleId,
        function_name: []const u8,
        ty_args: []const types.Type,
        args: []Value,
    ) !ExecutionResult {
        const func = (try self.loader.getFunctionByName(module_id, function_name)) orelse {
            return .{
                .status = .FunctionNotFound,
                .return_values = &.{},
                .events = &.{},
                .gas_used = 0,
                .abort_code = null,
            };
        };

        const all_funcs = (try self.loader.getFunctions(module_id)) orelse &.{};
        const inst_funcs = (try self.loader.getInstantiatedFunctions(module_id)) orelse &.{};
        const inst_ty_args = (try self.loader.getInstantiatedFunctionTyArgs(module_id)) orelse &.{};

        var interp = interpreter.Interpreter.initWithConfig(self.allocator, self.config.max_stack_size, self.config.max_call_stack_depth, self.config.paranoid_type_checks);
        defer interp.deinit(self.allocator);
        interp.setStorage(self.storage);
        interp.setNativeFunctions(self.native_functions);
        interp.setEvents(&self.events);
        interp.setInstantiatedFunctions(inst_funcs);
        interp.setInstantiatedFunctionTyArgs(inst_ty_args);
        interp.setLoader(self.loader);

        try self.storage.beginTransaction();
        errdefer self.storage.rollbackTransaction() catch {};
        const prev_event_count = self.events.items.len;
        errdefer {
            while (self.events.items.len > prev_event_count) {
                if (self.events.pop()) |evt| {
                    self.allocator.free(evt.data);
                }
            }
        }

        const result = interp.executeFunction(
            self.allocator,
            func,
            all_funcs,
            ty_args,
            args,
            &self.gas_meter,
        ) catch |err| {
            if (err == error.Aborted) {
                self.storage.rollbackTransaction() catch {};
                while (self.events.items.len > prev_event_count) {
                    if (self.events.pop()) |evt| {
                        self.allocator.free(evt.data);
                    }
                }
                return .{
                    .status = .Aborted,
                    .return_values = &.{},
                    .events = &.{},
                    .gas_used = self.gas_meter.getUsed(),
                    .abort_code = interp.last_abort_code,
                };
            }
            return err;
        };
        errdefer result.deinit(self.allocator);

        const events = try self.takeEvents();
        errdefer {
            for (events) |*evt| self.allocator.free(evt.data);
            self.allocator.free(events);
        }

        try self.storage.commitTransaction();

        return .{
            .status = .Success,
            .return_values = result.values,
            .events = events,
            .gas_used = result.gas_used,
            .abort_code = null,
        };
    }

    pub fn publishModule(self: *Self, mod: *module_mod.Module) !void {
        try self.module_cache.addModule(mod);
        try self.loader.loadModule(mod);
    }
};

pub const ExecutionResult = struct {
    status: Status,
    return_values: []Value,
    events: []Event,
    gas_used: u64,
    abort_code: ?u64,

    pub fn deinit(self: ExecutionResult, allocator: std.mem.Allocator) void {
        for (self.return_values) |*val| {
            val.deinit(allocator);
        }
        allocator.free(self.return_values);
        for (self.events) |*evt| {
            allocator.free(evt.data);
        }
        allocator.free(self.events);
    }
};

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

pub const MoveVM = struct {
    allocator: std.mem.Allocator,
    config: VMConfig,
    loader: vm_loader.Loader,
    natives: native_mod.NativeFunctions,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) MoveVM {
        return .{
            .allocator = allocator,
            .config = VMConfig.default(),
            .loader = vm_loader.Loader.init(allocator),
            .natives = native_mod.NativeFunctions.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.loader.deinit();
        self.natives.deinit();
    }

    pub fn newSession(self: *Self, store: *storage.DataStore, initial_gas: u64) Session {
        return Session.init(self.allocator, store, &self.loader, &self.natives, initial_gas, self.config);
    }

    pub fn registerNative(self: *Self, module: []const u8, name: []const u8, func: native_mod.NativeFunc) !u16 {
        return self.natives.register(module, name, func);
    }
};

pub const VMConfig = struct {
    max_stack_size: u32 = 1024,
    max_call_stack_depth: u32 = 1024,
    paranoid_type_checks: bool = false,

    pub fn default() VMConfig {
        return .{};
    }
};
