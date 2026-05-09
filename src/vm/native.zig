const std = @import("std");
const values = @import("values.zig");
const Value = values.Value;
const types = @import("types.zig");

pub const NativeResult = struct {
    cost: u64,
    values: []Value,
    is_abort: bool = false,
    abort_code: u64 = 0,
};

pub const Event = struct {
    type_id: u64,
    data: []const u8,
};

pub const NativeContext = struct {
    gas_remaining: u64,
    events: ?*std.ArrayList(Event) = null,
};

pub const NativeError = error{
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
    OutOfMemory,
};

pub const NativeFunc = *const fn (
    allocator: std.mem.Allocator,
    ctx: *NativeContext,
    ty_args: []const types.Type,
    args: []Value,
) NativeError!NativeResult;

pub const NativeFunctions = struct {
    functions: std.StringHashMap(u16),
    funcs: std.ArrayList(NativeFunc),

    pub fn init(allocator: std.mem.Allocator) NativeFunctions {
        return .{
            .functions = std.StringHashMap(u16).init(allocator),
            .funcs = std.ArrayList(NativeFunc).empty,
        };
    }

    pub fn register(self: *NativeFunctions, module: []const u8, name: []const u8, func: NativeFunc) !u16 {
        const key = try std.fmt.allocPrint(self.functions.allocator, "{s}::{s}", .{ module, name });
        errdefer self.functions.allocator.free(key);
        const idx: u16 = @intCast(self.funcs.items.len);
        try self.funcs.append(self.functions.allocator, func);
        try self.functions.put(key, idx);
        return idx;
    }

    pub fn lookup(self: NativeFunctions, module: []const u8, name: []const u8) ?NativeFunc {
        const key = std.fmt.allocPrint(self.functions.allocator, "{s}::{s}", .{ module, name }) catch return null;
        defer self.functions.allocator.free(key);
        const idx = self.functions.get(key) orelse return null;
        return self.funcs.items[idx];
    }

    pub fn lookupByIdx(self: NativeFunctions, idx: u16) ?NativeFunc {
        if (idx >= self.funcs.items.len) return null;
        return self.funcs.items[idx];
    }

    pub fn deinit(self: *NativeFunctions) void {
        const allocator = self.functions.allocator;
        var it = self.functions.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.functions.deinit();
        self.funcs.deinit(allocator);
    }
};

// ==================== Built-in Native Functions ====================

/// Native add: args[0] (u64) + args[1] (u64) -> u64
pub fn nativeAdd(
    allocator: std.mem.Allocator,
    ctx: *NativeContext,
    ty_args: []const types.Type,
    args: []Value,
) NativeError!NativeResult {
    _ = ctx;
    _ = ty_args;
    if (args.len != 2) return error.TypeMismatch;
    const a = switch (args[0].impl) {
        .U64 => |v| v,
        else => return error.TypeMismatch,
    };
    const b = switch (args[1].impl) {
        .U64 => |v| v,
        else => return error.TypeMismatch,
    };
    const result = try std.math.add(u64, a, b);
    var vals = try allocator.alloc(Value, 1);
    vals[0] = Value.makeU64(result);
    return .{ .cost = 1, .values = vals };
}

/// Native signer borrow_address: args[0] (Address) -> Address
pub fn nativeSignerBorrowAddress(
    allocator: std.mem.Allocator,
    ctx: *NativeContext,
    ty_args: []const types.Type,
    args: []Value,
) NativeError!NativeResult {
    _ = ctx;
    _ = ty_args;
    if (args.len != 1) return error.TypeMismatch;
    const addr = switch (args[0].impl) {
        .Address => |v| v,
        else => return error.TypeMismatch,
    };
    var vals = try allocator.alloc(Value, 1);
    vals[0] = Value.address(addr);
    return .{ .cost = 1, .values = vals };
}

/// Native SHA3-256: args[0] (VectorU8) -> VectorU8 (32 bytes)
pub fn nativeSha3_256(
    allocator: std.mem.Allocator,
    ctx: *NativeContext,
    ty_args: []const types.Type,
    args: []Value,
) NativeError!NativeResult {
    _ = ctx;
    _ = ty_args;
    if (args.len != 1) return error.TypeMismatch;

    const container = switch (args[0].impl) {
        .Container => |c| c,
        else => return error.TypeMismatch,
    };
    if (container.kind != .Vec) return error.TypeMismatch;

    var input = try allocator.alloc(u8, container.data.items.len);
    defer allocator.free(input);
    for (container.data.items, 0..) |item, i| {
        input[i] = switch (item) {
            .U8 => |v| v,
            else => return error.TypeMismatch,
        };
    }

    var hash: [32]u8 = undefined;
    const Sha3_256 = std.crypto.hash.sha3.Sha3_256;
    Sha3_256.hash(input, &hash, .{});

    var result = try values.Container.new(allocator, .Vec);
    for (hash) |b| {
        try result.data.append(allocator, .{ .U8 = b });
    }

    var vals = try allocator.alloc(Value, 1);
    vals[0] = Value.init(.{ .Container = result });
    return .{ .cost = 10, .values = vals };
}

