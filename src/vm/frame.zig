const std = @import("std");
const bytecode = @import("bytecode.zig");
const locals_mod = @import("locals.zig");
const types = @import("types.zig");
const module_mod = @import("module.zig");

/// Function definition
pub const Function = struct {
    name: []const u8,
    module: []const u8,
    module_address: [32]u8 = [_]u8{0} ** 32,
    param_count: u8,
    return_count: u8,
    local_count: u8,
    is_native: bool,
    native_idx: ?u16,
    code: bytecode.Bytecode,
    param_types: std.ArrayList(types.Type),
    return_types: std.ArrayList(types.Type),
    type_params: std.ArrayList(types.TypeParameter),
    // Module context for generic operations, constants, and cross-module calls (references, not owned)
    struct_defs: []const module_mod.StructDef = &.{},
    type_signatures: []const module_mod.TypeSignature = &.{},
    struct_instantiations: []const module_mod.StructDefInstantiation = &.{},
    constants: []const module_mod.Constant = &.{},
    function_handles: []const module_mod.FunctionHandle = &.{},
    resolved_handles: []const ?*Function = &.{},
    resolved_struct_field_types: []const types.ResolvedStructFieldTypes = &.{},

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Function {
        return .{
            .name = name,
            .module = "",
            .module_address = [_]u8{0} ** 32,
            .param_count = 0,
            .return_count = 0,
            .local_count = 0,
            .is_native = false,
            .native_idx = null,
            .code = bytecode.Bytecode.init(allocator),
            .param_types = std.ArrayList(types.Type).empty,
            .return_types = std.ArrayList(types.Type).empty,
            .type_params = std.ArrayList(types.TypeParameter).empty,
        };
    }

    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        for (self.param_types.items) |*ty| {
            ty.deinit(allocator);
        }
        self.param_types.deinit(allocator);
        for (self.return_types.items) |*ty| {
            ty.deinit(allocator);
        }
        self.return_types.deinit(allocator);
        self.type_params.deinit(allocator);
    }
};

/// Execution frame
pub const Frame = struct {
    pc: u16,
    locals: locals_mod.Locals,
    function: *const Function,
    ty_args: []const types.Type,

    pub fn init(locals: locals_mod.Locals, function: *const Function, ty_args: []const types.Type) Frame {
        return .{
            .pc = 0,
            .locals = locals,
            .function = function,
            .ty_args = ty_args,
        };
    }

    pub fn location(self: Frame) types.Location {
        return .{ .Module = .{
            .address = self.function.module_address,
            .name = self.function.module,
        } };
    }
};

/// Type parameter
pub const TypeParameter = struct {
    name: []const u8,
    constraints: types.AbilitySet,
};
