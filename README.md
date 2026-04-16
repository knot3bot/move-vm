# Move VM (Zig)

A Move VM implementation written in Zig 0.16.0, targeting the Move language bytecode interpreter and execution engine.

## Overview

This project implements the core components of the Move virtual machine:
- Bytecode instruction set and execution
- Operand stack management
- Frame and local variable handling  
- Gas metering and consumption
- Global storage interface
- Module and session management

## Based On

- [move-smith](https://github.com/aptos-labs/move-smith) - Rust fuzzer for Move VM
- [move-language/move](https://github.com/move-language/move) - Archived reference implementation
- [move-on-aptos](https://github.com/move-language/move-on-aptos) - Active development
- [move-sui](https://github.com/move-language/move-sui) - Sui Move implementation

## Requirements

- Zig 0.16.0

Verify your Zig version:
```bash
zig version
# Expected: 0.16.0
```

## Building

```bash
# Compile the project
zig build

# Run the demo
zig build run

# Run tests
zig build test
```

## Project Structure

```
src/
├── main.zig              # Entry point with demo
├── vm/
│   ├── mod.zig           # VM module exports
│   ├── opcodes.zig       # Opcode definitions
│   ├── bytecode.zig     # Instruction set + gas costs
│   ├── frame.zig        # Value, Frame, Function, Type
│   ├── stack.zig        # Operand stack
│   ├── interpreter.zig   # Execution loop
│   ├── module.zig       # Module definitions
│   ├── session.zig      # Session, MoveVM
│   └── native.zig        # Native function interface
├── gas/
│   └── gas.zig           # Gas tracker
└── storage/
    └── storage.zig      # Global storage
```

## Core Components

### Value Types
- Primitive: Bool, U8, U16, U32, U64, U128, U256
- Composite: Address, Signer, Vector, Struct
- Reference: Reference, MutableReference

### Bytecode Instructions
Full instruction set including:
- Stack operations: Push, Pop, Dup, Swap
- Arithmetic: Add, Sub, Mul, Div, Mod
- Logical: And, Or, Xor, Not
- Control flow: Branch, Jump, Ret
- Local access: Moveto, Movefrom
- Global operations: Exists, GetGlobal, SetGlobal

### Storage
- Global state map (address → type_key → value)
- Resource existence checks
- Value retrieval and storage

### Gas Model
- Initial gas tracking
- Consumption tracking
- Remaining gas queries
- Out-of-gas error handling

## Future Work

- Native function calling
- Generic function instantiation  
- Type checker / bytecode verifier
- Integration with Move compiler

## License

This is a research implementation. See reference repositories for original Move VM licensing.