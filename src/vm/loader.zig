const std = @import("std");
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const FunctionDef = module_mod.FunctionDef;
const FunctionHandle = module_mod.FunctionHandle;
const frame = @import("frame.zig");
const Function = frame.Function;
const types = @import("types.zig");
const bytecode = @import("bytecode.zig");
const vm_verifier = @import("verifier.zig");

/// Compiled module: holds executable Functions derived from a Module.
pub const CompiledModule = struct {
    module_id: types.ModuleId,
    functions: []Function,
    function_names: [][]const u8,
    instantiated_functions: []Function,
    instantiated_function_ty_args: [][]types.Type,
    dependencies: []types.ModuleId,
    resolved_handles: []?*Function,
    resolved_struct_field_types: []types.ResolvedStructFieldTypes,

    pub fn deinit(self: *CompiledModule, allocator: std.mem.Allocator) void {
        for (self.functions) |*func| {
            func.deinit(allocator);
        }
        allocator.free(self.functions);
        allocator.free(self.function_names);
        for (self.instantiated_functions) |*func| {
            func.deinit(allocator);
        }
        allocator.free(self.instantiated_functions);
        for (self.instantiated_function_ty_args) |ty_args| {
            for (ty_args) |*ty| {
                ty.deinit(allocator);
            }
            allocator.free(ty_args);
        }
        allocator.free(self.instantiated_function_ty_args);
        allocator.free(self.dependencies);
        allocator.free(self.resolved_handles);
        for (self.resolved_struct_field_types) |rsft| {
            for (rsft.field_types) |*ty| {
                ty.deinit(allocator);
            }
            allocator.free(rsft.field_types);
        }
        allocator.free(self.resolved_struct_field_types);
    }
};

