/// Move VM Bytecode Opcodes
/// Reference: https://github.com/move-language/move/blob/main/language/move-core/types/src/gas_schedule.rs
pub const Opcode = enum(u8) {
    // Stack operations
    Pop = 0x01,
    Ret = 0x02,

    // Local operations
    LdLoc = 0x03,
    StLoc = 0x04,
    LdConst = 0x05,

    // Arithmetic
    Add = 0x10,
    Sub = 0x11,
    Mul = 0x12,
    Div = 0x13,
    Mod = 0x14,
    BitAnd = 0x15,
    BitOr = 0x16,
    BitXor = 0x17,
    Shl = 0x18,
    Shr = 0x19,

    // Comparison
    Lt = 0x20,
    Gt = 0x21,
    Le = 0x22,
    Ge = 0x23,
    Eq = 0x24,
    Neq = 0x25,

    // Control flow
    BrTrue = 0x30,
    BrFalse = 0x31,
    Branch = 0x32,
    Call = 0x33,

    // Pack/Unpack
    Pack = 0x40,
    Unpack = 0x41,

    // Reference operations
    ReadRef = 0x50,
    WriteRef = 0x51,
    CopyLoc = 0x52,
    MoveLoc = 0x53,

    // Global operations
    MoveTo = 0x60,
    MoveFrom = 0x61,
    Exists = 0x62,
    MoveToGeneric = 0x63,
    MoveFromGeneric = 0x64,
    ExistsGeneric = 0x65,

    // Function operations
    CallGeneric = 0x36,
    Param = 0x37,

    // Cast operations
    Cast = 0x70,

    // Abort
    Abort = 0x80,

    // Nop
    Nop = 0xFF,
};

/// Number of Stack slots consumed/produced by each opcode
/// (consumed, produced)
pub fn stackEffect(op: Opcode) struct { consumed: u8, produced: u8 } {
    switch (op) {
        // Stack operations
        .Pop => return .{ .consumed = 1, .produced = 0 },
        .Ret => return .{ .consumed = 0, .produced = 0 }, // varies

        // Local operations
        .LdLoc => return .{ .consumed = 0, .produced = 1 },
        .StLoc => return .{ .consumed = 1, .produced = 0 },
        .LdConst => return .{ .consumed = 0, .produced = 1 },

        // Arithmetic - binary
        .Add, .Sub, .Mul, .Div, .Mod, .BitAnd, .BitOr, .BitXor, .Shl, .Shr => {
            return .{ .consumed = 2, .produced = 1 };
        },
        // Comparison - binary
        .Lt, .Gt, .Le, .Ge, .Eq, .Neq => return .{ .consumed = 2, .produced = 1 },

        // Control flow
        .BrTrue => return .{ .consumed = 1, .produced = 0 },
        .BrFalse => return .{ .consumed = 1, .produced = 0 },
        .Branch => return .{ .consumed = 0, .produced = 0 },
        .Call => return .{ .consumed = 0, .produced = 0 }, // varies

        // Pack/Unpack
        .Pack => return .{ .consumed = 0, .produced = 1 }, // varies
        .Unpack => return .{ .consumed = 1, .produced = 0 }, // varies

        // Reference operations
        .ReadRef => return .{ .consumed = 1, .produced = 1 },
        .WriteRef => return .{ .consumed = 2, .produced = 0 },
        .CopyLoc => return .{ .consumed = 1, .produced = 1 },
        .MoveLoc => return .{ .consumed = 1, .produced = 1 },

        // Global operations
        .MoveTo => return .{ .consumed = 2, .produced = 0 },
        .MoveFrom => return .{ .consumed = 1, .produced = 1 },
        .Exists => return .{ .consumed = 1, .produced = 1 },

        // Function operations
        .CallGeneric => return .{ .consumed = 0, .produced = 0 },
        .Param => return .{ .consumed = 0, .produced = 1 },

        // Cast
        .Cast => return .{ .consumed = 1, .produced = 1 },

        // Abort
        .Abort => return .{ .consumed = 1, .produced = 0 },

        // Nop
        .Nop => return .{ .consumed = 0, .produced = 0 },
    }
}
