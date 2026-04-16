const std = @import("std");
const frame = @import("frame.zig");
const bytecode = @import("bytecode.zig");

/// Move Module definition
/// Reference: move-language/move/language/move-binary-format/src/file_format.rs
pub const Module = struct {
    /// Module ID
    id: ModuleId,
    /// Function handles
    functions: std.ArrayList(FunctionHandle),
    /// Function instantiations (for generics)
    function_instantiations: std.ArrayList(FunctionInstantiation),
    /// Type signatures
    type_signatures: std.ArrayList(TypeSignature),
    /// Struct definitions
    structs: std.ArrayList(StructDef),
    /// Constant pool
    constants: std.ArrayList(frame.Value),
    /// Field definitions for structs
    struct_defs: std.ArrayList(StructDef),
    /// Function definitions (code)
    function_defs: std.ArrayList(FunctionDef),

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{
            .id = undefined,
            .functions = std.ArrayList(FunctionHandle).init(allocator),
            .function_instantiations = std.ArrayList(FunctionInstantiation).init(allocator),
            .type_signatures = std.ArrayList(TypeSignature).init(allocator),
            .structs = std.ArrayList(StructDef).init(allocator),
            .constants = std.ArrayList(frame.Value).init(allocator),
            .struct_defs = std.ArrayList(StructDef).init(allocator),
            .function_defs = std.ArrayList(FunctionDef).init(allocator),
        };
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.functions.deinit(allocator);
        self.function_instantiations.deinit(allocator);
        self.type_signatures.deinit(allocator);
        self.structs.deinit(allocator);
        self.constants.deinit(allocator);
        self.struct_defs.deinit(allocator);
        self.function_defs.deinit(allocator);
    }

    /// Get function by handle index
    pub fn getFunction(self: *Module, idx: u16) ?*FunctionHandle {
        if (idx < self.functions.items.len) {
            return &self.functions.items[idx];
        }
        return null;
    }

    /// Get function definition by index
    pub fn getFunctionDef(self: *Module, idx: u16) ?*FunctionDef {
        if (idx < self.function_defs.items.len) {
            return &self.function_defs.items[idx];
        }
        return null;
    }

    /// Get struct definition by index
    pub fn getStructDef(self: *Module, idx: u16) ?*StructDef {
        if (idx < self.struct_defs.items.len) {
            return &self.struct_defs.items[idx];
        }
        return null;
    }
};

/// Module ID (address + name)
pub const ModuleId = struct {
    address: [32]u8,
    name: []const u8,

    pub fn toString(self: ModuleId, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        try buf.writer().print("0x{}", .{std.fmt.fmtSliceHexLower(&self.address)});
        try buf.appendSlice("::");
        try buf.appendSlice(self.name);
        return buf.toOwnedSlice();
    }
};

/// Function handle - reference to function signature
pub const FunctionHandle = struct {
    /// Module containing the function
    module: ModuleId,
    /// Function name
    name: []const u8,
    /// Parameter types
    param_types: []const u16,
    /// Return types
    return_types: []const u16,
    /// Whether function is native
    is_native: bool,
};

/// Function instantiation (for generic functions)
pub const FunctionInstantiation = struct {
    /// Function handle index
    handle: u16,
    /// Type arguments
    type_args: []const u16,
};

/// Type signature
pub const TypeSignature = union(enum) {
    /// Reference: move-language/move/language/move-core/types/src/gas_schedule.rs
    Bool,
    U8,
    U16,
    U32,
    U64,
    U128,
    U256,
    Address,
    Signer,
    Vector: u16, // Type signature index
    Struct: u16, // Struct definition index
    Reference: u16, // Type signature index
    MutableReference: u16,
    TypeParameter: u16, // Type parameter index
};

/// Struct definition
pub const StructDef = struct {
    /// Struct name
    name: []const u8,
    /// Type parameters
    type_params: []const TypeParameter,
    /// Field definitions
    fields: std.ArrayList(FieldDef),
    /// Abilities (copy, drop, store, key)
    abilities: AbilitySet,
};

/// Type parameter
pub const TypeParameter = struct {
    name: []const u8,
    constraints: AbilitySet,
};

/// Field definition
pub const FieldDef = struct {
    name: []const u8,
    type_signature: TypeSignature,
};

/// Ability set
pub const AbilitySet = struct {
    can_copy: bool,
    can_drop: bool,
    can_store: bool,
    is_key: bool,

    pub fn default() AbilitySet {
        return .{
            .can_copy = false,
            .can_drop = false,
            .can_store = false,
            .is_key = false,
        };
    }

    pub fn key() AbilitySet {
        return .{
            .can_copy = false,
            .can_drop = false,
            .can_store = true,
            .is_key = true,
        };
    }
};

/// Function definition (with code)
pub const FunctionDef = struct {
    /// Function handle index
    handle: u16,
    /// Visibility
    visibility: Visibility,
    /// Type parameters
    type_params: []const TypeParameter,
    /// Parameters (local indices)
    params: u8,
    /// Return values
    returns: u8,
    /// Bytecode instructions
    code: bytecode.Bytecode,
    /// Whether is native
    is_native: bool,
};

/// Visibility
pub const Visibility = enum {
    Private,
    Public,
    Script,
};

/// Module cache/loader
pub const ModuleCache = struct {
    allocator: std.mem.Allocator,
    /// Loaded modules
    modules: std.StringHashMap(*Module),

    pub fn init(allocator: std.mem.Allocator) ModuleCache {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
        };
    }

    /// Get a module by ID
    pub fn getModule(self: *ModuleCache, id: *const ModuleId) ?*Module {
        const id_str = std.fmt.bytesToHex(id.address, .lower);
        return self.modules.get(id_str);
    }

    /// Add a module to the cache
    pub fn addModule(self: *ModuleCache, module: *Module) !void {
        const id_str = std.fmt.bytesToHex(module.id.address, .lower);
        try self.modules.put(id_str, module);
    }

    pub fn deinit(self: *ModuleCache, allocator: std.mem.Allocator) void {
        // Free modules
        var it = self.modules.valueIterator();
        while (it.next()) |m| {
            m.*.deinit(allocator);
            allocator.destroy(m.*);
        }
        self.modules.deinit();
    }
};
