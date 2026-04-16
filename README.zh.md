# Move VM (Zig)

使用 Zig 0.16.0 实现的 Move 虚拟机，专注于 Move 语言字节码解释器和执行引擎。

## 项目概述

本项目实现了 Move 虚拟机的核心组件：
- 字节码指令集与执行
- 操作数栈管理
- 帧与局部变量处理
- Gas 计费与消耗
- 全局存储接口
- 模块与会话管理

## 参考实现

- [move-smith](https://github.com/aptos-labs/move-smith) - Rust Move VM 模糊测试工具
- [move-language/move](https://github.com/move-language/move) - 归档的参考实现
- [move-on-aptos](https://github.com/move-language/move-on-aptos) - 活跃开发分支
- [move-sui](https://github.com/move-language/move-sui) - Sui Move 实现

## 环境要求

- Zig 0.16.0

验证 Zig 版本：
```bash
zig version
# 预期输出: 0.16.0
```

## 构建与运行

```bash
# 编译项目
zig build

# 运行演示
zig build run

# 运行测试
zig build test
```

## 项目结构

```
src/
├── main.zig              # 入口点 + 演示
├── vm/
│   ├── mod.zig           # VM 模块导出
│   ├── opcodes.zig       # 操作码定义
│   ├── bytecode.zig     # 指令集 + Gas 成本
│   ├── frame.zig        # Value, Frame, Function, Type
│   ├── stack.zig        # 操作数栈
│   ├── interpreter.zig  # 执行循环
│   ├── module.zig       # 模块定义
│   ├── session.zig      # Session, MoveVM
│   └── native.zig        # 本地函数接口
├── gas/
│   └── gas.zig           # Gas 追踪器
└── storage/
    └── storage.zig      # 全局存储
```

## 核心组件

### 值类型
- 原始类型：Bool, U8, U16, U32, U64, U128, U256
- 复合类型：Address, Signer, Vector, Struct
- 引用类型：Reference, MutableReference

### 字节码指令
完整指令集包括：
- 栈操作：Push, Pop, Dup, Swap
- 算术运算：Add, Sub, Mul, Div, Mod
- 逻辑运算：And, Or, Xor, Not
- 控制流：Branch, Jump, Ret
- 局部访问：Moveto, Movefrom
- 全局操作：Exists, GetGlobal, SetGlobal

### 存储
- 全局状态映射（address → type_key → value）
- 资源存在性检查
- 值检索与存储

### Gas 模型
- 初始 Gas 追踪
- Gas 消耗追踪
- 剩余 Gas 查询
- Gas 不足错误处理

## 后续工作

- 本地函数调用
- 泛型函数实例化
- 类型检查器 / 字节码验证器
- 与 Move 编译器集成

## 许可证

本项目为研究实现。受限于参考仓库的原始 Move VM 许可证。