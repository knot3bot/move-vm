const std = @import("std");
const types = @import("types.zig");

/// Global data status for tracking dirty writes
pub const GlobalDataStatus = enum {
    Clean,
    Dirty,
};

/// A container represents a collection of values (vector or struct fields).
/// All containers are heap-allocated and referenced via pointers.
pub const Container = struct {
    kind: Kind,
    data: std.ArrayList(ValueImpl),
    abilities: types.AbilitySet,
    ref_count: u32,

    pub const Kind = enum {
        Vec,
        Struct,
    };

    /// Create a new container on the heap.
    pub fn new(allocator: std.mem.Allocator, kind: Kind) !*Container {
        const ptr = try allocator.create(Container);
        ptr.* = .{
            .kind = kind,
            .data = std.ArrayList(ValueImpl).empty,
            .abilities = types.AbilitySet.default(),
            .ref_count = 0,
        };
        return ptr;
    }

    /// Create a new container with specific abilities.
    pub fn newWithAbilities(allocator: std.mem.Allocator, kind: Kind, abilities: types.AbilitySet) !*Container {
        const ptr = try allocator.create(Container);
        ptr.* = .{
            .kind = kind,
            .data = std.ArrayList(ValueImpl).empty,
            .abilities = abilities,
            .ref_count = 0,
        };
        return ptr;
    }

    /// Deep-copy this container.
    pub fn copy_value(self: *Container, allocator: std.mem.Allocator) error{OutOfMemory}!*Container {
        const ptr = try allocator.create(Container);
        errdefer ptr.deinit(allocator);
        ptr.* = .{
            .kind = self.kind,
            .data = std.ArrayList(ValueImpl).empty,
            .abilities = self.abilities,
            .ref_count = 0,
        };
        for (self.data.items) |item| {
            try ptr.data.append(allocator, try item.copy_value(allocator));
        }
        return ptr;
    }

    /// Deinitialize and free this container.
    pub fn deinit(self: *Container, allocator: std.mem.Allocator) void {
        for (self.data.items) |*item| {
            item.deinit(allocator);
        }
        if (self.ref_count != 0) {
            @panic("Container.deinit called with active references");
        }
        self.data.deinit(allocator);
        allocator.destroy(self);
    }

    /// Compare two containers for equality.
    pub fn equals(self: *Container, other: *Container) !bool {
        if (self.kind != other.kind) return false;
        if (self.data.items.len != other.data.items.len) return false;
        for (self.data.items, other.data.items) |a, b| {
            if (!try a.equals(b)) return false;
        }
        return true;
    }

    /// Get the length of this container.
    pub fn len(self: *Container) usize {
        return self.data.items.len;
    }
};

/// A reference to a container (vector, struct, or local slot).
pub const ContainerRef = struct {
    container: *Container,
    is_mutable: bool = true,
    is_global: bool = false,
    global_status: ?*GlobalDataStatus = null,
    // For global borrows: address and type_key are duplicated to enable
    // transaction logging on write_ref and borrow tracking on move_to/move_from.
    global_address: ?[]const u8 = null,
    global_type_key: ?[]const u8 = null,
};

/// A reference to an element inside a container.
pub const IndexedRef = struct {
    container_ref: ContainerRef,
    idx: usize,
};

