const std = @import("std");

/// A value in the Move VM
/// Reference: move-language/move/language/move-vm-types/src/values.rs
pub const Value = union(enum) {
    Bool: bool,
    U8: u8,
    U16: u16,
    U32: u32,
    U64: u64,
    U128: u128,
    U256: u256,
    Address: [32]u8,
    Signer: [32]u8,
    Vector: Vector,
    Struct: Struct,
    Reference: Reference,
    MutableReference: Reference,
    Invalid,

    pub fn dump(self: Value, writer: anytype) !void {
        switch (self) {
            .Bool => try writer.print("{}", .{self.Bool}),
            .U8 => try writer.print("{}", .{self.U8}),
            .U16 => try writer.print("{}", .{self.U16}),
            .U32 => try writer.print("{}", .{self.U32}),
            .U64 => try writer.print("{}", .{self.U64}),
            .U128 => try writer.print("{}", .{self.U128}),
            .U256 => try writer.print("{}", .{self.U256}),
            .Address => {
                try writer.print("@0x", .{});
                for (self.Address) |b| {
                    try writer.print("{x}", .{b});
                }
            },
            .Signer => {
                try writer.print("Signer@0x", .{});
                for (self.Signer) |b| {
                    try writer.print("{x}", .{b});
                }
            },
            .Vector => |v| try writer.print("Vector(len={})", .{v.len()}),
            .Struct => |s| try writer.print("Struct({})", .{s}),
            .Reference => |r| try writer.print("Ref({})", .{r}),
            .MutableReference => |r| try writer.print("&mut {}", .{r}),
            .Invalid => try writer.print("Invalid", .{}),
        }
    }

    /// Check if value is a resource (cannot be copied)
    pub fn isResource(self: Value) bool {
        switch (self) {
            .Signer, .Struct => return true,
            else => return false,
        }
    }

    /// Check if value can be copied
    pub fn canCopy(self: Value) bool {
        return !self.isResource();
    }

    /// Get type tag for this value
    pub fn typeTag(self: Value) TypeTag {
        switch (self) {
            .Bool => return .Bool,
            .U8 => return .U8,
            .U16 => return .U16,
            .U32 => return .U32,
            .U64 => return .U64,
            .U128 => return .U128,
            .U256 => return .U256,
            .Address => return .Address,
            .Signer => return .Signer,
            .Vector => return .Vector,
            .Struct => return .Struct,
            .Reference, .MutableReference => return .MutableReference,
            .Invalid => return .U64, // fallback
        }
    }
};

/// Type tag for values
pub const TypeTag = enum {
    Bool,
    U8,
    U16,
    U32,
    U64,
    U128,
    U256,
    Address,
    Signer,
    Vector,
    Struct,
    Reference,
    MutableReference,
};

