# Token 效率

## 1. 基本判断

多智能体不是天然省 Token。

每个新 Worker 都会增加：

- 输入上下文；
- 推理 Token；
- 工具调用；
- 输出 Token；
- Primary 汇总成本。

因此本框架的目标不是“多用 Luna”，而是：

> 用尽可能少的 Luna，把真正高 Token、低价值、可隔离的执行从 Primary 移走。

## 2. Token 的主要浪费来源

### A. 完整复制任务上下文

把长聊天、事故历史、完整日志和全部项目说明复制给每个 Worker，会直接放大输入 Token。

### B. 多 Worker 重复扫描

典型浪费：

```text
Reader 扫一遍
Writer 再扫一遍
Tester 再扫一遍
Reviewer 再扫一遍
Primary 最后又扫一遍
```

### C. 超大命令输出

例如无边界递归扫描、完整测试日志、完整巨大 Diff，会同时浪费 Shell 时间和模型上下文。

### D. 超级 Worker

一个 Worker 同时调查、实现、测试、文档、Git，通常会扩大上下文、延长关键路径并增加返工概率。

### E. 不必要的 Agent

任务本来 Primary 几步就能完成，却为了“使用多智能体”额外 Spawn，会增加总 Token。

## 3. Minimum Sufficient Context

Worker 只接收完成任务真正需要的信息。

推荐模板：

```text
ROLE=IMPLEMENTER

GOAL=
修复指定问题

KNOWN_FACTS=
- 已确认事实 1
- 已确认事实 2

READ_SCOPE=
...

WRITE_SCOPE=
...

DO_NOT_TOUCH=
...

ACCEPTANCE=
- ...

RETURN_FORMAT=
STATUS / FINDINGS / FILES_CHANGED / TESTS / RISKS / NEEDS_PRIMARY
```

不要默认附带：

- 用户完整历史；
- 与本任务无关的项目背景；
- 已经确认且无需重新证明的大段证据；
- 完整日志全文；
- 完整代码文件全文。

## 4. Fact Ledger

Primary 在当前 Run 内维护短事实账本，而不是创建共享状态文件。

例如：

```text
ROOT_CAUSE=
TARGET_FILES=
CALL_PATH=
TEST_ENTRY=
DO_NOT_TOUCH=
```

规则：

- 已确认事实可直接传给后续 Worker；
- 后续 Worker 不从零重复调查；
- 只有出现具体矛盾证据才重新打开对应事实。

这样既省 Token，也减少不同 Agent 得出互相冲突结论的概率。

## 5. Distilled Return

Worker 返回的是“可消费结论”，不是过程直播。

推荐：

```text
STATUS=COMPLETED
FINDINGS=
- ...
FILES_CHANGED=
- ...
TESTS=
- ... PASS
RISKS=
- NONE
NEEDS_PRIMARY=
- NONE
```

不要默认返回：

- 完整命令输出；
- 完整 pytest 日志；
- 完整 Git Diff；
- 长篇“我先做了什么、然后做了什么”。

原始事实留在文件系统和 Git 中，Primary 需要时定点读取。

## 6. 命令输出预算

搜索：

```text
优先 rg / git grep / git ls-files
避免无边界 Get-ChildItem -Recurse 或全盘扫描
```

Git：

```text
git status --short
git diff --stat
git diff -- <path>
```

只有需要时才读取完整 Diff。

文件：

```text
先定位
→ 再读取相关函数/范围
```

不要默认读取整个超大文件。

测试：

```text
T0 focused
T1 target
T2 related regression
T3 full suite only when required
```

## 7. 为什么 V1 固定 Luna Max

理论上降低 reasoning effort 可能进一步减少 Token 与延迟，但过弱的 Worker 可能导致：

```text
第一次便宜
→ 判断错误
→ 重新扫描
→ 返工
→ 第二轮测试
→ 总成本更高
```

V1 因此先固定 `gpt-5.6-luna/max`，把优化重点放在：

- 少 Spawn；
- 小 Context；
- 小 Scope；
- 小输出；
- 少重复；
- 渐进验证。

等积累真实 Run 数据后，再单独 A/B 测试 Reader 使用 Medium/High 是否有稳定收益。

## 8. 为什么 Fast Mode 不作为默认策略

本框架追求“速度 + Token/额度效率”，而 Fast Mode 本质上是用更多额度购买更低模型延迟。

因此：

- 不在框架配置中强制启用 Fast service tier；
- 紧急生产事故等“速度优先、不在意额度”的任务可由用户自行开启；
- 正常开发默认以总体成本效率为目标。

## 9. Shell Snapshot

`features.shell_snapshot = true` 属于低风险的执行优化：通过 Shell 环境快照减少重复命令的环境构建开销。

它与“开更多 Agent”不同，不需要额外引入一批模型上下文，因此适合作为默认明确开启项。

Windows 的 `unified_exec` 当前不作为默认配置，先通过基准测试验证兼容性和收益。

## 10. 建议记录的数据

至少记录：

```text
TASK_TYPE
PRIMARY_MODEL
WORKERS_SPAWNED
READERS
WRITERS
MAX_CONCURRENCY
WALL_TIME
SLOWEST_WORKER
RETRIES
TEST_LEVEL
TOKEN / CREDITS（可取得时）
FINAL_STATUS
```

不要只看“任务用了多久”。

一个方案可能：

- 快 1 分钟；
- 但 Token 多 40%；
- 还增加一次重试。

这种方案不一定更优。

## 11. 评价公式

V1 不实现复杂自动打分，但人工评估时至少同时考虑：

```text
正确性 / Acceptance
Wall Time
Token / Credits
重试次数
Integration 冲突
```

正确性是硬门槛，剩下指标再做效率比较。