/// Loader: compiles Modules into executable Functions and caches them.
pub const Loader = struct {
    allocator: std.mem.Allocator,
    compiled_modules: std.StringHashMap(*CompiledModule),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .compiled_modules = std.StringHashMap(*CompiledModule).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.compiled_modules.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.compiled_modules.deinit();
    }

    /// Check if a module has been loaded.
    pub fn isModuleLoaded(self: Self, module_id: types.ModuleId) !bool {
        const module_key = try module_id.toString(self.allocator);
        defer self.allocator.free(module_key);
        return self.compiled_modules.contains(module_key);
    }

    /// Collect external module dependencies from a module's FunctionHandles.
    fn collectDependencies(self: Self, module: *const Module) !std.ArrayList(types.ModuleId) {
        var deps = std.ArrayList(types.ModuleId).empty;
        errdefer deps.deinit(self.allocator);

        for (module.functions.items) |handle| {
            // Skip self-references
            if (std.mem.eql(u8, handle.module.name, module.id.name) and
                std.mem.eql(u8, &handle.module.address, &module.id.address))
            {
                continue;
            }

            // Check if already in deps list
            var found = false;
            for (deps.items) |existing| {
                if (std.mem.eql(u8, existing.name, handle.module.name) and
                    std.mem.eql(u8, &existing.address, &handle.module.address))
                {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try deps.append(self.allocator, handle.module);
            }
        }

        return deps;
    }

    /// Validate that all external dependencies of a module are already loaded.
    fn validateDependencies(self: *Self, module: *const Module) !void {
        var deps = try collectDependencies(self.*, module);
        defer deps.deinit(self.allocator);

        for (deps.items) |dep| {
            const loaded = try self.isModuleLoaded(dep);
            if (!loaded) {
                return error.DependencyNotFound;
            }
        }
    }

    /// Compile a Module into executable Functions and cache.
    pub fn loadModule(self: *Self, module: *const Module) !void {
        const module_key = try module.id.toString(self.allocator);
        defer self.allocator.free(module_key);

        if (self.compiled_modules.contains(module_key)) {
            return; // Already loaded
        }

        // Validate all external dependencies are loaded first
        try self.validateDependencies(module);

        const compiled = try self.allocator.create(CompiledModule);
        errdefer self.allocator.destroy(compiled);

        const func_count = module.function_defs.items.len;
        const functions = try self.allocator.alloc(Function, func_count);
        var funcs_initialized: usize = 0;
        errdefer {
            for (0..funcs_initialized) |j| {
                functions[j].deinit(self.allocator);
            }
            self.allocator.free(functions);
        }

        const names = try self.allocator.alloc([]const u8, func_count);
        errdefer self.allocator.free(names);

        for (module.function_defs.items, 0..) |func_def, i| {
            const handle = if (func_def.handle < module.functions.items.len)
                module.functions.items[func_def.handle]
            else
                return error.InvalidFunctionIndex;

            var func = Function.init(self.allocator, handle.name);
            func.module = handle.module.name;
            func.module_address = handle.module.address;
            func.param_count = func_def.params;
            func.return_count = func_def.returns;
            func.local_count = func_def.local_count;
            func.is_native = func_def.is_native;
            func.struct_defs = module.struct_defs.items;
            func.type_signatures = module.type_signatures.items;
            func.struct_instantiations = module.struct_instantiations.items;
            func.constants = module.constants.items;
            func.function_handles = module.functions.items;

            // Convert type signature indices to types
            for (handle.param_types) |ty_idx| {
                if (ty_idx < module.type_signatures.items.len) {
                    const ty = try typeSignatureToType(module.type_signatures.items[ty_idx], module, self.allocator);
                    try func.param_types.append(self.allocator, ty);
                } else {
                    try func.param_types.append(self.allocator, .U64);
                }
            }
            for (handle.return_types) |ty_idx| {
                if (ty_idx < module.type_signatures.items.len) {
                    const ty = try typeSignatureToType(module.type_signatures.items[ty_idx], module, self.allocator);
                    try func.return_types.append(self.allocator, ty);
                } else {
                    try func.return_types.append(self.allocator, .U64);
                }
            }

            // Deep copy instructions
            for (func_def.code.instructions.items) |inst| {
                try func.code.push(self.allocator, inst);
            }

            functions[i] = func;
            names[i] = handle.name;
            funcs_initialized += 1;
        }

        // Resolve function handles to actual Function pointers for cross-module calls
        const resolved_handles = try self.allocator.alloc(?*Function, module.functions.items.len);
        errdefer self.allocator.free(resolved_handles);
        @memset(resolved_handles, null);

        for (module.functions.items, 0..) |handle, i| {
            if (std.mem.eql(u8, handle.module.name, module.id.name) and
                std.mem.eql(u8, &handle.module.address, &module.id.address))
            {
                // Local function: find in compiled functions array
                for (names, 0..) |fname, j| {
                    if (std.mem.eql(u8, fname, handle.name)) {
                        resolved_handles[i] = &functions[j];
                        break;
                    }
                }
            } else {
                // External function: look up in already-loaded modules
                if (try self.getFunctionByName(handle.module, handle.name)) |func| {
                    resolved_handles[i] = func;
                }
            }
        }

        // Attach resolved handles to all functions for verifier/interpreter use
        for (functions) |*func| {
            func.resolved_handles = resolved_handles;
        }

        // Compile function instantiations for generic calls
        const inst_count = module.function_instantiations.items.len;
        const inst_functions = try self.allocator.alloc(Function, inst_count);
        var inst_funcs_initialized: usize = 0;
        errdefer {
            for (0..inst_funcs_initialized) |j| {
                inst_functions[j].deinit(self.allocator);
            }
            self.allocator.free(inst_functions);
        }

        const inst_ty_args = try self.allocator.alloc([]types.Type, inst_count);
        var inst_ty_args_initialized: usize = 0;
        errdefer {
            for (0..inst_ty_args_initialized) |j| {
                for (inst_ty_args[j]) |*ty| ty.deinit(self.allocator);
                self.allocator.free(inst_ty_args[j]);
            }
            self.allocator.free(inst_ty_args);
        }

        for (module.function_instantiations.items, 0..) |func_inst, i| {
            const base_func = if (func_inst.handle < module.function_defs.items.len)
                module.function_defs.items[func_inst.handle]
            else
                return error.InvalidFunctionIndex;

            const handle = if (base_func.handle < module.functions.items.len)
                module.functions.items[base_func.handle]
            else
                return error.InvalidFunctionIndex;

            var func = Function.init(self.allocator, handle.name);
            func.module = handle.module.name;
            func.module_address = handle.module.address;
            func.param_count = base_func.params;
            func.return_count = base_func.returns;
            func.local_count = base_func.local_count;
            func.is_native = base_func.is_native;
            func.struct_defs = module.struct_defs.items;
            func.type_signatures = module.type_signatures.items;
            func.struct_instantiations = module.struct_instantiations.items;
            func.constants = module.constants.items;

            for (handle.param_types) |ty_idx| {
                if (ty_idx < module.type_signatures.items.len) {
                    const ty = typeSignatureToType(module.type_signatures.items[ty_idx], module, self.allocator) catch .U64;
                    try func.param_types.append(self.allocator, ty);
                } else {
                    try func.param_types.append(self.allocator, .U64);
                }
            }
            for (handle.return_types) |ty_idx| {
                if (ty_idx < module.type_signatures.items.len) {
                    const ty = typeSignatureToType(module.type_signatures.items[ty_idx], module, self.allocator) catch .U64;
                    try func.return_types.append(self.allocator, ty);
                } else {
                    try func.return_types.append(self.allocator, .U64);
                }
            }

            for (base_func.code.instructions.items) |inst| {
                try func.code.push(self.allocator, inst);
            }

            inst_functions[i] = func;
            inst_funcs_initialized += 1;
            inst_ty_args[i] = try self.allocator.alloc(types.Type, func_inst.type_args.len);
            inst_ty_args_initialized += 1;
            errdefer self.allocator.free(inst_ty_args[i]);
            for (func_inst.type_args, 0..) |ty_idx, j| {
                if (ty_idx < module.type_signatures.items.len) {
                    inst_ty_args[i][j] = try typeSignatureToType(module.type_signatures.items[ty_idx], module, self.allocator);
                } else {
                    inst_ty_args[i][j] = .U64;
                }
            }
        }

        // Pre-compute resolved field types for generic struct instantiations (TypeParameter -> concrete type)
        const resolved_struct_field_types = try self.allocator.alloc(types.ResolvedStructFieldTypes, module.struct_instantiations.items.len);
        errdefer {
            for (resolved_struct_field_types) |*rsft| {
                for (rsft.field_types) |*ty| ty.deinit(self.allocator);
                self.allocator.free(rsft.field_types);
            }
            self.allocator.free(resolved_struct_field_types);
        }
        for (module.struct_instantiations.items, 0..) |inst, i| {
            if (inst.def >= module.struct_defs.items.len) {
                return error.InvalidStructDef;
            }
            const def = module.struct_defs.items[inst.def];
            const field_types = try self.allocator.alloc(types.Type, def.fields.items.len);
            for (def.fields.items, 0..) |field, j| {
                field_types[j] = try typeSignatureToTypeImpl(field.type_signature, module, self.allocator, inst.type_args);
            }
            resolved_struct_field_types[i] = .{ .field_types = field_types };
        }

        // Attach resolved struct field types to all functions
        for (functions) |*func| {
            func.resolved_struct_field_types = resolved_struct_field_types;
        }

        // Collect dependencies
        var deps = try collectDependencies(self.*, module);
        defer deps.deinit(self.allocator);
        const dep_slice = try self.allocator.dupe(types.ModuleId, deps.items);

        compiled.* = .{
            .module_id = module.id,
            .functions = functions,
            .function_names = names,
            .instantiated_functions = inst_functions,
            .instantiated_function_ty_args = inst_ty_args,
            .dependencies = dep_slice,
            .resolved_handles = resolved_handles,
            .resolved_struct_field_types = resolved_struct_field_types,
        };

        // Verify all functions before caching
        for (functions) |*func| {
            try vm_verifier.verifyFunction(self.allocator, func, functions, inst_functions, 1024);
        }
        for (inst_functions) |*func| {
            try vm_verifier.verifyFunction(self.allocator, func, functions, inst_functions, 1024);
        }

        const key_copy = try self.allocator.dupe(u8, module_key);
        errdefer self.allocator.free(key_copy);
        try self.compiled_modules.put(key_copy, compiled);
    }

    /// Load multiple modules in dependency order.
    pub fn loadModules(self: *Self, modules: []const *const Module) !void {
        for (modules) |mod| {
            try self.loadModule(mod);
        }
    }

    /// Convert a TypeSignature to a runtime Type, optionally substituting TypeParameters.
    fn typeSignatureToTypeImpl(ts: module_mod.TypeSignature, module: *const module_mod.Module, allocator: std.mem.Allocator, type_args: ?[]const u16) !types.Type {
        return switch (ts) {
            .Bool => .Bool,
            .U8 => .U8,
            .U16 => .U16,
            .U32 => .U32,
            .U64 => .U64,
            .U128 => .U128,
            .U256 => .U256,
            .Address => .Address,
            .Signer => .Signer,
            .TypeParameter => |idx| {
                if (type_args) |args| {
                    if (idx < args.len) {
                        const concrete_idx = args[idx];
                        if (concrete_idx < module.type_signatures.items.len) {
                            return typeSignatureToTypeImpl(module.type_signatures.items[concrete_idx], module, allocator, null);
                        }
                    }
                }
                return .{ .TypeParameter = idx };
            },
            .Vector => |idx| {
                if (idx >= module.type_signatures.items.len) return error.InvalidType;
                const inner = try typeSignatureToTypeImpl(module.type_signatures.items[idx], module, allocator, type_args);
                const ptr = try allocator.create(types.Type);
                ptr.* = inner;
                return .{ .Vector = ptr };
            },
            .Struct => |idx| {
                if (idx >= module.struct_defs.items.len) return error.InvalidType;
                const def = module.struct_defs.items[idx];
                const field_types = try allocator.alloc(types.Type, def.fields.items.len);
                errdefer allocator.free(field_types);
                for (def.fields.items, 0..) |field, i| {
                    field_types[i] = try typeSignatureToTypeImpl(field.type_signature, module, allocator, type_args);
                }
                return .{ .Struct = .{ .handle = idx, .field_types = field_types } };
            },
            .Reference => |idx| {
                if (idx >= module.type_signatures.items.len) return error.InvalidType;
                const inner = try typeSignatureToTypeImpl(module.type_signatures.items[idx], module, allocator, type_args);
                const ptr = try allocator.create(types.Type);
                ptr.* = inner;
                return .{ .Reference = ptr };
            },
            .MutableReference => |idx| {
                if (idx >= module.type_signatures.items.len) return error.InvalidType;
                const inner = try typeSignatureToTypeImpl(module.type_signatures.items[idx], module, allocator, type_args);
                const ptr = try allocator.create(types.Type);
                ptr.* = inner;
                return .{ .MutableReference = ptr };
            },
        };
    }

    fn typeSignatureToType(ts: module_mod.TypeSignature, module: *const module_mod.Module, allocator: std.mem.Allocator) !types.Type {
        return typeSignatureToTypeImpl(ts, module, allocator, null);
    }

    /// Get a function by module ID and function index.
    pub fn getFunction(self: Self, module_id: types.ModuleId, func_idx: u16) !?*Function {
        const module_key = try module_id.toString(self.allocator);
        defer self.allocator.free(module_key);

        const compiled = self.compiled_modules.get(module_key) orelse return null;
        if (func_idx >= compiled.functions.len) return null;
        return &compiled.functions[func_idx];
    }

    /// Get a function by module ID and function name.
    pub fn getFunctionByName(self: Self, module_id: types.ModuleId, name: []const u8) !?*Function {
        const module_key = try module_id.toString(self.allocator);
        defer self.allocator.free(module_key);

        const compiled = self.compiled_modules.get(module_key) orelse return null;
        for (compiled.function_names, 0..) |fname, i| {
            if (std.mem.eql(u8, fname, name)) {
                return &compiled.functions[i];
            }
        }
        return null;
    }

    /// Get all functions for a module as a slice (for function table passing).
    pub fn getFunctions(self: Self, module_id: types.ModuleId) !?[]Function {
        const module_key = try module_id.toString(self.allocator);
        defer self.allocator.free(module_key);

        const compiled = self.compiled_modules.get(module_key) orelse return null;
        return compiled.functions;
    }

    /// Get instantiated functions for a module.
    pub fn getInstantiatedFunctions(self: Self, module_id: types.ModuleId) !?[]Function {
        const module_key = try module_id.toString(self.allocator);
        defer self.allocator.free(module_key);

        const compiled = self.compiled_modules.get(module_key) orelse return null;
        return compiled.instantiated_functions;
    }

    /// Get instantiated function type arguments for a module.
    pub fn getInstantiatedFunctionTyArgs(self: Self, module_id: types.ModuleId) !?[][]types.Type {
        const module_key = try module_id.toString(self.allocator);
        defer self.allocator.free(module_key);

        const compiled = self.compiled_modules.get(module_key) orelse return null;
        return compiled.instantiated_function_ty_args;
    }

    /// Get the dependencies of a loaded module.
    pub fn getModuleDependencies(self: Self, module_id: types.ModuleId) !?[]const types.ModuleId {
        const module_key = try module_id.toString(self.allocator);
        defer self.allocator.free(module_key);

        const compiled = self.compiled_modules.get(module_key) orelse return null;
        return compiled.dependencies;
    }

    /// Resolve a function across any loaded module.
    pub fn resolveFunction(self: Self, module_id: types.ModuleId, function_name: []const u8) !?*Function {
        return try self.getFunctionByName(module_id, function_name);
    }
};
