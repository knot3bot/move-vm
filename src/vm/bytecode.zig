const std = @import("std");

/// Move VM Bytecode Instructions
/// Reference: move-language/move/language/move-binary-format/src/file_format.rs

pub const Instruction = union(enum) {
    // Stack operations
    pop: void,
    ret: Ret,

    // Local operations
    ld_loc: u8,
    st_loc: u8,
    copy_loc: u8,
    move_loc: u8,

    // Constant loading
    ld_u8: u8,
    ld_u16: u16,
    ld_u32: u32,
    ld_u64: u64,
    ld_u128: u128,
    ld_u256: u256,
    ld_const: LdConst,
    ld_addr: LdAddr,
    ld_true: void,
    ld_false: void,

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

    // Logical
    and_: void,
    or_: void,
    not: void,

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
    pack: u16,
    unpack: u16,
    pack_generic: u16,
    unpack_generic: u16,

    // Reference operations
    mut_borrow_loc: u8,
    imm_borrow_loc: u8,
    mut_borrow_field: u16,
    imm_borrow_field: u16,
    mut_borrow_field_generic: u16,
    imm_borrow_field_generic: u16,
    read_ref: void,
    write_ref: void,
    freeze_ref: void,

    // Cast operations
    cast_u8: void,
    cast_u16: void,
    cast_u32: void,
    cast_u64: void,
    cast_u128: void,
    cast_u256: void,

    // Global operations
    move_to: MoveTo,
    move_from: MoveFrom,
    exists: Exists,
    move_to_generic: MoveToGeneric,
    move_from_generic: MoveFromGeneric,
    exists_generic: ExistsGeneric,
    mut_borrow_global: BorrowGlobal,
    imm_borrow_global: BorrowGlobal,
    mut_borrow_global_generic: BorrowGlobalGeneric,
    imm_borrow_global_generic: BorrowGlobalGeneric,

    // Vector operations
    vec_pack: VecPack,
    vec_len: u16,
    vec_imm_borrow: u16,
    vec_mut_borrow: u16,
    vec_push_back: u16,
    vec_pop_back: u16,
    vec_unpack: VecUnpack,
    vec_swap: u16,

    // Abort
    abort: void,

    // Nop
    nop: void,
};

pub const Ret = struct {
    num_vals: u8,
};

pub const LdConst = struct {
    const_idx: u32,
};

pub const LdAddr = struct {
    addr_idx: u16,
};

pub const Call = struct {
    func: u16,
};

pub const CallGeneric = struct {
    func_instantiation: u16,
};

pub const MoveTo = struct {
    type_: u16,
};

pub const MoveFrom = struct {
    type_: u16,
};

pub const Exists = struct {
    type_: u16,
};

pub const MoveToGeneric = struct {
    type_instantiation: u16,
};

pub const MoveFromGeneric = struct {
    type_instantiation: u16,
};

pub const ExistsGeneric = struct {
    type_instantiation: u16,
};

pub const BorrowGlobal = struct {
    type_: u16,
};

pub const BorrowGlobalGeneric = struct {
    type_instantiation: u16,
};

pub const VecPack = struct {
    type_: u16,
    num: u64,
};

pub const VecUnpack = struct {
    type_: u16,
    num: u64,
};

/// Bytecode sequence
pub const Bytecode = struct {
    instructions: std.ArrayList(Instruction),

    pub fn init(allocator: std.mem.Allocator) Bytecode {
        _ = allocator;
        return .{
            .instructions = std.ArrayList(Instruction).empty,
        };
    }

    pub fn deinit(self: *Bytecode, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
    }

    pub fn push(self: *Bytecode, allocator: std.mem.Allocator, inst: Instruction) !void {
        try self.instructions.append(allocator, inst);
    }

    pub fn len(self: Bytecode) usize {
        return self.instructions.items.len;
    }
};

/// Gas cost per instruction
pub fn instructionGasCost(inst: Instruction) u64 {
    return switch (inst) {
        .add, .sub, .mul, .div, .mod => 1,
        .bit_and, .bit_or, .bit_xor, .shl, .shr => 1,
        .and_, .or_, .not => 1,
        .lt, .gt, .le, .ge, .eq, .neq => 1,
        .pop, .ret => 1,
        .ld_loc, .st_loc, .copy_loc, .move_loc => 1,
        .ld_u8, .ld_u16, .ld_u32, .ld_u64, .ld_u128, .ld_u256 => 1,
        .ld_const => 2,
        .ld_addr => 2,
        .ld_true, .ld_false => 1,
        .br_true, .br_false, .branch => 1,
        .call, .call_generic => 10,
        .pack, .unpack => 5,
        .pack_generic, .unpack_generic => 10,
        .read_ref, .write_ref => 2,
        .mut_borrow_loc, .imm_borrow_loc => 1,
        .mut_borrow_field, .imm_borrow_field => 2,
        .mut_borrow_field_generic, .imm_borrow_field_generic => 4,
        .freeze_ref => 0,
        .cast_u8, .cast_u16, .cast_u32, .cast_u64, .cast_u128, .cast_u256 => 1,
        .move_to, .move_from, .exists => 5,
        .move_to_generic, .move_from_generic, .exists_generic => 10,
        .mut_borrow_global, .imm_borrow_global => 5,
        .mut_borrow_global_generic, .imm_borrow_global_generic => 10,
        .abort => 1,
        .nop => 0,
        .vec_pack => 10,
        .vec_len => 2,
        .vec_imm_borrow, .vec_mut_borrow => 2,
        .vec_push_back => 3,
        .vec_pop_back => 2,
        .vec_unpack => 5,
        .vec_swap => 2,
    };
}
