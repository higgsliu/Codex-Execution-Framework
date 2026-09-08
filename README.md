# Codex Execution Framework

> 让 Codex 在不绑定主模型的前提下，通过 **GPT-5.6 Luna Max 子智能体、自适应并发、最小上下文和执行优化**，同时降低任务墙钟时间与 Token 消耗。

## 这是什么

这不是新的 Codex Runtime，也不是 Skill、Scheduler 或 Agent 平台。

它是一套可以放进现有代码仓库的 **Codex 执行规则 + 子智能体配置 + 轻量诊断脚本**：

```text
用户在 Codex 选择当前主模型
            │
            ▼
         Primary
  规划 / 判断 / 调度 / 整合 / 验收
            │
            ▼
  GPT-5.6 Luna Max Worker Pool
      Reader / Writer
            │
            ▼
  Targeted Test / Shell / Git
            │
            ▼
 Primary Integration / Acceptance
```

核心目标有两个：

1. **更快**：只在能缩短关键路径时并行，把大量机械执行交给子智能体。
2. **更省 Token**：减少昂贵主模型读取日志、重复扫描、机械测试和大段工具输出的上下文消耗。

---

## 核心约束

### 1. Primary 不固定模型

本仓库 **不设置顶层 `model` 或 `model_reasoning_effort`**。

你在当前 Codex 会话选择什么模型和推理等级，它就是什么 Primary。

Primary 负责：

- 理解目标；
- 规划与拆分；
- 判断关键路径；
- 决定是否委派以及委派数量；
- 判断读写冲突；
- 整合子智能体结果；
- 最终测试、Git Integration、Review Snapshot 与 Acceptance。

### 2. Worker 固定 GPT-5.6 Luna Max

所有执行型子智能体统一：

```text
model = gpt-5.6-luna
reasoning = max
```

只保留两个极简 Worker：

- `luna_reader`：只读调查、代码搜索、日志/历史分析、Review、测试准备。
- `luna_writer`：范围明确的源码、测试或配置修改。

不维护 6 套复杂 Agent Prompt。

### 3. 并发上限 6，但 6 只是容量

```text
全局硬上限：6
普通任务：2~3
中型任务：3~4
5~6：只用于真正高并行、低冲突任务
普通单批 Spawn：1~3
```

不要因为有 6 个槽位就开满。

### 4. Writer 严格限流

```text
Writer 默认：1
常规最大：2
绝对最大：3
```

只有写入范围完全独立时才允许 3 个 Writer 并行。多个 Worker 需要修改相同文件、同一功能或同一共享状态时，必须减少并发或串行。

### 5. 不把慢 Writer 和快 Reader 塞进同一批

Codex 会收集所请求的子智能体结果后再统一返回，因此一批中单个长尾 Worker 可能拖住整批。

错误：

```text
Reader 2min
Reader 3min
Reader 2min
Writer 15min
→ 整批约 15min+
```

推荐：

```text
Batch A：2~3 个耗时相近的 Reader
→ 得到最小充分事实
Batch B：1 个 Writer + 真正同期可完成的 Tester/Reader
```

### 6. Token-Aware Spawn Gate

只有满足至少一项，才值得 Spawn：

- 能明显缩短关键路径；
- 能把大量日志、搜索、历史等脏上下文隔离出 Primary；
- 属于大量机械、重复、范围明确的执行；
- 需要独立复核。

一个短函数、一个变量、一次 `git status` 等低成本工作通常由 Primary 直接完成。

---

## Token 优化原则

### 最小充分上下文

Worker 不接收完整聊天历史和整份长任务包，只接收：

```text
ROLE
GOAL
KNOWN_FACTS
READ_SCOPE / WRITE_SCOPE
DO_NOT_TOUCH
ACCEPTANCE
RETURN_FORMAT
```

### 事实复用

Primary 维护当前 Run 的短事实账本：

```text
ROOT_CAUSE
TARGET_FILES
CALL_PATH
TEST_ENTRY
DO_NOT_TOUCH
```

已确认事实默认复用；除非出现矛盾证据，不允许不同 Worker 从零重复侦察。

### 精简返回

Worker 返回结构化结果，不向 Primary 倾倒完整日志、完整测试输出或完整 Diff：

```text
STATUS=
FINDINGS=
FILES_CHANGED=
TESTS=
RISKS=
NEEDS_PRIMARY=
```

### 渐进验证

```text
T0 最小复现 / 语法 / focused check
↓
T1 目标测试
↓
T2 相关模块回归
↓
T3 全量测试，仅在 Acceptance 或风险确实要求时执行
```

---

