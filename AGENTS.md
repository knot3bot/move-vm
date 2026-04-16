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
├── vm/
│   ├── mod.zig        # VM module exports
│   ├── opcodes.zig    # Opcode enum (legacy)
│   ├── bytecode.zig   # Instruction definitions + gas costs
│   ├── frame.zig      # Value, Frame, Function, Type, Location, Instruction
│   ├── stack.zig     # Operand stack
│   ├── interpreter.zig # Main execution loop
│   ├── module.zig    # Module, FunctionHandle, StructDef, ModuleCache
│   ├── session.zig   # Session, MoveVM, VMConfig (needs fixes)
│   └── native.zig    # Native function interface
├── gas/
│   └── gas.zig        # Gas tracker with params
└── storage/
    └── storage.zig    # Global storage interface
```

## Implementation Status

### Completed
- **Value types**: Bool, U8-U256, Address, Signer, Vector, Struct, Reference, MutableReference
- **Bytecode**: Full instruction set with stack effects
- **Stack**: Operand stack with push/pop/peek operations
- **Frame**: Local variables, PC, type arguments, function, instruction
- **Gas**: Basic tracking with consume/remaining/used
- **Storage**: Global state map (address -> type_key -> value)
- **Module**: Module definitions, function handles, struct definitions
- **Interpreter**: Execution loop with instruction dispatch

### Known Issues
- session.zig has Zig 0.16.0 API incompatibilities (ArrayList init/deinit)
- Not fully integrated with main.zig (but working on it)

### Todo
- Fix session.zig for Zig 0.16.0 compatibility
- Native function calling
- Generic function instantiation
- Type checker / verifier

## Reference Sources

- [move-smith](https://github.com/aptos-labs/move-smith) - execution engine reference
- [move-language/move](https://github.com/move-language/move) - archived, official semantics
- [move-on-aptos](https://github.com/move-language/move-on-aptos) - active development
- [move-sui](https://github.com/move-language/move-sui) - active development

## Important Notes

- First work: set up `build.zig` + port core VM structures
- Study `msmith/src/execution` for the execution engine pattern
- Ask before architectural decisions - this is a port from Rust, not a rewrite