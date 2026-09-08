# Codex Execution Protocol

本文件定义本项目推荐的 Codex 执行规则。目标是在不降低正确性和验收标准的前提下，同时优化：

1. 墙钟时间；
2. 总 Token / 额度；
3. Primary 的高成本上下文；
4. 多智能体协调与写入冲突。

## 1. Primary

- 不在项目配置中固定 Primary 模型或推理等级。
- 当前 Codex 会话中用户选择的模型与推理等级即为 Primary。
- Primary 负责：目标理解、规划、关键路径、委派、冲突判断、结果整合、最终验证、Git Integration、Review Snapshot、Acceptance。
- Primary 不应把大量机械搜索、日志阅读、重复测试等低价值上下文全部留在主线程。

## 2. Worker

所有子智能体统一使用：

- `model = gpt-5.6-luna`
- `model_reasoning_effort = max`

只使用两种项目 Worker：

- `luna_reader`：只读调查、搜索、日志/历史分析、Review、测试准备、证据收集。
- `luna_writer`：范围明确的源码、测试或配置修改。

禁止 Worker 再 Spawn Worker。保持两层：`Primary -> Worker`。

## 3. Spawn Gate

不要因为有空闲槽位就创建 Worker。

只有满足至少一项时才委派：

- 能明显缩短当前关键路径；
- 能把大量日志、文件搜索、Git 历史等噪声上下文隔离出 Primary；
- 属于范围清楚的大量机械或重复执行；
- 需要独立复核或第二证据来源。

短函数、单变量、一次简单 Git 状态、单个明显配置修改等低成本工作，优先由 Primary 直接完成。

## 4. 并发

- 全局 Worker 硬上限：6。
- 普通任务通常：2~3。
- 中型任务通常：3~4。
- 5~6 只用于真正高并行、低冲突任务。
- 普通单批 Spawn：1~3。
- 6 是容量，不是目标。

同一批 Worker 应尽量具有相近的预计工作量和生命周期。不要把预计很慢的 Writer 与几个很快的 Reader 放在同一批，避免最慢 Worker 拖住整批结果。

## 5. Reader / Writer 边界

### Reader

- 默认只读。
- 适合并行搜索、调用链、日志、Git 历史、Review、测试准备。
- 通常同批不超过 3；大型只读 Audit 必要时可到 4~6，但必须有明确独立范围。

### Writer

- 默认 Writer 数：1。
- 常规最大：2。
- 绝对最大：3，且必须证明 `WRITE_SCOPE` 完全独立。
- 多个 Writer 需要修改相同文件、同一功能、同一数据结构或共享状态时，必须减少并发或串行。
- 一个 Writer 不应承担“调查 + 大范围实现 + 测试 + 文档 + Git 收尾”全部工作。

## 6. Worker Packet

每个 Worker 只接收最小充分上下文，不复制完整聊天历史或整份长任务说明。

任务包应尽量包含：

```text
ROLE=
GOAL=
KNOWN_FACTS=
READ_SCOPE=
WRITE_SCOPE=
DO_NOT_TOUCH=
ACCEPTANCE=
RETURN_FORMAT=
```

一个 Worker 应只有一个主要目标、一个明确 Scope、一个主要交付物和一个明确验收条件。

## 7. Fact Reuse

Primary 在当前 Run 中维护短事实账本，例如：

```text
ROOT_CAUSE
TARGET_FILES
CALL_PATH
TEST_ENTRY
DO_NOT_TOUCH
```

已确认事实默认复用。除非出现矛盾证据，不允许 Writer、Tester、Reviewer 为了“保险”再次从零重复扫描同一区域。

## 8. Worker Return

Worker 只返回可供 Primary 消费的结构化结果：

```text
STATUS=COMPLETED | PARTIAL | BLOCKED
FINDINGS=
FILES_CHANGED=
TESTS=
RISKS=
NEEDS_PRIMARY=
```

不要把完整 Shell 输出、完整测试日志、完整 Diff 或长篇过程叙述倾倒回 Primary。原始证据保留在源码、测试、日志文件或 Git Diff 中，需要时再定点读取。

## 9. Critical Path First

优先处理决定整个 Run 最早完成时间的任务。

- P0：不完成就不能交付，例如核心修复、必要测试、必要根因确认。
- P1：明显提高质量，例如独立 Review、相关回归、补充调查。
- P2：锦上添花，例如额外文档、非必要延伸调查。

不得让 P2 抢占关键 Writer / Tester 所需资源。

不要默认等待无关信息“全部齐全”才开始下一步；但当 Codex 将多个 Worker 作为同一批请求时，要预期该批结果会被统一收集，因此应通过合理分批避免长尾阻塞。

## 10. Stall

不要只按运行时间判断 Worker 卡住。

若连续 >= 2 次出现同类失败，并且没有新增有效证据、有效 Diff 或测试推进，应停止继续撞同一路径，返回 `PARTIAL/BLOCKED` 给 Primary 重新规划。

## 11. Test Ladder

默认渐进验证：

```text
T0：最小复现 / 语法 / focused check
T1：目标测试
T2：相关模块回归
T3：全量测试，仅在 Acceptance 或风险确实要求时
```

禁止为了“保险”在每次小修改后无条件执行全仓测试。

## 12. Shell / Context

- 搜索优先使用定点、低输出工具，例如 `rg`、`git grep`、`git ls-files`。
- 避免无边界递归扫描和一次输出几千行。
- Git 优先 `git status --short`、`git diff --stat`、定点 `git diff -- <path>`。
- 先定位再读取；不要默认读取整个超大文件。
- 已有事实和命令结果能复用时，不重复调用。

## 13. Integration

最终集成权属于 Primary。

Worker 默认不得自行：

- merge；
- push；
- 修改主分支历史；
- 创建最终 Review Snapshot；
- 宣告最终 Acceptance。

Primary 在集成前应检查整体 Diff、必要测试与范围边界，然后再执行项目自身要求的 Git / Review 流程。

## 14. 降级

如果配置要求的 `gpt-5.6-luna/max` Worker 当前不可用：

- 不静默替换成其他 Worker 模型；
- 明确报告 Worker Pool 不可用；
- 必要时由当前 Primary 进入单智能体降级执行；
- 不因为降级而降低 Acceptance 标准。

## 15. 最小复杂度

本框架依赖 Codex 原生多智能体能力，不额外建设 Scheduler 服务、状态数据库、Agent Registry 或 Worker 套娃系统。优先通过简单、明确、可执行的规则解决调度问题。