/// Vector value
pub const Vector = struct {
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Vector {
        return .{
            .data = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn len(self: Vector) usize {
        return self.data.items.len;
    }

    pub fn deinit(self: *Vector) void {
        self.data.deinit();
    }
};

/// Reference value
pub const Reference = struct {
    /// Points to the value
    value: *Value,
};

/// Struct representation
pub const Struct = struct {
    /// Type ID (handle index)
    type_id: u32,
    /// Struct field values
    fields: std.ArrayList(Value),

    pub fn init(allocator: std.mem.Allocator, type_id: u32) Struct {
        return .{
            .type_id = type_id,
            .fields = std.ArrayList(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Struct) void {
        self.fields.deinit();
    }
};

/// Local variable
pub const Local = struct {
    value: Value,
    is_mutable: bool,
};

/// Execution frame - represents a function call
/// Reference: move-language/move/language/move-vm/runtime/src/interpreter.rs Frame
pub const Frame = struct {
    /// PC counter
    pc: u32,
    /// Local variables
    locals: std.ArrayList(Local),
    /// Type arguments for generic functions
    ty_args: std.ArrayList(Type),
    /// Function being executed
    function: ?*const Function,
    /// Location (module info for error reporting)
    location: Location,

    pub fn init(allocator: std.mem.Allocator, num_locals: u32) Frame {
        var locals = std.ArrayList(Local).init(allocator);
        locals.resize(num_locals) catch unreachable;
        // Initialize all locals to Invalid
        for (locals.items) |*l| {
            l.* = .{ .value = .Invalid, .is_mutable = true };
        }

        return .{
            .pc = 0,
            .locals = locals,
            .ty_args = std.ArrayList(Type).init(allocator),
            .function = null,
            .location = Location.default(),
        };
    }

    pub fn deinit(self: *Frame) void {
        self.locals.deinit();
        self.ty_args.deinit();
    }

    /// Get local variable at index
    pub fn getLocal(self: Frame, idx: u8) ?Value {
        if (idx < self.locals.items.len) {
            return self.locals.items[idx].value;
        }
        return null;
    }

    /// Set local variable at index
    pub fn setLocal(self: *Frame, idx: u8, value: Value) void {
        if (idx < self.locals.items.len) {
            self.locals.items[idx].value = value;
        }
    }
};

/// Function definition
pub const Function = struct {
    /// Function name
    name: []const u8,
    /// Number of parameters
    param_count: u8,
    /// Number of return values
    return_count: u8,
    /// Number of locals
    local_count: u8,
    /// Whether function is native
    is_native: bool,
    /// Bytecode instructions
    code: std.ArrayList(Instruction),
    /// Parameter types
    param_types: std.ArrayList(Type),
    /// Return types
    return_types: std.ArrayList(Type),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Function {
        return .{
            .name = name,
            .param_count = 0,
            .return_count = 0,
            .local_count = 0,
            .is_native = false,
            .code = std.ArrayList(Instruction).init(allocator),
            .param_types = std.ArrayList(Type).init(allocator),
            .return_types = std.ArrayList(Type).init(allocator),
        };
    }

    pub fn deinit(self: *Function) void {
        self.code.deinit();
        self.param_types.deinit();
        self.return_types.deinit();
    }
};

/// Type for type checking
pub const Type = union(enum) {
    Bool,
    U8,
    U16,
    U32,
    U64,
    U128,
    U256,
    Address,
    Signer,
    Reference: *Type,
    MutableReference: *Type,
    Vector: *Type,
    Struct: StructType,
    TypeParameter: u16,

    pub fn isResource(self: Type) bool {
        switch (self) {
            .Signer, .Struct => return true,
            else => return false,
        }
    }
};

/// Struct type info
pub const StructType = struct {
    handle: u16,
    field_types: std.ArrayList(Type),
};

/// Location for error reporting
pub const Location = struct {
    module: ?ModuleId,
    function_idx: u16,
    code_offset: u16,

    pub fn default() Location {
        return .{
            .module = null,
            .function_idx = 0,
            .code_offset = 0,
        };
    }
};

/// Module ID
pub const ModuleId = struct {
    address: [32]u8,
    name: []const u8,
};

/// Simple instruction representation
pub const Instruction = union(enum) {
    pop,
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    lt,
    gt,
    le,
    ge,
    eq,
    neq,
    read_ref,
    write_ref,
    abort,
    nop,
    freeze_ref,
    ld_loc: u8,
    st_loc: u8,
    ld_const: LdConst,
    br_true: u16,
    br_false: u16,
    branch: u16,
    call: Call,
    call_generic: CallGeneric,
    pack: u8,
    unpack: u8,
    move_to: MoveTo,
    move_from: MoveFrom,
    exists: Exists,
    borrow_global: BorrowGlobal,
    ret: Ret,
    move_to_generic,
    move_from_generic,
    exists_generic,
    borrow_global_generic,
    cast: Cast,
};

pub const LdConst = struct { const_idx: u32 };
pub const Call = struct { func: u16 };
pub const CallGeneric = struct { func_instantiation: u16 };
pub const MoveTo = struct { type_: u16 };
pub const MoveFrom = struct { type_: u16 };
pub const Exists = struct { type_: u16 };
pub const BorrowGlobal = struct { type_: u16, mutable: bool };
pub const Ret = struct { num_vals: u8 };
pub const Cast = struct { idx: u16 };