/// Internal representation of a Move value.
pub const ValueImpl = union(enum) {
    Invalid,
    U8: u8,
    U16: u16,
    U32: u32,
    U64: u64,
    U128: u128,
    U256: u256,
    Bool: bool,
    Address: [32]u8,
    Container: *Container,
    ContainerRef: ContainerRef,
    IndexedRef: IndexedRef,

    pub const CopyError = error{ OutOfMemory };

    /// Deep-copy a ValueImpl.
    pub fn copy_value(self: ValueImpl, allocator: std.mem.Allocator) CopyError!ValueImpl {
        return switch (self) {
            .Invalid => .Invalid,
            .U8 => |x| .{ .U8 = x },
            .U16 => |x| .{ .U16 = x },
            .U32 => |x| .{ .U32 = x },
            .U64 => |x| .{ .U64 = x },
            .U128 => |x| .{ .U128 = x },
            .U256 => |x| .{ .U256 = x },
            .Bool => |x| .{ .Bool = x },
            .Address => |x| .{ .Address = x },
            .Container => |c| .{ .Container = try c.copy_value(allocator) },
            .ContainerRef => |r| {
                r.container.ref_count += 1;
                const addr_copy = if (r.global_address) |addr| try allocator.dupe(u8, addr) else null;
                errdefer if (addr_copy) |a| allocator.free(a);
                const tk_copy = if (r.global_type_key) |tk| try allocator.dupe(u8, tk) else null;
                return .{ .ContainerRef = .{
                    .container = r.container,
                    .is_mutable = r.is_mutable,
                    .is_global = r.is_global,
                    .global_status = r.global_status,
                    .global_address = addr_copy,
                    .global_type_key = tk_copy,
                } };
            },
            .IndexedRef => |r| {
                r.container_ref.container.ref_count += 1;
                return .{ .IndexedRef = .{
                    .container_ref = .{
                        .container = r.container_ref.container,
                        .is_mutable = r.container_ref.is_mutable,
                        .is_global = r.container_ref.is_global,
                        .global_status = r.container_ref.global_status,
                    },
                    .idx = r.idx,
                } };
            },
        };
    }

    pub const EqualsError = error{ TypeMismatch, IndexOutOfBounds };

    /// Compare two ValueImpls for equality.
    pub fn equals(self: ValueImpl, other: ValueImpl) EqualsError!bool {
        const tag_a = std.meta.activeTag(self);
        const tag_b = std.meta.activeTag(other);
        if (tag_a != tag_b) return false;

        return switch (self) {
            .Invalid => true,
            .U8 => |a| a == other.U8,
            .U16 => |a| a == other.U16,
            .U32 => |a| a == other.U32,
            .U64 => |a| a == other.U64,
            .U128 => |a| a == other.U128,
            .U256 => |a| a == other.U256,
            .Bool => |a| a == other.Bool,
            .Address => |a| std.mem.eql(u8, &a, &other.Address),
            .Container => |a| try a.equals(other.Container),
            .ContainerRef => |a| a.container == other.ContainerRef.container,
            .IndexedRef => |a| a.container_ref.container == other.IndexedRef.container_ref.container and a.idx == other.IndexedRef.idx,
        };
    }

    /// Deinitialize any heap-allocated resources owned by this ValueImpl.
    pub fn deinit(self: *ValueImpl, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Container => |c| c.deinit(allocator),
            .ContainerRef => |r| {
                r.container.ref_count -= 1;
                if (r.global_address) |addr| allocator.free(addr);
                if (r.global_type_key) |tk| allocator.free(tk);
            },
            .IndexedRef => |r| {
                r.container_ref.container.ref_count -= 1;
            },
            else => {},
        }
    }

    /// Read from a reference.
    pub fn read_ref(self: ValueImpl, allocator: std.mem.Allocator) !ValueImpl {
        return switch (self) {
            .ContainerRef => |r| .{ .Container = try r.container.copy_value(allocator) },
            .IndexedRef => |r| {
                if (r.idx >= r.container_ref.container.data.items.len) return error.IndexOutOfBounds;
                return try r.container_ref.container.data.items[r.idx].copy_value(allocator);
            },
            else => error.TypeMismatch,
        };
    }

    /// Write to a reference.
    pub fn write_ref(self: *ValueImpl, allocator: std.mem.Allocator, value: ValueImpl) !void {
        switch (self.*) {
            .ContainerRef => |*r| {
                if (!r.is_mutable) return error.InvalidReference;
                if (r.container.ref_count > 1) return error.InvalidReference;
                switch (value) {
                    .Container => |src| {
                        if (r.container.kind != src.kind) return error.TypeMismatch;
                        // Deep replace: free old items, copy new ones
                        for (r.container.data.items) |*item| {
                            item.deinit(allocator);
                        }
                        r.container.data.clearRetainingCapacity();
                        for (src.data.items) |item| {
                            try r.container.data.append(allocator, try item.copy_value(allocator));
                        }
                        if (r.is_global) {
                            if (r.global_status) |status| {
                                status.* = .Dirty;
                            }
                        }
                    },
                    else => return error.TypeMismatch,
                }
            },
            .IndexedRef => |*r| {
                if (!r.container_ref.is_mutable) return error.InvalidReference;
                if (r.idx >= r.container_ref.container.data.items.len) return error.IndexOutOfBounds;
                const old = r.container_ref.container.data.items[r.idx];
                if (old == .Container and old.Container.ref_count > 0) return error.InvalidReference;
                const new_val = try value.copy_value(allocator);
                r.container_ref.container.data.items[r.idx].deinit(allocator);
                r.container_ref.container.data.items[r.idx] = new_val;
                if (r.container_ref.is_global) {
                    if (r.container_ref.global_status) |status| {
                        status.* = .Dirty;
                    }
                }
            },
            else => return error.TypeMismatch,
        }
    }

    /// Borrow an element from a container reference.
    pub fn borrow_elem(self: ValueImpl, idx: usize) !ValueImpl {
        return switch (self) {
            .ContainerRef => |r| {
                if (r.container.kind != .Vec) return error.TypeMismatch;
                if (idx >= r.container.data.items.len) return error.IndexOutOfBounds;
                const item = r.container.data.items[idx];
                switch (item) {
                    .Container => |c| {
                        c.ref_count += 1;
                        return .{ .ContainerRef = .{
                            .container = c,
                            .is_mutable = r.is_mutable,
                            .is_global = r.is_global,
                            .global_status = r.global_status,
                        } };
                    },
                    else => {
                        r.container.ref_count += 1;
                        return .{ .IndexedRef = .{
                            .container_ref = r,
                            .idx = idx,
                        } };
                    },
                }
            },
            else => return error.TypeMismatch,
        };
    }

    /// Borrow a field from a struct reference.
    pub fn borrow_field(self: ValueImpl, idx: usize) !ValueImpl {
        return switch (self) {
            .ContainerRef => |r| {
                if (r.container.kind != .Struct) return error.TypeMismatch;
                if (idx >= r.container.data.items.len) return error.IndexOutOfBounds;
                const item = r.container.data.items[idx];
                switch (item) {
                    .Container => |c| {
                        c.ref_count += 1;
                        return .{ .ContainerRef = .{
                            .container = c,
                            .is_mutable = r.is_mutable,
                            .is_global = r.is_global,
                            .global_status = r.global_status,
                        } };
                    },
                    else => {
                        r.container.ref_count += 1;
                        return .{ .IndexedRef = .{
                            .container_ref = r,
                            .idx = idx,
                        } };
                    },
                }
            },
            else => return error.TypeMismatch,
        };
    }

    /// Get the type tag for this value.
    pub fn typeTag(self: ValueImpl) types.TypeTag {
        return switch (self) {
            .Invalid => .U64,
            .U8 => .U8,
            .U16 => .U16,
            .U32 => .U32,
            .U64 => .U64,
            .U128 => .U128,
            .U256 => .U256,
            .Bool => .Bool,
            .Address => .Address,
            .Container => .Struct,
            .ContainerRef => .Reference,
            .IndexedRef => .Reference,
        };
    }

    /// Check if this value can be copied.
    pub fn canCopy(self: ValueImpl) bool {
        return switch (self) {
            .Container => |c| c.abilities.can_copy,
            else => true,
        };
    }

    /// Check if this value can be dropped.
    pub fn canDrop(self: ValueImpl) bool {
        return switch (self) {
            .Container => |c| c.abilities.can_drop and c.ref_count == 0,
            else => true,
        };
    }

    /// Check if this value can be stored (move_to).
    pub fn canStore(self: ValueImpl) bool {
        return switch (self) {
            .Container => |c| c.abilities.can_store,
            else => true,
        };
    }

    /// Check if this value has the key ability (for global storage).
    pub fn isKey(self: ValueImpl) bool {
        return switch (self) {
            .Container => |c| c.abilities.is_key,
            else => false,
        };
    }

    pub fn isResource(self: ValueImpl) bool {
        return switch (self) {
            .Container => |c| c.abilities.is_key,
            else => false,
        };
    }
};

