<!-- From: /Users/cborli/ws_zig/move-vm/AGENTS.md -->
# AGENTS.md - move-vm

## Project Overview

Greenfield Zig 0.16.0 implementation of Move VM core (bytecode verification + execution). Based on [move-smith](https://github.com/aptos-labs/move-smith) (Rust fuzzer) and [move-language/move](https://github.com/move-language/move) (archived reference).

## Key Constraints

- **Language**: Zig 0.16.0 (verify with `zig version`)
- **Scope**: VM core only - bytecode interpreter, gas calculation, storage interface
- **Out of scope**: Prover, compiler, other verification tools

## Development Commands

```bash
zig build          # Compile
zig build run      # Run executable
zig build test     # Run tests
zig fmt            # Format code
```

## Architecture

Current structure:
```
src/
├── main.zig           # Entry point + demos
├── tests.zig          # Integration and unit tests (test root)
├── vm/
│   ├── mod.zig        # VM module exports
│   ├── bytecode.zig   # Instruction definitions + gas costs
│   ├── values.zig     # Value/ValueImpl/Container/Ref/IntegerValue + Struct/Vector helpers
│   ├── locals.zig     # Locals management for frames
│   ├── types.zig      # Type, TypeTag, AbilitySet, Location, ModuleId
│   ├── frame.zig      # Frame, Function
│   ├── stack.zig      # Operand stack
│   ├── interpreter.zig # Main execution loop with ExitCode pattern
│   ├── verifier.zig   # Bytecode verifier (operand stack + type checking)
│   ├── loader.zig     # Module compiler + function resolver + generic instantiation
│   ├── module.zig     # Module, FunctionHandle, StructDef, ModuleCache
│   ├── session.zig    # Session, MoveVM, VMConfig
│   └── native.zig     # Native function interface + built-in implementations
├── gas/
│   └── gas.zig        # Gas tracker
└── storage/
    └── storage.zig    # DataStore (global storage interface)
```

## Implementation Status

### Completed
- **Value types**: Full Value/ValueImpl/Container/ContainerRef/IndexedRef hierarchy
- **Arithmetic**: All integer types (U8-U256) with checked operations
- **Locals**: copy_loc, move_loc, store_loc, borrow_loc with reference semantics
- **Operand Stack**: push/pop/pop_as/popn/last_n
- **Bytecode**: Full instruction set with stack effects and gas costs
- **Interpreter**: execute_main loop with ExitCode pattern (Return/Call/CallGeneric)
- **Struct/Vector**: Pack/unpack (including generic), vec_push_back, vec_pop_back, vec_len, vec_swap, vec_imm_borrow, vec_mut_borrow
- **Reference operations**: read_ref, write_ref, freeze_ref, borrow_loc, mut_borrow_field, imm_borrow_field (including generic variants)
- **Casts**: CastU8-CastU256
- **Control flow**: BrTrue/BrFalse/Branch/Call/CallGeneric/Abort/Ret
- **Function calls**: Full frame creation with locals + cross-function calls
- **Gas**: Per-instruction gas metering
- **Global storage**: move_to, move_from, exists, borrow_global (mut/imm) with deep-copy semantics (including generic variants)
- **Bytecode verifier**: Operand stack type tracking, depth checking, branch merge consistency, worklist-based CFG analysis
- **Loader/Resolver**: Compiles Module → executable Function array, caches by ModuleId, supports CallGeneric with type instantiations, multi-module dependency validation
- **Native functions**: Framework (registration/lookup) + built-ins: nativeAdd, nativeSignerBorrowAddress, nativeSha3_256, nativeBcsToBytes, nativeEventEmit
- **Session/MoveVM API**: Full API with Loader integration, native function registry, event collection, and transaction semantics
- **Generic operations**: Module context integration for pack_generic/unpack_generic/move_to_generic — resolves field counts and abilities from StructDefInstantiation
- **Runtime ability checking**: copy_loc (can_copy), pop/store_loc (can_drop), move_to (is_key), write_ref (can_store)
- **Runtime reference counting/lifetime validation**: Container-level `ref_count` tracking prevents UAF via `canDrop` (blocks pop/st_loc on referenced containers), `write_ref` guards (blocks whole-container write when `ref_count > 1`, blocks element overwrite when nested container has active refs), and `copy_value`/`deinit` ref-count bookkeeping for all `ContainerRef`/`IndexedRef` values
- **Error-path UAF prevention**: Operand stack cleared before locals on interpreter error/abort, ensuring outstanding references decrement ref_counts before their backing containers are destroyed
- **Storage API safety**: `getGlobalPtr` returns `?*Value` for borrows (prevents accidental deinit of stored containers); `borrow_global` increments `container.ref_count`
- **Data-size gas scaling**: Proportional gas charges for linear-time operations (`eq`/`neq`, `pack`/`pack_generic`, `vec_pack`, `move_to`, `copy_loc`, `read_ref`, `write_ref`)
- **Native function gas hardening**: Minimum gas charged on failure path; `nativeSha3_256` scales with input size
- **Type resolution strictness**: Loader uses `try` propagation for all type resolution — no silent fallback to `.U64`
- **Transaction atomicity**: Storage `removeGlobal` propagates errors; Session captures events before storage commit with `errdefer` rollback
- **ModuleCache key duplication**: Keys duplicated before HashMap insertion (fixes dangling pointer UAF)
- **OOM leak fixes**: `callee_locals`, `executeMain` return values, `move_to` resource copies all have `errdefer`/`defer` guards
- **32-bit safety / intCast panics**: `vec_swap`, `vec_imm_borrow`, `vec_mut_borrow` check bounds before `@intCast`; `NativeFunctions.register` checks max u16; verifier validates `vec_pack`/`vec_unpack` counts
- **Storage memory hygiene**: `DataStore.deinit` frees all module values and active change logs; `logChange` has `errdefer` for `old_copy`
- **Abort code propagation**: `session.zig` captures `error.Aborted` and returns `ExecutionResult` with `abort_code`; `executeNative` propagates native abort codes via `last_abort_code`
- **Module struct abilities in `pack`**: `.pack` instruction now uses `struct_defs[def_idx].abilities` instead of hardcoded defaults; verifier and interpreter both resolve field counts from struct definitions
- **Verification cache**: `Interpreter` maintains `verified_set` (HashMap by function pointer) to skip redundant bytecode verification, preventing repeated gas consumption
- **Native function signature verification**: Verifier checks `param_count`/`return_count`/`local_count` consistency for native functions instead of skipping entirely
- **Cross-module call type checking**: Verifier type-checks arguments for `.call` when callee is resolved via `resolved_handles` or found in `functions` array
- **Stack memory leak fixes**: `Stack.popn` deinits original slots before shrinking; `Stack.deinit`/`clearAndDeinit` iterate top-down to drop references before targets
- **Container lifetime hardening**: `Container.deinit` uses `@panic` (all builds) when `ref_count != 0`; `IndexedRef` read/write check bounds before access
- **OOM-path leak fixes**: `VectorValue.pop_back`, `Container.copy_value`, `StructValue.pack`, `VectorValue.pack` all have `errdefer` guards for partial-allocation failures
- **Gas metering integer safety**: All data-size gas calculations use `@as(u64, ...)` widening to prevent `u16`/`usize` overflow before consumption
- **Rollback hardening**: `rollbackTransaction` propagates `setGlobalInternal` errors instead of swallowing; `DataStore.deinit` cleans up active transaction logs
- **Locals allocation gas metering**: `Locals.new` is charged proportional to `local_count` in both `executeFunction` and `.Call`/`.CallGeneric` paths
- **Empty address map cleanup**: `removeGlobalInternal`/`takeGlobalInternal` delete the outer address entry when the inner map becomes empty
- **Nested unpack leak fix**: `.unpack`/`.unpack_generic` defer blocks now deinit all unpacked values before freeing the ArrayList buffer
- **Global borrow safety**: `setGlobalInternal`/`removeGlobalInternal`/`takeGlobalInternal` check `Container.ref_count > 0` and return `error.BorrowedResource` to prevent pointer invalidation
- **Global write transaction logging**: `.write_ref` on a `borrow_global` result calls `store.logChange` before mutating, ensuring rollback can restore the old value
- **ContainerRef global tracking**: `ContainerRef` carries duplicated `global_address`/`global_type_key` for transaction logging; `copy_value` deep-copies these strings; `deinit` frees them
- **Tests**: 105/105 passing, zero memory leaks
- **Transaction nesting**: `DataStore` supports nested transactions via a stack of change logs; inner commits merge into parent, inner rollbacks restore only their own scope
- **`ld_const` type verification**: Verifier reads constant pool type signature and pushes correct `TypeTag` instead of `null`, enabling strict type checking for constant-loaded values
- **`ld_const` full integer coverage**: `parseConstant` supports Bool, U8, U16, U32, U64, U128, U256, Address; tests cover all integer types and cross-type mismatch detection

### Known Limitations
- ~~Generic type parameter substitution is partial~~ **Fixed**: Verifier now type-checks `.pack`/`.pack_generic` fields against `struct_defs`/`resolved_struct_field_types`, and `.unpack_generic` pushes concrete field types instead of `null`
- Runtime borrow checker is defense-only (ref_count), not a full compile-time lifetime analysis — certain complex reference patterns may still pass runtime checks but violate Move semantics
- Cross-module `Call` instructions use local function indices (no global function table linking)
- Constant pool (`ld_const`) supports primitive types only; Vector/Struct constants are not yet implemented
- No concurrent execution support (single-threaded only)
- Verifier unresolved handle bypass: When `call` handle is unresolved, verifier pushes `null` types, bypassing cross-module type checking

### Todo
- (empty — all planned items completed)

## Reference Sources

- [move-smith](https://github.com/aptos-labs/move-smith) - execution engine reference
- [move-language/move](https://github.com/move-language/move) - archived, official semantics
- [move-on-aptos](https://github.com/move-language/move-on-aptos) - active development
- [move-sui](https://github.com/move-language/move-sui) - active development

## Important Notes

- First work: set up `build.zig` + port core VM structures
- Study `msmith/src/execution` for the execution engine pattern
- Ask before architectural decisions - this is a port from Rust, not a rewrite
- All code must compile with Zig 0.16.0 (`zig build test` must pass)
