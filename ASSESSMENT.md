# move-vm 综合评估报告

> 评估维度：架构 · 性能 · 安全 · Zig 0.16.0 最佳实践  
> 代码版本：`202d4d3` (v0.1.0) → 性能加固后  
> 测试状态：**105/105 passing，zero leaks**

---

## 一、架构层面

### 1.1 设计亮点 ✅

| 设计 | 评价 |
|------|------|
| `resolved_struct_field_types` 预计算 | 优秀的架构决策。Loader 在模块编译期完成 `TypeParameter → concrete` 替换，避免运行时递归解析。 |
| `Interpreter.verified_set` 缓存 | 合理的性能/安全权衡。用函数指针做 key 跳过重复 verifier 调用，同时避免重新消耗 gas。 |
| 嵌套事务 change_log 栈 | 清晰的层级语义。内层 commit merge、内层 rollback isolate，符合数据库 SAVEPOINT 模型。 |
| `Value` / `ValueImpl` 分离 | 良好。`Value` 作为公共包装器，`ValueImpl` 承载 union，使 API 和内部表示解耦。 |

### 1.2 耦合与分层问题 ⚠️

#### A. `Function` 承担过多角色
**位置**：`src/vm/frame.zig:8-28`

`Function` 同时是：
- 字节码执行单元（`code`, `param_count`, `local_count`）
- 模块上下文代理（`struct_defs`, `type_signatures`, `struct_instantiations`, `resolved_struct_field_types`）
- 跨模块调用描述符（`function_handles`, `resolved_handles`）
- 常量池容器（`constants`）

**影响**：一个函数的 `Function` 实例大小依赖整个模块的元数据量。如果模块有 100 个 struct，每个 `Function` 都携带全部 `struct_defs` 切片引用。

**建议**：将模块级上下文提取为 `*const ModuleContext` 指针，Function 只保留一个指针，而非 7 个切片字段。

```zig
pub const Function = struct {
    // ... execution fields ...
    module_ctx: *const ModuleContext, // 替换所有 struct_defs / type_signatures / ...
};
```

#### B. `Locals` 用 `Container` 做 backing store 引入过度抽象
**位置**：`src/vm/locals.zig:10-11`

Locals 本质上是一个固定大小的 `[]ValueImpl` 数组，却通过 `Container.new(.Vec)` 分配。这带来：
- 额外的 heap allocation（`Container` struct + `ArrayList` buffer）
- 运行时 bounds check 转移到 `Container.data.items.len`
- `borrow_loc` 对非-Container 值创建 `IndexedRef`，增加引用计数管理负担

**建议**：Locals 直接使用 `[]ValueImpl` 或 `std.ArrayList(ValueImpl)`，仅在需要 borrow 时才按需包装为 `Container`。或者使用 `ArrayListUnmanaged` 避免内部 allocator 指针。

#### C. `DataStore` 与 `Value` 类型紧耦合
**位置**：`src/storage/storage.zig`

`DataStore` 直接操作 `values.Value`，通过 `val.impl == .Container` 判断引用状态。这导致存储层必须了解 VM 值类型的内部结构。

**建议**：存储层应只接收 `[]const u8`（序列化后的 BCS 字节）+ metadata。VM 层负责序列化/反序列化。这在未来支持持久化存储时尤为重要。

#### D. `Interpreter` 字段设置模式繁琐
**位置**：`src/vm/interpreter.zig:130-180`

`Interpreter` 需要连续调用 6-7 个 `setXxx` 方法才能进入可用状态：
```zig
interp.setStorage(store);
interp.setNativeFunctions(natives);
interp.setEvents(&events);
interp.setInstantiatedFunctions(inst_funcs);
interp.setInstantiatedFunctionTyArgs(inst_ty_args);
interp.setLoader(loader);
```

**建议**：提供一个 `Interpreter.Config` 结构体，一次性初始化：
```zig
const config = Interpreter.Config{
    .storage = store,
    .native_functions = natives,
    // ...
};
var interp = try Interpreter.init(allocator, config);
```

