const std = @import("std");
const frame = @import("frame.zig");

/// Native function interface
/// Reference: move-language/move/language/move-vm-types/src/natives/function.rs
/// Native function signature
pub const NativeFunc = fn (
    context: *NativeContext,
    type_args: []const frame.Type,
    args: []frame.Value,
) NativeResult;

/// Native function result
pub const NativeResult = union(enum) {
    /// Successful execution
    success: SuccessResult,
    /// Aborted with code
    abort: AbortResult,
    /// Out of gas
    out_of_gas: OutOfGasResult,
};

/// Success result
pub const SuccessResult = struct {
    /// Gas cost
    cost: u64,
    /// Return values
    return_values: []frame.Value,
};

/// Abort result
pub const AbortResult = struct {
    /// Gas cost
    cost: u64,
    /// Abort code
    abort_code: u64,
};

/// Out of gas result
pub const OutOfGasResult = struct {
    /// Partial gas cost used
    partial_cost: u64,
};

/// Native context - provides access to VM state
pub const NativeContext = struct {
    /// Associated VM
    vm: ?*anyopaque,
    /// Data store
    data_store: ?*anyopaque,
    /// Gas remaining
    gas_remaining: u64,
    /// Extensions
    extensions: NativeExtensions,
};

/// Native extensions - for extra context
pub const NativeExtensions = struct {
    /// Extension data
    data: std.StringHashMap(?*anyopaque),

    pub fn init(allocator: std.mem.Allocator) NativeExtensions {
        return .{
            .data = std.StringHashMap(?*anyopaque).init(allocator),
        };
    }

    pub fn deinit(self: *NativeExtensions) void {
        self.data.deinit();
    }

    /// Get an extension
    pub fn get(self: *NativeExtensions, key: []const u8) ?*anyopaque {
        return self.data.get(key) orelse null;
    }

    /// Add an extension
    pub fn add(self: *NativeExtensions, key: []const u8, value: ?*anyopaque) !void {
        try self.data.put(key, value);
    }
};

/// Native function table
pub const NativeFunctions = struct {
    /// Function table: module -> function_name -> NativeFunc
    functions: std.AutoHashMap(NativeFunctionKey, NativeFunc),

    pub fn init(allocator: std.mem.Allocator) NativeFunctions {
        return .{
            .functions = std.AutoHashMap(NativeFunctionKey, NativeFunc).init(allocator),
        };
    }

    /// Register a native function
    pub fn register(
        self: *NativeFunctions,
        module: []const u8,
        name: []const u8,
        func: NativeFunc,
    ) !void {
        const key = NativeFunctionKey{
            .module = module,
            .name = name,
        };
        try self.functions.put(key, func);
    }

    /// Look up a native function
    pub fn lookup(self: *NativeFunctions, module: []const u8, name: []const u8) ?NativeFunc {
        const key = NativeFunctionKey{
            .module = module,
            .name = name,
        };
        return self.functions.get(key);
    }

    pub fn deinit(self: *NativeFunctions) void {
        self.functions.deinit();
    }
};

/// Native function key
const NativeFunctionKey = struct {
    module: []const u8,
    name: []const u8,
};

/// Built-in native functions
pub const Builtins = struct {
    /// Initialize with default native functions
    pub fn init(allocator: std.mem.Allocator) !NativeFunctions {
        const funcs = NativeFunctions.init(allocator);

        // Register block (empty - real implementation would have crypto, etc.)
        // Example: try funcs.register("Std", "sha2_256", sha2_256);

        return funcs;
    }
};
