const std = @import("std");
const types = @import("types.zig");
const bytecode = @import("bytecode.zig");

pub const Module = struct {
    id: types.ModuleId,
    functions: std.ArrayList(FunctionHandle),
    function_instantiations: std.ArrayList(FunctionInstantiation),
    type_signatures: std.ArrayList(TypeSignature),
    structs: std.ArrayList(StructDef),
    constants: std.ArrayList(Constant),
    struct_defs: std.ArrayList(StructDef),
    struct_instantiations: std.ArrayList(StructDefInstantiation),
    function_defs: std.ArrayList(FunctionDef),

    pub fn init(allocator: std.mem.Allocator) Module {
        _ = allocator;
        return .{
            .id = undefined,
            .functions = std.ArrayList(FunctionHandle).empty,
            .function_instantiations = std.ArrayList(FunctionInstantiation).empty,
            .type_signatures = std.ArrayList(TypeSignature).empty,
            .structs = std.ArrayList(StructDef).empty,
            .constants = std.ArrayList(Constant).empty,
            .struct_defs = std.ArrayList(StructDef).empty,
            .struct_instantiations = std.ArrayList(StructDefInstantiation).empty,
            .function_defs = std.ArrayList(FunctionDef).empty,
        };
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        for (self.function_defs.items) |*def| {
            def.deinit(allocator);
        }
        for (self.struct_defs.items) |*def| {
            def.deinit(allocator);
        }
        for (self.constants.items) |*c| {
            allocator.free(c.data);
        }
        self.functions.deinit(allocator);
        self.function_instantiations.deinit(allocator);
        self.type_signatures.deinit(allocator);
        self.structs.deinit(allocator);
        self.constants.deinit(allocator);
        self.struct_defs.deinit(allocator);
        self.struct_instantiations.deinit(allocator);
        self.function_defs.deinit(allocator);
    }
};

pub const Constant = struct {
    type_signature: TypeSignature,
    data: []const u8,
};

pub const FunctionHandle = struct {
    module: types.ModuleId,
    name: []const u8,
    param_types: []const u16,
    return_types: []const u16,
    is_native: bool,
};

pub const FunctionInstantiation = struct {
    handle: u16,
    type_args: []const u16,
};

pub const TypeSignature = union(enum) {
    Bool,
    U8,
    U16,
    U32,
    U64,
    U128,
    U256,
    Address,
    Signer,
    Vector: u16,
    Struct: u16,
    Reference: u16,
    MutableReference: u16,
    TypeParameter: u16,
};

pub const StructDef = struct {
    name: []const u8,
    type_params: []const types.TypeParameter,
    fields: std.ArrayList(FieldDef),
    abilities: types.AbilitySet,

    pub fn deinit(self: *StructDef, allocator: std.mem.Allocator) void {
        self.fields.deinit(allocator);
    }
};

pub const FieldDef = struct {
    name: []const u8,
    type_signature: TypeSignature,
};

pub const StructDefInstantiation = struct {
    def: u16,
    type_args: []const u16,
};

pub const FunctionDef = struct {
    handle: u16,
    visibility: Visibility,
    type_params: []const types.TypeParameter,
    params: u8,
    returns: u8,
    local_count: u8,
    code: bytecode.Bytecode,
    is_native: bool,

    pub fn deinit(self: *FunctionDef, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
    }
};

pub const Visibility = enum {
    Private,
    Public,
    Script,
};

pub const ModuleCache = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*Module),

    pub fn init(allocator: std.mem.Allocator) ModuleCache {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
        };
    }

    pub fn getModule(self: *ModuleCache, id: *const types.ModuleId) ?*Module {
        const id_str = id.toString(self.allocator) catch return null;
        defer self.allocator.free(id_str);
        return self.modules.get(id_str);
    }

    pub fn addModule(self: *ModuleCache, module: *Module) !void {
        const id_str = try module.id.toString(self.allocator);
        defer self.allocator.free(id_str);
        const id_copy = try self.allocator.dupe(u8, id_str);
        errdefer self.allocator.free(id_copy);
        try self.modules.put(id_copy, module);
    }

    pub fn deinit(self: *ModuleCache) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.modules.deinit();
    }
};