#### E. `mod.zig` 是纯粹的 re-export，无聚合价值
**位置**：`src/vm/mod.zig`

当前 `mod.zig` 只是 `@import` 列表。建议至少提供 `VM` 顶层聚合类型，或统一的 `init`/`deinit` 入口。

---

## 二、性能层面

### 2.1 关键热点 🔴

#### A. 每指令拷贝 40+ 字节的 `Instruction` union ✅ 已修复
**位置**：`src/vm/interpreter.zig:575`

`executeCode`、`executeInstruction`、`chargeDataSizeGas`、`instructionGasCost` 全部改为接收 `*const bytecode.Instruction`，dispatch 只拷贝 8 字节指针。

#### B. `Stack.popn` 每次 pack/unpack 都堆分配临时数组 ✅ 已修复（保留堆分配，修复 aliasing bug）
**位置**：`src/vm/stack.zig:68-81`

零分配版本（返回内部 slice）被发现会导致 aliasing bug：返回的 slice 会被后续 `push` 覆盖。已恢复 `allocator.alloc` + `memcpy` 模式，同时保留 `initCapacity` 预分配以减少 ArrayList 内部 reallocation。

#### C. `logChange` 对同一 key 重复 deep-copy ✅ 已修复
**位置**：`src/storage/storage.zig:121-140`

`logChange` 现在先扫描当前事务 log，如果同一 `(address, type_key)` 已存在则直接返回，避免重复 deep-copy。

#### D. Native 函数结果双重复制 ✅ 已修复
**位置**：`src/vm/interpreter.zig:233,349`

`executeNative` 现在直接返回 `native_result.values`（转移所有权），不再内部 `dupe`。`.Call`/`.CallGeneric` 和 `executeFunction` 入口路径同步更新，消除第二次 `dupe`。
#### E. 存储 key 双重分配
**位置**：`src/vm/interpreter.zig:1038-1040` + `src/storage/storage.zig:162,175`

Interpreter 用 `std.fmt.allocPrint` 分配 `addr_key`/`type_key`（临时），`setGlobalInternal` 立即 `dupe` 一份持久副本。每个 global 操作浪费 2 次字符串分配。

**修复方向**：添加所有权转移 API：
```zig
pub fn setGlobalOwned(self: *DataStore, address: []u8, type_key: []u8, value: Value) !void {
    // takes ownership of address/type_key, no dupe needed
}
```

### 2.2 中等影响 ⚠️

| 问题 | 位置 | 修复 | 状态 |
|------|------|------|------|
| Stack/Container 零初始容量 | `stack.zig:16`, `values.zig:28` | 使用 `initCapacity` 预分配 | ✅ 已修复 |
| Gas getters 按值传递 | `gas.zig` | 改为 `*const Gas` | ✅ 已修复 |
| `ModuleCache` ID 字符串 double-alloc | `module.zig:147-151` | 直接使用 `toString` 结果作为 key | 待修复 |
| `ModuleId.toString` 逐字节 hex 编码 | `types.zig:119-130` | 预分配 `64 + 2 + name.len` 后用 `std.fmt.bufPrint` | 待修复 |

### 2.3 数据结构设计建议

#### `Container.data` 小向量优化
当前每个 `Container` 需要 2 次 heap alloc（Container struct + ArrayList buffer）。对于小型 struct（2-4 字段），指针追踪开销严重。

**可选方案**：
- 预分配容量（已知 field/element 数量时）
- 使用 `std.heap.ArenaAllocator` 按模块/交易统一分配，批量释放

#### `Bytecode` 指令存储
`ArrayList(Instruction)` 对存储是足够的。真正的问题是 dispatch 拷贝（§2.1A）。如果未来需要更高性能，可考虑将 `Instruction` 压缩为 tagged enum + 变长 payload，或使用 direct threading（Zig 中可通过 `comptime` 生成跳转表）。

---

## 三、安全层面

### 3.1 已验证的安全机制 ✅

