const std = @import("std");

/// Move VM Bytecode Instructions
/// Reference: move-language/move/language/move-binary-format/src/file_format.rs
/// A bytecode instruction
pub const Instruction = union(enum) {
    // Stack operations
    pop: void,
    ret: Ret,

    // Local operations
    ld_loc: u8,
    st_loc: u8,
    ld_const: LdConst,

    // Arithmetic
    add: void,
    sub: void,
    mul: void,
    div: void,
    mod: void,
    bit_and: void,
    bit_or: void,
    bit_xor: void,
    shl: void,
    shr: void,

    // Comparison
    lt: void,
    gt: void,
    le: void,
    ge: void,
    eq: void,
    neq: void,

    // Control flow
    br_true: u16,
    br_false: u16,
    branch: u16,
    call: Call,
    call_generic: CallGeneric,

    // Pack/Unpack
    pack: u8,
    unpack: u8,

    // Reference operations
    read_ref: void,
    write_ref: void,
    copy_loc: u8,
    move_loc: u8,

    // Global operations
    move_to: MoveTo,
    move_from: MoveFrom,
    exists: Exists,
    move_to_generic: MoveToGeneric,
    move_from_generic: MoveFromGeneric,
    exists_generic: ExistsGeneric,

    // Borrow global
    borrow_global: BorrowGlobal,
    borrow_global_generic: BorrowGlobalGeneric,

    // Cast operations
    cast: Type,

    // Abort
    abort: void,

    // Nop
    nop: void,

    // New annotations
    freeze_ref: void,

    /// Simple instruction with no immediate
    pub fn simple(op: SimpleOpcode) Instruction {
        return switch (op) {
            .Add => .add,
            .Sub => .sub,
            .Mul => .mul,
            .Div => .div,
            .Mod => .mod,
            .BitAnd => .bit_and,
            .BitOr => .bit_or,
            .BitXor => .bit_xor,
            .Shl => .shl,
            .Shr => .shr,
            .Lt => .lt,
            .Gt => .gt,
            .Le => .le,
            .Ge => .ge,
            .Eq => .eq,
            .Neq => .neq,
            .Pop => .pop,
            .ReadRef => .read_ref,
            .WriteRef => .write_ref,
            .Abort => .abort,
            .Nop => .nop,
            .FreezeRef => .freeze_ref,
        };
    }
};

/// Simple opcodes (no immediate value)
pub const SimpleOpcode = enum {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
    Lt,
    Gt,
    Le,
    Ge,
    Eq,
    Neq,
    Pop,
    ReadRef,
    WriteRef,
    Abort,
    Nop,
    FreezeRef,
};

/// Return instruction
pub const Ret = struct {
    /// Number of return values
    num_vals: u8,
};

/// Load constant instruction
pub const LdConst = struct {
    /// Constant pool index
    const_idx: u32,
};

/// Call instruction
pub const Call = struct {
    /// Function handle index
    func: u16,
};

/// Generic call instruction
pub const CallGeneric = struct {
    /// Function instantiation index
    func_instantiation: u16,
};

/// MoveTo instruction
pub const MoveTo = struct {
    /// Type signature index
    type_: u16,
};

/// MoveFrom instruction
pub const MoveFrom = struct {
    /// Type signature index
    type_: u16,
};

/// Exists instruction
pub const Exists = struct {
    /// Type signature index
    type_: u16,
};

/// Generic MoveTo
pub const MoveToGeneric = struct {
    /// Type instantiation index
    type_instantiation: u16,
};

/// Generic MoveFrom
pub const MoveFromGeneric = struct {
    /// Type instantiation index
    type_instantiation: u16,
};

/// Generic Exists
pub const ExistsGeneric = struct {
    /// Type instantiation index
    type_instantiation: u16,
};

/// Borrow global
pub const BorrowGlobal = struct {
    /// Type signature index
    type_: u16,
    /// Mutable reference
    mutable: bool,
};

/// Generic borrow global
pub const BorrowGlobalGeneric = struct {
    /// Type instantiation index
    type_instantiation: u16,
    /// Mutable reference
    mutable: bool,
};

/// Type for cast operation
pub const Type = struct {
    /// Type signature index
    idx: u16,
};

/// Bytecode sequence
pub const Bytecode = struct {
    /// Instructions
    instructions: std.ArrayList(Instruction),

    pub fn init(allocator: std.mem.Allocator) Bytecode {
        return .{
            .instructions = std.ArrayList(Instruction).init(allocator),
        };
    }

    pub fn deinit(self: *Bytecode) void {
        self.instructions.deinit();
    }

    pub fn push(self: *Bytecode, inst: Instruction) !void {
        try self.instructions.append(inst);
    }
};

/// Gas cost per instruction
pub fn instructionGasCost(inst: Instruction) u64 {
    return switch (inst) {
        .add, .sub, .mul, .div, .mod => 1,
        .bit_and, .bit_or, .bit_xor, .shl, .shr => 1,
        .lt, .gt, .le, .ge, .eq, .neq => 1,
        .pop, .ret => 1,
        .ld_loc, .st_loc => 1,
        .ld_const => 2,
        .br_true, .br_false, .branch => 1,
        .call, .call_generic => 10,
        .pack, .unpack => 5,
        .read_ref, .write_ref => 2,
        .copy_loc, .move_loc => 1,
        .move_to, .move_from, .exists => 5,
        .move_to_generic, .move_from_generic, .exists_generic => 10,
        .borrow_global, .borrow_global_generic => 5,
        .cast => 1,
        .abort => 1,
        .nop, .freeze_ref => 0,
    };
}