/// Public wrapper around ValueImpl.
pub const Value = struct {
    impl: ValueImpl,

    pub fn init(impl: ValueImpl) Value {
        return .{ .impl = impl };
    }

    pub fn makeU8(x: u8) Value { return .{ .impl = .{ .U8 = x } }; }
    pub fn makeU16(x: u16) Value { return .{ .impl = .{ .U16 = x } }; }
    pub fn makeU32(x: u32) Value { return .{ .impl = .{ .U32 = x } }; }
    pub fn makeU64(x: u64) Value { return .{ .impl = .{ .U64 = x } }; }
    pub fn makeU128(x: u128) Value { return .{ .impl = .{ .U128 = x } }; }
    pub fn makeU256(x: u256) Value { return .{ .impl = .{ .U256 = x } }; }
    pub fn makeBool(x: bool) Value { return .{ .impl = .{ .Bool = x } }; }
    pub fn address(x: [32]u8) Value { return .{ .impl = .{ .Address = x } }; }
    pub fn invalid() Value { return .{ .impl = .Invalid }; }

    pub fn copy_value(self: Value, allocator: std.mem.Allocator) !Value {
        return .{ .impl = try self.impl.copy_value(allocator) };
    }

    pub fn equals(self: Value, other: Value) !bool {
        return try self.impl.equals(other.impl);
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        self.impl.deinit(allocator);
    }

    pub fn read_ref(self: Value, allocator: std.mem.Allocator) !Value {
        return .{ .impl = try self.impl.read_ref(allocator) };
    }

    pub fn write_ref(self: *Value, allocator: std.mem.Allocator, value: Value) !void {
        try self.impl.write_ref(allocator, value.impl);
    }

    pub fn borrow_elem(self: Value, idx: usize) !Value {
        return .{ .impl = try self.impl.borrow_elem(idx) };
    }

    pub fn borrow_field(self: Value, idx: usize) !Value {
        return .{ .impl = try self.impl.borrow_field(idx) };
    }

    pub fn typeTag(self: Value) types.TypeTag {
        return self.impl.typeTag();
    }

    pub fn isResource(self: Value) bool {
        return self.impl.isResource();
    }

    pub fn canCopy(self: Value) bool {
        return self.impl.canCopy();
    }

    pub fn canDrop(self: Value) bool {
        return self.impl.canDrop();
    }

    pub fn canStore(self: Value) bool {
        return self.impl.canStore();
    }

    pub fn isKey(self: Value) bool {
        return self.impl.isKey();
    }
};

