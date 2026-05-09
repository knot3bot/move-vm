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
- **Tests**: 70/70 passing, zero memory leaks

### Known Limitations
- Generic type parameter substitution is partial (resolves field counts and abilities from struct definitions, but does not replace TypeParameter with concrete types in field signatures)
- write_ref via copied IndexedRef has a known edge case
- Cross-module `Call` instructions use local function indices (no global function table linking)
- Constant pool (ld_const) is not fully implemented
- No concurrent execution support (single-threaded only)

### Todo
- Generic type parameter replacement in struct field signatures (TypeParameter -> concrete type)
- Cross-module `Call` instruction linking via global function table

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
