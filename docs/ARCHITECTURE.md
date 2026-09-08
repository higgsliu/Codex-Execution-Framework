# 架构说明

## 1. 设计目标

Codex Execution Framework 同时优化两个目标：

- **速度**：减少任务墙钟时间，特别是长任务中的串行等待和重复命令开销。
- **Token / 额度**：减少高成本主模型承担机械搜索、日志、重复测试和冗长工具输出。

正确性、范围控制和 Acceptance 是硬约束，不能为了提速或省 Token 降低。

## 2. 四层结构

```text
┌────────────────────────────────────┐
│ 1. PRIMARY                         │
│ 当前 Codex 用户选择模型             │
│ 规划 / 判断 / 关键路径 / 验收        │
├────────────────────────────────────┤
│ 2. LUNA WORKER POOL                │
│ GPT-5.6 Luna / Max                 │
│ luna_reader / luna_writer          │
│ Hard Limit = 6                     │
├────────────────────────────────────┤
│ 3. EXECUTION EFFICIENCY            │
│ Minimum Context                    │
│ Fact Reuse                         │
│ Targeted Tests                     │
│ Shell Snapshot                     │
│ Concise Returns                    │
├────────────────────────────────────┤
│ 4. INTEGRATION                     │
│ Primary → Diff → Test → Git        │
│ → Review Snapshot → Acceptance     │
└────────────────────────────────────┘
```

## 3. Primary 为什么不固定

项目配置故意不写：

```toml
model = "..."
model_reasoning_effort = "..."
```

这样不会覆盖用户当前在 Codex 中选择的主模型和推理等级。

框架只规定职责，而不规定型号：

```text
Primary = 当前会话主模型
```

未来主模型变化时，框架无需随之重写。

## 4. 为什么 Worker 固定 Luna Max

Worker 的核心价值不是替代 Primary 的最终判断，而是承接：

- 范围明确的搜索；
- 大量日志/历史/调用链读取；
- 小而明确的实现；
- 测试准备与执行；
- 独立只读 Review；
- 批量、重复、高吞吐工作。

统一使用 `gpt-5.6-luna/max` 的好处是：

- Worker 成本与能力行为较稳定；
- 不需要为不同工种维护多套模型矩阵；
- 避免 Primary 承担大量低价值上下文；
- 简化共享与排障。

V1 不尝试为 Reader、Writer 分配不同 reasoning effort。后续只有在真实 Run 数据证明 Medium/High 能明显节省总成本且不增加返工时才考虑调整。

## 5. 为什么只有 Reader / Writer

“调查员、测试员、审查员、资料员、实施员”等角色仍然有意义，但它们只是任务角色，不值得演化成大量独立 Agent 配置。

真正影响并发安全的是权限：

```text
READ_ONLY
WRITE_SCOPED
PRIMARY_ONLY
```

因此 V1 只保留：

- `luna_reader` -> READ_ONLY
- `luna_writer` -> WRITE_SCOPED
- Primary -> PRIMARY_ONLY Integration

## 6. 为什么最大并发是 6

6 是硬容量，不是推荐的默认人数。

```text
普通任务：2~3
中型任务：3~4
高并行任务：5~6
```

多 Agent 会产生额外输入、推理、工具调用、输出和汇总成本，因此不把最大并发当作目标。

## 7. 为什么 Writer 更保守

读任务天然冲突较低，写任务会引入：

- 同文件冲突；
- 同功能冲突；
- 共享状态覆盖；
- 测试结果互相污染；
- Integration 复杂度上升。

因此：

```text
Writer 默认 1
常规最大 2
绝对最大 3（范围完全独立）
```

并行单位应该是独立模块边界，而不是 Agent 数量。

## 8. 为什么 Primary 独占 Integration

Worker 报告只是执行结果，不是最终事实来源。

最终应由 Primary：

1. 查看整体 Diff；
2. 检查修改范围；
3. 读取必要证据；
4. 执行必要验证；
5. 再进入 Git / Review Snapshot / Acceptance。

这样可以避免多个 Worker 同时 commit、merge、push 或相互改写 Git 状态。

## 9. 不建设额外编排平台

本框架不实现 Scheduler 服务、数据库、Agent Registry、共享 `SYSTEM_STATE.md` 或 Worker 套娃。

原因：

- Codex 已有原生 Spawn / Wait / Close 能力；
- 额外基础设施会增加维护成本；
- 小团队更需要规则清晰，而不是编排平台本身；
- 中央共享状态文件容易变成新的冲突热点。

V1 的设计原则是：**用最少的机制解决最多的执行问题。**