/// Integer value wrapper for arithmetic operations.
pub const IntegerValue = union(enum) {
    U8: u8,
    U16: u16,
    U32: u32,
    U64: u64,
    U128: u128,
    U256: u256,

    pub fn fromValue(v: Value) !IntegerValue {
        return switch (v.impl) {
            .U8 => |x| .{ .U8 = x },
            .U16 => |x| .{ .U16 = x },
            .U32 => |x| .{ .U32 = x },
            .U64 => |x| .{ .U64 = x },
            .U128 => |x| .{ .U128 = x },
            .U256 => |x| .{ .U256 = x },
            else => error.TypeMismatch,
        };
    }

    pub fn toValue(self: IntegerValue) Value {
        return switch (self) {
            .U8 => |x| Value.makeU8(x),
            .U16 => |x| Value.makeU16(x),
            .U32 => |x| Value.makeU32(x),
            .U64 => |x| Value.makeU64(x),
            .U128 => |x| Value.makeU128(x),
            .U256 => |x| Value.makeU256(x),
        };
    }

    pub fn add_checked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.add(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.add(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.add(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.add(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.add(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.add(u256, x, b.U256) },
        };
    }

    pub fn sub_checked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.sub(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.sub(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.sub(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.sub(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.sub(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.sub(u256, x, b.U256) },
        };
    }

    pub fn mul_checked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.mul(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.mul(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.mul(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.mul(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.mul(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.mul(u256, x, b.U256) },
        };
    }

    pub fn div_checked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        if (b.isZero()) return error.DivisionByZero;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.divTrunc(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.divTrunc(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.divTrunc(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.divTrunc(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.divTrunc(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.divTrunc(u256, x, b.U256) },
        };
    }

    pub fn rem_checked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        if (b.isZero()) return error.DivisionByZero;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.rem(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.rem(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.rem(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.rem(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.rem(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.rem(u256, x, b.U256) },
        };
    }

    pub fn bit_or(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = x | b.U8 },
            .U16 => |x| .{ .U16 = x | b.U16 },
            .U32 => |x| .{ .U32 = x | b.U32 },
            .U64 => |x| .{ .U64 = x | b.U64 },
            .U128 => |x| .{ .U128 = x | b.U128 },
            .U256 => |x| .{ .U256 = x | b.U256 },
        };
    }

    pub fn bit_and(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = x & b.U8 },
            .U16 => |x| .{ .U16 = x & b.U16 },
            .U32 => |x| .{ .U32 = x & b.U32 },
            .U64 => |x| .{ .U64 = x & b.U64 },
            .U128 => |x| .{ .U128 = x & b.U128 },
            .U256 => |x| .{ .U256 = x & b.U256 },
        };
    }

    pub fn bit_xor(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = x ^ b.U8 },
            .U16 => |x| .{ .U16 = x ^ b.U16 },
            .U32 => |x| .{ .U32 = x ^ b.U32 },
            .U64 => |x| .{ .U64 = x ^ b.U64 },
            .U128 => |x| .{ .U128 = x ^ b.U128 },
            .U256 => |x| .{ .U256 = x ^ b.U256 },
        };
    }

    pub fn shl_checked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| {
                if (b.U8 >= 8) return error.Overflow;
                return .{ .U8 = try std.math.shlExact(u8, x, @intCast(b.U8)) };
            },
            .U16 => |x| {
                if (b.U16 >= 16) return error.Overflow;
                return .{ .U16 = try std.math.shlExact(u16, x, @intCast(b.U16)) };
            },
            .U32 => |x| {
                if (b.U32 >= 32) return error.Overflow;
                return .{ .U32 = try std.math.shlExact(u32, x, @intCast(b.U32)) };
            },
            .U64 => |x| {
                if (b.U64 >= 64) return error.Overflow;
                return .{ .U64 = try std.math.shlExact(u64, x, @intCast(b.U64)) };
            },
            .U128 => |x| {
                if (b.U128 >= 128) return error.Overflow;
                return .{ .U128 = try std.math.shlExact(u128, x, @intCast(b.U128)) };
            },
            .U256 => |x| {
                const shift: u8 = @intCast(b.U256 & 0xFF);
                if (shift >= 256) return error.Overflow;
                return .{ .U256 = x << shift };
            },
        };
    }

    pub fn shr_checked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        if (b.isZero()) return a;
        return switch (a) {
            .U8 => |x| .{ .U8 = std.math.shr(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = std.math.shr(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = std.math.shr(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = std.math.shr(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = std.math.shr(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = x >> @as(u8, @intCast(b.U256 & 0xFF)) },
        };
    }

    pub fn lt(a: IntegerValue, b: IntegerValue) !bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| x < b.U8,
            .U16 => |x| x < b.U16,
            .U32 => |x| x < b.U32,
            .U64 => |x| x < b.U64,
            .U128 => |x| x < b.U128,
            .U256 => |x| x < b.U256,
        };
    }

    pub fn gt(a: IntegerValue, b: IntegerValue) !bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| x > b.U8,
            .U16 => |x| x > b.U16,
            .U32 => |x| x > b.U32,
            .U64 => |x| x > b.U64,
            .U128 => |x| x > b.U128,
            .U256 => |x| x > b.U256,
        };
    }

    pub fn le(a: IntegerValue, b: IntegerValue) !bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| x <= b.U8,
            .U16 => |x| x <= b.U16,
            .U32 => |x| x <= b.U32,
            .U64 => |x| x <= b.U64,
            .U128 => |x| x <= b.U128,
            .U256 => |x| x <= b.U256,
        };
    }

    pub fn ge(a: IntegerValue, b: IntegerValue) !bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| x >= b.U8,
            .U16 => |x| x >= b.U16,
            .U32 => |x| x >= b.U32,
            .U64 => |x| x >= b.U64,
            .U128 => |x| x >= b.U128,
            .U256 => |x| x >= b.U256,
        };
    }

    pub fn cast_u8(self: IntegerValue) !u8 {
        return switch (self) {
            .U8 => |x| x,
            .U16 => |x| std.math.cast(u8, x) orelse return error.Overflow,
            .U32 => |x| std.math.cast(u8, x) orelse return error.Overflow,
            .U64 => |x| std.math.cast(u8, x) orelse return error.Overflow,
            .U128 => |x| std.math.cast(u8, x) orelse return error.Overflow,
            .U256 => |x| if (x <= std.math.maxInt(u8)) @intCast(x) else return error.Overflow,
        };
    }

    pub fn cast_u16(self: IntegerValue) !u16 {
        return switch (self) {
            .U8 => |x| x,
            .U16 => |x| x,
            .U32 => |x| std.math.cast(u16, x) orelse return error.Overflow,
            .U64 => |x| std.math.cast(u16, x) orelse return error.Overflow,
            .U128 => |x| std.math.cast(u16, x) orelse return error.Overflow,
            .U256 => |x| if (x <= std.math.maxInt(u16)) @intCast(x) else return error.Overflow,
        };
    }

    pub fn cast_u32(self: IntegerValue) !u32 {
        return switch (self) {
            .U8, .U16 => |x| @intCast(x),
            .U32 => |x| x,
            .U64 => |x| std.math.cast(u32, x) orelse return error.Overflow,
            .U128 => |x| std.math.cast(u32, x) orelse return error.Overflow,
            .U256 => |x| if (x <= std.math.maxInt(u32)) @intCast(x) else return error.Overflow,
        };
    }

    pub fn cast_u64(self: IntegerValue) !u64 {
        return switch (self) {
            .U8, .U16, .U32 => |x| @intCast(x),
            .U64 => |x| x,
            .U128 => |x| std.math.cast(u64, x) orelse return error.Overflow,
            .U256 => |x| if (x <= std.math.maxInt(u64)) @intCast(x) else return error.Overflow,
        };
    }

    pub fn cast_u128(self: IntegerValue) !u128 {
        return switch (self) {
            .U8, .U16, .U32, .U64 => |x| @intCast(x),
            .U128 => |x| x,
            .U256 => |x| if (x <= std.math.maxInt(u128)) @intCast(x) else return error.Overflow,
        };
    }

    pub fn cast_u256(self: IntegerValue) !u256 {
        return switch (self) {
            .U8, .U16, .U32, .U64, .U128 => |x| @intCast(x),
            .U256 => |x| x,
        };
    }

    fn isZero(self: IntegerValue) bool {
        return switch (self) {
            .U8 => |x| x == 0,
            .U16 => |x| x == 0,
            .U32 => |x| x == 0,
            .U64 => |x| x == 0,
            .U128 => |x| x == 0,
            .U256 => |x| x == 0,
        };
    }
};

