---
name: update-sdk
description: 更新 @anthropic-ai/claude-agent-sdk 到最新版本（或指定版本）
---

更新 `@anthropic-ai/claude-agent-sdk` 包。可选参数 `$ARGUMENTS` 指定目标版本号（如 `0.2.63`），不指定则更新到最新版。

## 前置检查

1. **必须在主目录执行**：SDK 更新修改根目录的 `package-lock.json` 和 `node_modules`，在 worktree 中无法正确工作。检查方法：
   ```bash
   git rev-parse --git-dir
   ```
   如果输出包含 `worktrees/`，说明当前在 worktree 中，必须中止并提示用户去主目录执行。

2. **工作区必须干净**：确认没有未提交的改动（`git status --porcelain` 输出为空）。如果有未提交改动，中止并提示用户先提交或 stash。

## 执行流程

### Step 1: 查询版本

```bash
# 当前安装版本
node -e "console.log(require('./node_modules/@anthropic-ai/claude-agent-sdk/package.json').version)"

# npm 最新版本
npm view @anthropic-ai/claude-agent-sdk version
```

如果 `$ARGUMENTS` 不为空，目标版本 = `$ARGUMENTS`；否则目标版本 = npm 最新版。

如果当前版本 = 目标版本，报告"已是最新"并结束。

向用户显示：当前版本 → 目标版本，**等待用户确认后**再继续。

### Step 2: 备份并安装

```bash
cp package-lock.json package-lock.json.sdk-backup
npm install @anthropic-ai/claude-agent-sdk@<目标版本>
```

### Step 3: 编译验证

```bash
npm run build
```

如果失败 → 跳到「回滚」。

### Step 4: 单元测试

```bash
npm run test:unit
```

如果失败 → 跳到「回滚」。

### Step 5: Smoke test — 验证 SDK 可加载

```bash
node -e "
  import('@anthropic-ai/claude-agent-sdk').then(sdk => {
    if (typeof sdk.query !== 'function') {
      console.error('FAIL: sdk.query is not a function, got:', typeof sdk.query);
      process.exit(1);
    }
    console.log('OK: SDK loaded, query is function, exports:', Object.keys(sdk).join(', '));
  }).catch(err => {
    console.error('FAIL: cannot import SDK:', err.message);
    process.exit(1);
  });
"
```

如果失败 → 跳到「回滚」。

### Step 6: API 表面检查

确认 `sdk.d.ts` 中关键类型/函数声明仍然存在：

```bash
grep -q "export declare function query" node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts && echo "OK: query export found" || echo "WARN: query export missing in sdk.d.ts"
```

如果 `query` 导出缺失，向用户**警告**但不自动回滚（可能是 SDK 重命名了导出），由用户决定是否继续。

### Step 7: 提交

```bash
git add package.json package-lock.json
git commit -m "chore: update @anthropic-ai/claude-agent-sdk to <新版本号>"
```

### Step 8: 清理

```bash
rm -f package-lock.json.sdk-backup
```

提交成功后，向用户报告：
- 更新完成：旧版本 → 新版本
- 编译 ✓、测试 ✓、Smoke test ✓
- 提醒：部署后建议人工验证一次对话，确认运行时行为正常

## 回滚流程

任何验证步骤失败时执行：

```bash
cp package-lock.json.sdk-backup package-lock.json
npm install --ignore-scripts
rm -f package-lock.json.sdk-backup
```

回滚后向用户报告失败原因，不要自动重试。
