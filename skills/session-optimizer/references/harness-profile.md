# Agent 运行环境（Harness Profile）

> 数据来源：项目实际代码。所有信息标注文件和标识符，不含推测。

## 工具能力

### 工具白名单

来源：`claude-bridge.ts` AGENT_TOOLS 常量

```
Read, Glob, Grep, Bash, Task, TodoWrite, WebFetch, WebSearch, Write
```

共 9 个工具。通过 `toolPermissionFilter()` 回调做权限验证。

### 各工具权限约束

- **Bash** — 关键词黑名单（网络工具、env 泄露、危险删除）+ 正则黑名单（P4 写操作、Git push、内联网络代码等）。详见 `claude-bridge.ts` BLOCKED_BASH_KEYWORDS / BLOCKED_BASH_PATTERNS。
- **WebFetch** — 阻止 Confluence 域名、SSRF 防护（localhost/私有 IP/云元数据）。
- **Read/Glob/Grep** — 路径限制在 `agentFileAccessRoot` + `uploadDir` 范围内。
- **Write** — 仅允许写入 `{agentCwd}/_workspace/conv-{convId}/`，环境变量 `AGENT_WORKSPACE` 动态注入。
- **Edit/NotebookEdit** — 不在白名单中，显式拒绝。
- **Task/TodoWrite/WebSearch** — 直接允许，无额外约束。

---

## 安全约束

### 文件访问范围

来源：`config.ts` agentCwd/agentFileAccessRoot 配置

- `agentCwd`：agent 工作目录（environment variable），相对路径的基准
- `agentFileAccessRoot`：文件访问最大范围（environment variable），可大于 agentCwd

### 环境变量沙箱

来源：`claude-bridge.ts` buildSandboxedEnv() 函数

Agent 子进程只能看到系统路径类变量（PATH、HOME 等）、API key 和 Python UTF-8 编码设置。所有服务端敏感变量已剥离。唯一每次会话变化的是 `AGENT_WORKSPACE`（值为 `./_workspace/conv-{convId}`）。

---

## 会话模型

### 超时与重试

来源：`claude-bridge.ts` 超时常量

| 配置 | 值 | 说明 |
|------|-----|------|
| `MAX_RETRIES` | 3 | 最多 3 次尝试 |
| `FIRST_EVENT_TIMEOUT_MS` | 90,000 (90s) | 首个事件的等待时间 |
| `IDLE_TIMEOUT_MS` | 300,000 (5min) | 事件间隔超时 |

超时流程：启动 → 90s 等首个事件 → 切换 5min IDLE → 每个事件重置 → 超时则 abort + 重试。

重试策略：第 1 次复用 session ID（恢复历史），第 2+ 次不复用（从头开始）。全部失败也返回部分内容。

### 事件缓冲

来源：`session-hub.ts`

- 环形缓冲 5,000 事件
- 工具调用实时写入 `tool_calls` 表
- 会话完成后保留 5 分钟（支持断线重连）

---

## SDK 配置与能力边界

### 我们控制的配置

来源：`claude-bridge.ts` createSession()

```typescript
model: 'claude-opus-4-6'
systemPrompt: { type: 'preset', preset: 'claude_code' }  // SDK 内置 prompt
tools: ['Read', 'Glob', 'Grep', 'Bash', 'Task', 'TodoWrite', 'WebFetch', 'WebSearch', 'Write']
maxTurns: 100
settingSources: ['user', 'project', 'local']
env: { ...sandboxedEnv, AGENT_WORKSPACE }
```

关键：使用 SDK 内置的 `claude_code` preset 系统 prompt，无自定义系统 prompt。

### SDK 内部管理的行为（不可控）

1. **上下文窗口管理**：SDK 自动管理历史消息，我们无法设置窗口大小
2. **Compaction**：SDK 内部的对话压缩机制，我们无法配置保留策略
3. **工具实现**：工具执行逻辑在 SDK 内部，我们只能通过 `canUseTool` 做准入过滤
4. **settingSources**：SDK 自动读取 CWD 中的 `.claude/settings.json` 和 CLAUDE.md