/// Struct value helpers
pub const StructValue = struct {
    pub fn pack(allocator: std.mem.Allocator, fields: []const Value, abilities: types.AbilitySet) !Value {
        const container = try Container.newWithAbilities(allocator, .Struct, abilities);
        errdefer container.deinit(allocator);
        for (fields) |field| {
            try container.data.append(allocator, (try field.copy_value(allocator)).impl);
        }
        return Value.init(.{ .Container = container });
    }

    pub fn unpack(value: Value, allocator: std.mem.Allocator) !std.ArrayList(Value) {
        switch (value.impl) {
            .Container => |c| {
                if (c.kind != .Struct) return error.TypeMismatch;
                var result = std.ArrayList(Value).empty;
                for (c.data.items) |item| {
                    try result.append(allocator, Value.init(try item.copy_value(allocator)));
                }
                return result;
            },
            else => return error.TypeMismatch,
        }
    }
};

/// Vector value helpers
pub const VectorValue = struct {
    pub fn pack(allocator: std.mem.Allocator, elements: []const Value, abilities: types.AbilitySet) !Value {
        var container = try Container.newWithAbilities(allocator, .Vec, abilities);
        errdefer container.deinit(allocator);
        for (elements) |elem| {
            try container.data.append(allocator, (try elem.copy_value(allocator)).impl);
        }
        return Value.init(.{ .Container = container });
    }

    pub fn len(value: Value) !usize {
        switch (value.impl) {
            .Container => |c| {
                if (c.kind != .Vec) return error.TypeMismatch;
                return c.data.items.len;
            },
            else => return error.TypeMismatch,
        }
    }

    pub fn push_back(value: Value, allocator: std.mem.Allocator, elem: Value) !void {
        switch (value.impl) {
            .ContainerRef => |r| {
                if (r.container.kind != .Vec) return error.TypeMismatch;
                try r.container.data.append(allocator, (try elem.copy_value(allocator)).impl);
                if (r.is_global) {
                    if (r.global_status) |status| status.* = .Dirty;
                }
            },
            else => return error.TypeMismatch,
        }
    }

    pub fn pop_back(value: Value, allocator: std.mem.Allocator) !Value {
        switch (value.impl) {
            .ContainerRef => |r| {
                if (r.container.kind != .Vec) return error.TypeMismatch;
                const container_len = r.container.data.items.len;
                if (container_len == 0) return error.IndexOutOfBounds;
                var item = r.container.data.pop().?;
                errdefer item.deinit(allocator);
                const copied = try item.copy_value(allocator);
                item.deinit(allocator);
                if (r.is_global) {
                    if (r.global_status) |status| status.* = .Dirty;
                }
                return Value.init(copied);
            },
            else => return error.TypeMismatch,
        }
    }

    pub fn swap(value: Value, idx1: usize, idx2: usize) !void {
        switch (value.impl) {
            .ContainerRef => |r| {
                if (r.container.kind != .Vec) return error.TypeMismatch;
                const container_len = r.container.data.items.len;
                if (idx1 >= container_len or idx2 >= container_len) return error.IndexOutOfBounds;
                const tmp = r.container.data.items[idx1];
                r.container.data.items[idx1] = r.container.data.items[idx2];
                r.container.data.items[idx2] = tmp;
                if (r.is_global) {
                    if (r.global_status) |status| status.* = .Dirty;
                }
            },
            else => return error.TypeMismatch,
        }
    }

    pub fn unpack(value: Value, allocator: std.mem.Allocator, expected_len: usize) !std.ArrayList(Value) {
        switch (value.impl) {
            .Container => |c| {
                if (c.kind != .Vec) return error.TypeMismatch;
                if (c.data.items.len != expected_len) return error.TypeMismatch;
                var result = std.ArrayList(Value).empty;
                for (c.data.items) |item| {
                    try result.append(allocator, Value.init(try item.copy_value(allocator)));
                }
                return result;
            },
            else => return error.TypeMismatch,
        }
    }
};