| 机制 | 状态 |
|------|------|
| 整数算术 checked math | ✅ `std.math.add/sub/mul/divTrunc/rem` |
| Shift amount 溢出检查 | ✅ `shl_checked` 先比较 `>= bit_width` |
| Stack bounds | ✅ `Stack.push` / `pop` / `peekOffset` 都检查 |
| Local index bounds | ✅ `Locals.copy_loc` / `move_loc` / `store_loc` / `borrow_loc` |
| `IndexedRef` bounds | ✅ `read_ref` / `write_ref` 检查 `idx >= len` |
| Global borrow 冲突 | ✅ `setGlobalInternal` / `removeGlobalInternal` 检查 `ref_count > 0` |
| Container UAF 防护 | ✅ `Container.deinit` `@panic` 当 `ref_count != 0` |
| 零除检查 | ✅ `div_checked` / `rem_checked` 检查 `b.isZero()` |

### 3.2 潜在风险 ⚠️

#### A. `ref_count` 可溢出（理论风险）✅ 已修复
**位置**：`src/vm/values.zig:16`

已添加 `Container.addRef()` / `Container.releaseRef()` 方法，在 `maxInt(u32)` 时 panic，在 `0` 时 panic。所有 raw `ref_count +=/-= 1` 的调用点已替换为 `addRef()` / `releaseRef()`。

#### B. `eq` 对深层 Container 递归比较可能栈溢出 ✅ 已修复
**位置**：`src/vm/values.zig:76-83`

`Container.equals` 和 `ValueImpl.equals` 已添加递归深度限制（`MAX_DEPTH = 64`），超过时返回 `error.TypeMismatch`。

#### C. `verified_set` 使用裸指针存在 lifetime 风险
**位置**：`src/vm/interpreter.zig:310-311`

```zig
const func_ptr = @intFromPtr(func);
if (!self.verified_set.contains(func_ptr)) {
```

如果 `Function` 被重新分配（如 ModuleCache 淘汰后重新加载），新分配的 `Function` 可能获得相同的地址，导致错误命中缓存。

**修复**：使用模块 ID + 函数名的字符串作为 key，或存储验证时的 generation counter。

#### D. `catch {}` 静默忽略关键错误
**位置**：`src/vm/session.zig:108,128,196,215`

```zig
errdefer self.storage.rollbackTransaction() catch {};
```

如果 rollback 失败（如 `BorrowedResource`），事务实际上未回滚，但 Session 仍返回 `Aborted` 或错误。调用者可能认为状态已恢复。

**修复**：至少记录日志。在 Debug 模式下应 `std.log.err` 或 `std.debug.assert`。

#### E. `stack.zig:30` `@intCast` 隐含 panic
```zig
pub fn len(self: Stack) u32 {
    return @intCast(self.values.items.len);
}
```

`items.len` 是 `usize`。在 64 位系统上，如果 stack 被恶意增长到 > 2^32（虽然 `max_size` 限制应阻止），`@intCast` 会 panic。

**评估**：`max_size` 是 `u32`，`push` 检查 `items.len >= max_size`，所以实际安全。但防御式编程建议：
```zig
return std.math.cast(u32, self.values.items.len) orelse std.math.maxInt(u32);
```

#### F. `executeMain` 返回空切片存在悬空风险
**位置**：`src/vm/interpreter.zig:568`
```zig
return .{ .values = &.{}, .gas_used = gas_meter.getUsed() };
```

返回 `&[]`（空切片）是安全的（指向空数组的 sentinel），但调用者可能会 `deinit` 它，而 `deinit` 会 `allocator.free(self.values)`。如果 `values` 是 `&[]`（栈上临时空数组），`free` 会 panic。

**验证**：`ExecutionResult.deinit` 执行 `allocator.free(self.values)`。如果 `values` 来自 `&[]{}`（编译期空数组），`allocator.free` 不会 panic（Zig 会检测到非堆分配并 panic）。

**建议**：统一返回 `allocator.alloc` 的结果，即使是空返回值也 alloc 0 长度，或让 `deinit` 特殊处理空切片。

---

## 四、Zig 0.16.0 最佳实践

