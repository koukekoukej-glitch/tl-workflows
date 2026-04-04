---
name: changelog
description: 生成更新公告：汇总所有未发布的 commit
---

生成面向**普通用户**的更新公告，汇总自上次发布以来的所有 commit。

**核心原则：这是给使用产品的普通用户看的更新公告。** 用户只关心"产品变好了什么"，不关心代码、架构、管理后台。

## 流程

### 1. 确定范围

运行以下命令查找最近的 changelog tag 和未发布的 commit：

```bash
LAST_TAG=$(cd $PROJECT_DIR && git tag -l 'changelog-*' --sort=-creatordate | head -1)
if [ -n "$LAST_TAG" ]; then
  echo "上次发布标记: $LAST_TAG ($(cd $PROJECT_DIR && git log -1 --format='%ai' "$LAST_TAG"))"
  echo "---"
  cd $PROJECT_DIR && git log "$LAST_TAG"..HEAD --format='%h %s' --no-merges
else
  echo "没有找到 changelog tag，将汇总所有 commit"
  echo "---"
  cd $PROJECT_DIR && git log --format='%h %s' --no-merges -50
fi
```

如果没有未发布的 commit，告知用户"没有新的改动需要发布"并结束。

### 2. 理解改动

对每个 commit，如果仅从 commit message 不足以理解改动内容，用 `git show <hash> --stat` 查看改了哪些文件，必要时读取关键文件的 diff 来准确描述改动。

### 3. 生成更新公告

将 commit 按类型分组，撰写面向**普通用户**的更新公告。

**目标读者**：使用这个产品的普通用户。他们不知道什么是 commit、SDK、SSE、rebase，也不需要知道。

**必须包含**（如果有的话）：
- 用户在使用时能直接感知到的功能新增、体验改进、问题修复
- 用通俗的语言描述，比如"上传图片"而不是"attachment upload API"

**必须排除**：
- 管理员后台相关的改动（白名单管理、统计面板、用量分析等）
- 开发者/运维层面的改动（重构、测试、CI/CD、部署脚本、安全加固、日志、配置项等）
- 纯技术优化（内存、并发、数据库 schema 等用户无法感知的改动）

**写作风格**：
- 使用中文，语气友好自然
- 一句话说清变化，不解释技术原因
- 分类参考：新功能、体验优化、问题修复（按实际内容取舍，没有的类别不写）
- 如果过滤后没有任何用户可感知的改动，告知"近期改动均为内部优化，无面向用户的更新"

输出格式示例：
```
## 更新公告 (2026-02-28)

### 新功能
- 支持上传图片附件，大图自动压缩

### 改进
- 聊天滚动体验优化，AI 回复时不再打断手动滚动

### 修复
- 修复刷新页面后消息丢失的问题
```

### 4. 打标记

生成更新公告后，询问用户是否将这些 commit 标记为已发布。如果用户确认，运行：

```bash
cd $PROJECT_DIR && git tag "changelog-$(date +%Y%m%d-%H%M%S)"
```

这样下次运行 /changelog 时只会显示新的 commit。