// ==================== Tests ====================

test "Value copy and equals" {
    const allocator = std.testing.allocator;
    const v1 = Value.makeU64(42);
    const v2 = try v1.copy_value(allocator);
    try std.testing.expect(try v1.equals(v2));
}

test "IntegerValue arithmetic" {
    const a = IntegerValue{ .U64 = 10 };
    const b = IntegerValue{ .U64 = 3 };
    const sum = try IntegerValue.add_checked(a, b);
    try std.testing.expectEqual(@as(u64, 13), sum.U64);
    const diff = try IntegerValue.sub_checked(a, b);
    try std.testing.expectEqual(@as(u64, 7), diff.U64);
    const prod = try IntegerValue.mul_checked(a, b);
    try std.testing.expectEqual(@as(u64, 30), prod.U64);
    const quot = try IntegerValue.div_checked(a, b);
    try std.testing.expectEqual(@as(u64, 3), quot.U64);
    const rem = try IntegerValue.rem_checked(a, b);
    try std.testing.expectEqual(@as(u64, 1), rem.U64);
}

test "Struct pack and unpack" {
    const allocator = std.testing.allocator;
    const fields = [_]Value{ Value.makeU8(10), Value.makeU64(20) };
    var s = try StructValue.pack(allocator, &fields, types.AbilitySet.default());
    defer s.deinit(allocator);

    var unpacked = try StructValue.unpack(s, allocator);
    defer {
        for (unpacked.items) |*v| v.deinit(allocator);
        unpacked.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), unpacked.items.len);
    try std.testing.expectEqual(@as(u8, 10), unpacked.items[0].impl.U8);
    try std.testing.expectEqual(@as(u64, 20), unpacked.items[1].impl.U64);
}