### 4.1 做得好的 ✅

| 实践 | 评价 |
|------|------|
| Allocator 显式传递 | 所有函数都接收 `std.mem.Allocator`，无隐藏全局分配器 |
| `init`/`deinit` 成对 | 几乎所有有堆分配的结构体都有匹配的 deinit |
| `build.zig` 现代 API | 使用 `b.createModule`、`b.addExecutable` 等新 API |
| 无 `anytype` | 代码中没有滥用 `anytype`，类型签名清晰 |
| 错误集设计 | `VMError` 统一了执行层错误，verifier 有独立的 `VerifierError` |

### 4.2 可改进项 ⚠️

#### A. `comptime` 使用严重不足
**当前唯一使用**：`Stack.popAs`（`comptime T: type`）

大量重复代码可用 `comptime` 消除：
- `IntegerValue.add_checked` / `sub_checked` / `mul_checked` — 除运算符外完全相同
- `cast_u8` / `cast_u16` / ... — 除目标类型外完全相同
- `ld_u8` / `ld_u16` / ... 指令处理 — 除类型外完全相同

**示例重构**：
```zig
fn checkedOp(comptime Op: fn (type, anytype, anytype) anytype, a: IntegerValue, b: IntegerValue) !IntegerValue {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
    return switch (a) {
        inline else => |x, tag| {
            const T = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = @intFromEnum(tag) } });
            // 或维护一个 comptime 映射表
            return @unionInit(IntegerValue, @tagName(tag), try Op(T, x, @field(b, @tagName(tag))));
        },
    };
}
```

#### B. 未利用 `ArrayListUnmanaged`
**位置**：`src/vm/values.zig:14`, `src/vm/stack.zig:8`

`std.ArrayList(T)` 内部携带 `allocator` 指针（8 bytes）。`Container`、`Stack`、`Bytecode` 都已在 struct 外部接收 allocator，内部再存一份是冗余的。

**建议**：对于需要外部 allocator 的结构体，使用 `ArrayListUnmanaged`：
```zig
pub const Container = struct {
    data: std.ArrayListUnmanaged(ValueImpl), // 无需内部 allocator 指针
    // ...
};
```

#### C. `VMError` 过于庞大且跨模块合并
**位置**：`src/vm/interpreter.zig:51-71`

```zig
pub const VMError = error{
    OutOfGas, Aborted, TypeMismatch, InvalidLocal, InvalidReference,
    CopyResource, CallStackOverflow, NoFunctionInFrame, InvalidInstruction,
    DivisionByZero, StackOverflow, StackUnderflow, IndexOutOfBounds,
    Overflow, ModuleNotFound, FunctionNotFound, ExecutionFailure,
    InvalidResource, MissingStorage, MissingReturn,
    OutOfMemory, BorrowedResource, // 从 storage 合并而来
};
```

错误集合并导致：
- 任何函数签名都膨胀为 20+ 个错误
- 编译器无法优化错误路径

**建议**：分层错误。执行核心只返回 `ExecutionError`，各子系统返回自己的错误，在最外层统一转换：
```zig
pub const ExecutionError = error{ OutOfGas, Aborted, TypeMismatch, ... };
pub fn mapStorageErr(err: storage.Error) ExecutionError {
    return switch (err) { .BorrowedResource => error.InvalidReference, ... };
}
```

#### D. `Interpreter` 的 setter 模式 vs Builder 模式
当前 `Interpreter` 创建后需要 6-7 个 `setXxx` 调用。更 Zig-idiomatic 的方式：

```zig
pub const Config = struct {
    max_stack_size: u32 = 1024,
    max_call_depth: u32 = 256,
    paranoid_type_checks: bool = false,
};

pub fn init(allocator: std.mem.Allocator, config: Config) !Interpreter {
    return .{
        .operand_stack = try Stack.initCapacity(allocator, config.max_stack_size),
        .call_stack = try std.ArrayList(Frame).initCapacity(allocator, config.max_call_depth),
        // ...
    };
}
```