## Shell 执行优化

项目配置明确开启：

```toml
[features]
shell_snapshot = true
```

它用于复用 Shell 环境快照，加快重复命令执行。

`unified_exec` 在 macOS/Linux 当前默认开启，而 Windows 当前默认关闭，因此本框架 **不在默认配置中强开 Windows `unified_exec`**。Windows 用户应先运行基准测试，再决定是否自行启用。

Fast Mode 也不作为框架默认要求；它属于“用更多额度换更低延迟”，与本项目同时追求速度和 Token/额度效率的默认目标不同。

---

## 快速开始

### 1. Clone 本仓库

```powershell
git clone https://github.com/higgsliu/Codex-Execution-Framework.git
cd Codex-Execution-Framework
```

### 2. 把配置复制到你的目标项目

至少复制：

```text
.codex/
```

如果目标项目没有 `AGENTS.md`，可以直接复制本仓库的 `AGENTS.md`。

如果目标项目已经有 `AGENTS.md`，**不要覆盖原有业务/工程规则**；应把本仓库的调度、Token、Worker 和 Integration 规则合并进去。

### 3. 运行环境检查

```powershell
./scripts/doctor.ps1 -ProjectRoot "D:\YourProject"
```

可选的真实子智能体探针会消耗少量模型 Token：

```powershell
./scripts/doctor.ps1 -ProjectRoot "D:\YourProject" -LiveProbe
```

### 4. 在目标项目打开 Codex

主模型和推理等级由你自己在 Codex 当前会话选择。本框架不会覆盖。

然后正常给任务即可；适用的 `AGENTS.md` 会指导 Primary 在值得时使用 Luna Worker。

---

## 基准测试

本仓库提供轻量测试，不建设复杂性能平台。

### 本地 Shell 基线

```powershell
./scripts/benchmark.ps1 -ProjectRoot "D:\YourProject" -Mode Shell
```

### Primary 基线（会消耗 Token）

```powershell
./scripts/benchmark.ps1 -ProjectRoot "D:\YourProject" -Mode Primary
```

### Luna Reader 基线（会消耗 Token）

```powershell
./scripts/benchmark.ps1 -ProjectRoot "D:\YourProject" -Mode LunaReader
```

可通过多次运行比较：

- Primary only；
- Primary + Luna Reader；
- 不同 Codex 版本；
- Windows 是否自行开启 `unified_exec`；
- 调整调度规则后的耗时与 Token。

真正要优化的是：

```text
Wall Time + Token/Credits + 成功率
```

而不是单看 Agent 数量。

---

## 仓库结构

```text
Codex-Execution-Framework/
├── README.md
├── AGENTS.md
├── .codex/
│   ├── config.toml
│   └── agents/
│       ├── luna-reader.toml
│       └── luna-writer.toml
├── docs/
│   ├── ARCHITECTURE.md
│   ├── SCHEDULING.md
│   └── TOKEN_EFFICIENCY.md
└── scripts/
    ├── doctor.ps1
    └── benchmark.ps1
```

---

## 明确不做什么

V1 不建设：

- 自研 Scheduler 服务；
- Agent Registry；
- 状态数据库；
- Worker 套 Worker；
- 六套复杂工种 Agent；
- 自动接管用户主模型；
- 默认强开 Fast Mode；
- 依赖实验特性才能工作的核心流程。

Codex 原生多智能体负责 Spawn 和线程管理；本仓库只负责 **怎样更经济、更稳定地使用它**。

---

## 与 Gpt-Development-Loop 的关系

这两个项目职责不同：

```text
Gpt-Development-Loop
GPT → Codex → GitHub → GPT Review
          │
          ▼
Codex-Execution-Framework
Primary → Luna Workers → Test / Shell / Integration
```

- `Gpt-Development-Loop`：解决 GPT、Codex、GitHub 与 GPT Review 的外部开发闭环。
- `Codex-Execution-Framework`：解决 Codex 内部怎样执行得更快、更省 Token。

两者可以组合，但不应揉成同一个大框架。

---

## V1 的判断标准

这套框架是否有效，不靠感觉判断。建议用 10~20 个真实 Codex Run 记录：

```text
TASK_TYPE
PRIMARY_MODEL
WORKERS_SPAWNED
MAX_CONCURRENCY
READERS
WRITERS
WALL_TIME
SLOWEST_WORKER
RETRIES
TEST_LEVEL
TOKEN / CREDITS（客户端可取得时）
FINAL_STATUS
```

用真实数据再调整 `Typical Workers`、Reader/Writer 数量和 Batch 大小，而不是继续凭理论把并发往上加。
