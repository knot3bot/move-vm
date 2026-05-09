const std = @import("std");

/// Runtime type representation
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

    pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Reference => |ty| {
                ty.deinit(allocator);
                allocator.destroy(ty);
            },
            .MutableReference => |ty| {
                ty.deinit(allocator);
                allocator.destroy(ty);
            },
            .Vector => |ty| {
                ty.deinit(allocator);
                allocator.destroy(ty);
            },
            .Struct => |s| {
                for (s.field_types) |*ft| {
                    ft.deinit(allocator);
                }
                allocator.free(s.field_types);
            },
            else => {},
        }
    }
};

pub const StructType = struct {
    handle: u16,
    field_types: []Type,
};

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

/// Type parameter
pub const TypeParameter = struct {
    name: []const u8,
    constraints: AbilitySet,
};

/// Ability set for structs
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

/// Location for error reporting
pub const Location = union(enum) {
    Undefined,
    Module: ModuleId,

    pub fn default() Location {
        return .Undefined;
    }
};

/// Module ID
pub const ModuleId = struct {
    address: [32]u8,
    name: []const u8,

    pub fn toString(self: ModuleId, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "0x");
        for (self.address) |b| {
            const hex = std.fmt.bytesToHex(&[_]u8{b}, .lower);
            try buf.appendSlice(allocator, &hex);
        }
        try buf.appendSlice(allocator, "::");
        try buf.appendSlice(allocator, self.name);
        return try buf.toOwnedSlice(allocator);
    }
};