#### E. `Bytecode` 缺少 `initCapacity`
**位置**：`src/vm/bytecode.zig`

```zig
pub const Bytecode = struct {
    instructions: std.ArrayList(Instruction),
    // 没有 initCapacity
};
```

Loader 在编译模块时已知指令数量，预分配可消除 reallocation。

#### F. `Gas` 结构体方法签名
**位置**：`src/gas/gas.zig`

```zig
pub fn canConsume(self: Gas, amount: u64) bool  // 按值拷贝 16 bytes
pub fn getRemaining(self: Gas) u64               // 同上
```

16 bytes 拷贝不算昂贵，但按 Zig 惯例，纯读取方法应取 `*const`：
```zig
pub fn canConsume(self: *const Gas, amount: u64) bool
```

#### G. 缺少 `src/root.zig` 作为库入口
当前 `src/main.zig` 是 CLI 入口，`src/tests.zig` 是测试根。如果未来作为库被依赖，需要 `src/root.zig` 统一导出公共 API。

---

## 五、修复优先级矩阵

| 优先级 | 维度 | 问题 | 预期收益 | 状态 |
|--------|------|------|----------|------|
| **P0** | 性能 | 每指令 `Instruction` union 拷贝 | 消除 40+ bytes × 指令数 的内存流量 | ✅ 已修复 |
| **P0** | 性能 | `logChange` 重复 deep-copy | 消除 N 次 deep-copy per key per tx | ✅ 已修复 |
| **P0** | 安全 | `ref_count` 溢出风险 | 防止恶意 bytecode 绕过 UAF 防护 | ✅ 已修复 |
| **P1** | 性能 | `popn` 中间堆分配 | 消除 alloc/free per pack/unpack | ✅ 已修复（保留 alloc，修复 aliasing bug） |
| **P1** | 性能 | Native 结果双重复制 | 消除一次 alloc+dupe | ✅ 已修复 |
| **P1** | Zig | 使用 `ArrayListUnmanaged` | 每个 Container/Stack 节省 8 bytes | 待修复 |
| **P1** | 架构 | `Function` 模块上下文切片 → 指针 | 降低每个 Function 实例的内存占用 | 待修复 |
| **P2** | 性能 | Stack/Container 预分配 | 减少 reallocation churn | ✅ 已修复 |
| **P2** | 安全 | `eq` 递归深度限制 | 防止恶意嵌套结构导致栈溢出 | ✅ 已修复 |
| **P2** | 安全 | `verified_set` lifetime 风险 | 避免缓存命中错误函数 | 待修复 |
| **P2** | Zig | `comptime` 重构整数运算 | 减少 ~200 行重复代码 | 待修复 |
| **P3** | 架构 | `Interpreter.Config` 初始化 | 简化 API，减少 setter 调用 | 待修复 |
| **P3** | 性能 | `ModuleId.toString` 优化 | 减少小字符串分配 | 待修复 |
| **P0** | Bug | `popn` zero-allocation 导致 `ContainerRef` 内存损坏 | 13/105 测试崩溃 | ✅ 已修复 |

---

## 六、总体评分

| 维度 | 当前状态 | 评分 (1-10) | 核心瓶颈 |
|------|----------|-------------|----------|
| **架构** | 功能完整，但模块边界和抽象层次有优化空间 | **7.5** | `Function` 职责过重，`Locals` 过度抽象 |
| **性能** | 热点已优化，无致命性能缺陷 | **7.5** | `ArrayListUnmanaged` 迁移，`ModuleId.toString` 优化 |
| **安全** | 防御机制完善，理论风险已大幅减少 | **8.5** | `verified_set` lifetime，`catch {}` 静默忽略 |
| **Zig 惯用法** | 基本合规，`comptime` 和高级数据结构未充分利用 | **7.0** | 重复代码多，`ArrayListUnmanaged` 未使用，错误集过大 |
| **综合** | 生产可用的 MVP，性能和安全已加固 | **7.8** | — |

---

*报告生成时间：2026-05-08*  
*评估范围：src/ 全部文件 + build.zig + AGENTS.md*
