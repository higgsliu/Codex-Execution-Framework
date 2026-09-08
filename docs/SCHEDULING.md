# 调度规则

## 1. 调度目标

调度的目标不是“尽量多开 Agent”，而是：

> 在满足正确性和 Acceptance 的前提下，用最少必要 Worker 缩短关键路径，并避免把 Token 花在重复或低价值工作上。

## 2. 三个核心问题

Primary 每次准备委派前，依次判断：

1. **这个任务值得委派吗？**
2. **它是 Reader 还是 Writer？**
3. **它应该和谁同一批运行？**

## 3. Spawn Gate

满足至少一项才 Spawn：

### A. 关键路径收益

Worker 与当前关键工作并行，能够缩短总墙钟时间。

例：

```text
Writer 修改源码
Tester/Reader 同时准备失败复现和目标测试
```

### B. 上下文隔离收益

任务需要读取大量：

- 日志；
- Git 历史；
- 大量文件；
- 调用链；
- 支持材料。

把这些交给 Reader，再返回压缩结果，可以保护 Primary 上下文。

### C. 机械执行收益

范围清楚、重复、高吞吐的工作，例如多目录搜索、相关测试、批量核对。

### D. 独立复核收益

需要与实现者相对独立的 Review 或第二证据来源。

如果以上都不满足，Primary 直接完成通常更快、更省。

## 4. 并发预算

```text
GLOBAL_HARD_LIMIT = 6
TYPICAL_ACTIVE = 2~3
MEDIUM_TASK = 3~4
HIGH_PARALLEL = 5~6
NORMAL_BATCH = 1~3
```

5~6 个 Worker 更适合：

- 大型只读 Audit；
- 多个独立模块扫描；
- 多个真正独立的验证维度。

普通 Bug 不应因为“复杂”就默认开满。

## 5. Reader 规则

Reader 适合：

- 代码搜索；
- 调用链；
- 事故日志；
- Git 历史；
- 文档/证据；
- Review；
- 测试入口和复现准备。

普通任务同批通常 1~3 个 Reader。

当存在 4~6 个完全独立、只读、范围清晰的调查区域时，可以提高并发，但仍应确保每个 Reader 有独立问题，而不是重复“看看有没有问题”。

## 6. Writer 规则

```text
WRITE_DEFAULT = 1
WRITE_NORMAL_MAX = 2
WRITE_ABSOLUTE_MAX = 3
```

允许 2~3 个 Writer 并行的前提：

```text
A WRITE_SCOPE = module-a/**
B WRITE_SCOPE = module-b/**
C WRITE_SCOPE = module-c/**
```

如果多个 Writer 需要修改同一文件、同一核心函数、同一状态文件或同一数据合同，减少并发或串行。

不要按“文件前半段/后半段”拆同一个高耦合实现。

## 7. 避免长尾批次

Codex 会等待一批请求的结果并统一汇总，因此同批任务应尽量耗时相近。

错误：

```text
Batch
├─ Reader A：小范围搜索
├─ Reader B：查 Git 历史
├─ Reader C：看 2 个测试文件
└─ Writer D：大范围实现 + 测试 + 文档
```

即使前三个很快，整批仍由 Writer D 的长尾决定。

推荐：

```text
Batch 1
├─ Reader A
├─ Reader B
└─ Reader C

→ Primary 得到最小充分事实

Batch 2
├─ Writer D
└─ Reader/Tester E（只有确实能同期推进时）
```

## 8. 关键路径优先

### P0 Critical

不完成就不能交付：

- 核心根因确认；
- 核心实现；
- 必要验证。

### P1 Supporting

明显提高质量：

- 第二调查；
- 独立 Review；
- 相关回归。

### P2 Optional

锦上添花：

- 额外整理；
- 非必要延伸调查；
- 与本轮 Acceptance 无关的文档优化。

当槽位紧张时，优先保证 P0/P1。不要让 P2 延迟关键 Writer 或 Tester。

## 9. Writer 任务包必须小

一个 Worker 不应同时负责：

```text
调查 + 根因 + 大范围改造 + 测试 + 文档 + Git 收尾
```

应切为可独立验收的工作包。

示例：

```text
Writer A
GOAL = 修复核心源码
WRITE_SCOPE = src/**

Writer/Tester B
GOAL = 补目标测试
WRITE_SCOPE = tests/**
```

如果两者存在强依赖，则不要为了并行强拆；宁可让一个 Writer 做关键实现，另一个 Reader 提前准备测试与证据。

## 10. Tester 尽量提前准备

Tester/Reader 可以在 Writer 尚未完成时先做：

- 失败复现；
- 找现有测试；
- 确定目标测试命令；
- 准备边界样本；
- 确认 Acceptance 的验证入口。

这样 Writer 完成后可以直接进入验证，减少串行阶段。

## 11. Stall

不要只用固定分钟数判断卡死。

下列情况更值得判断为无进展：

- 同类失败连续 >= 2 次；
- 没有新增证据；
- 没有有效 Diff；
- 测试结果没有推进；
- 不断扩大扫描范围；
- 重复确认已确认事实。

达到条件后停止继续无脑重试，返回 Primary 重新规划。

## 12. 常见调度模板

### 小 Bug

```text
Primary
├─ Reader ×1（需要调查时）
├─ Writer ×1
└─ Reader/Tester ×1
```

通常总 Worker：2~3。

### 中型功能

```text
Batch 1：Reader ×2
Batch 2：Writer ×1~2 + Tester ×1
Batch 3：Reviewer ×1（风险需要时）
```

不要默认全部同批。

### 大型只读 Audit

```text
Reader ×4~6
```

每个 Reader 必须负责明确、互不重复的区域或问题维度。

### 多模块实现

```text
Writer A -> module-a/**
Writer B -> module-b/**
Writer C -> module-c/**
```

只有在 Scope 真正独立时使用 3 Writer。

## 13. 最终原则

```text
容量 ≠ 目标
可并行 ≠ 值得并行
Agent 更多 ≠ Token 更省
Writer 更多 ≠ 关键路径更短
```

真正需要优化的是：

```text
Wall Time + Token/Credits + 成功率 + Integration 成本
```