/// Native BCS to_bytes: args[0] (primitive) -> VectorU8
pub fn nativeBcsToBytes(
    allocator: std.mem.Allocator,
    ctx: *NativeContext,
    ty_args: []const types.Type,
    args: []Value,
) NativeError!NativeResult {
    _ = ctx;
    _ = ty_args;
    if (args.len != 1) return error.TypeMismatch;

    var result = try values.Container.newWithAbilities(allocator, .Vec, .{
        .can_copy = true,
        .can_drop = true,
        .can_store = true,
        .is_key = false,
    });

    switch (args[0].impl) {
        .U8 => |v| try result.data.append(allocator, .{ .U8 = v }),
        .U16 => |v| {
            const bytes = std.mem.asBytes(&v);
            for (bytes) |b| try result.data.append(allocator, .{ .U8 = b });
        },
        .U32 => |v| {
            const bytes = std.mem.asBytes(&v);
            for (bytes) |b| try result.data.append(allocator, .{ .U8 = b });
        },
        .U64 => |v| {
            const bytes = std.mem.asBytes(&v);
            for (bytes) |b| try result.data.append(allocator, .{ .U8 = b });
        },
        .U128 => |v| {
            const bytes = std.mem.asBytes(&v);
            for (bytes) |b| try result.data.append(allocator, .{ .U8 = b });
        },
        .Bool => |v| {
            try result.data.append(allocator, .{ .U8 = if (v) 1 else 0 });
        },
        .Address => |v| {
            for (v) |b| try result.data.append(allocator, .{ .U8 = b });
        },
        else => return error.TypeMismatch,
    }

    var vals = try allocator.alloc(Value, 1);
    vals[0] = Value.init(.{ .Container = result });
    return .{ .cost = 5, .values = vals };
}

/// Native event emit: args[0] (u64) -> void
pub fn nativeEventEmit(
    allocator: std.mem.Allocator,
    ctx: *NativeContext,
    ty_args: []const types.Type,
    args: []Value,
) NativeError!NativeResult {
    _ = ty_args;
    if (args.len != 1) return error.TypeMismatch;

    const val = switch (args[0].impl) {
        .U64 => |v| v,
        else => return error.TypeMismatch,
    };

    if (ctx.events) |events| {
        const data = try allocator.dupe(u8, std.mem.asBytes(&val));
        errdefer allocator.free(data);
        try events.append(allocator, .{ .type_id = val, .data = data });
    }

    return .{ .cost = 1, .values = &.{} };
}

/// Native assert: args[0] (bool) -> void, aborts if false
pub fn nativeAssert(
    allocator: std.mem.Allocator,
    ctx: *NativeContext,
    ty_args: []const types.Type,
    args: []Value,
) NativeError!NativeResult {
    _ = ctx;
    _ = ty_args;
    _ = allocator;
    if (args.len != 1) return error.TypeMismatch;
    const cond = switch (args[0].impl) {
        .Bool => |v| v,
        else => return error.TypeMismatch,
    };
    if (!cond) {
        return .{ .cost = 1, .values = &.{}, .is_abort = true, .abort_code = 0x10001 };
    }
    return .{ .cost = 1, .values = &.{} };
}

/// Native vector_empty: ty_args[0] (element type) -> Vector
pub fn nativeVectorEmpty(
    allocator: std.mem.Allocator,
    ctx: *NativeContext,
    ty_args: []const types.Type,
    args: []Value,
) NativeError!NativeResult {
    _ = ctx;
    _ = args;
    const container = try values.Container.newWithAbilities(allocator, .Vec, .{
        .can_copy = true,
        .can_drop = true,
        .can_store = true,
        .is_key = false,
    });
    _ = ty_args;

    var vals = try allocator.alloc(Value, 1);
    vals[0] = Value.init(.{ .Container = container });
    return .{ .cost = 1, .values = vals };
}
