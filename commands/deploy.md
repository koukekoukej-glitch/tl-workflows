---
name: deploy
description: 部署项目到生产环境
disable-model-invocation: true
---

执行项目部署流程，将当前所有改动发布到生产环境。

运行以下命令：

```bash
bash $PROJECT_DIR/scripts/deploy.sh
```

该脚本会依次完成：
1. 备份数据库（保留最近 10 个备份）
2. 构建客户端
3. 构建服务端
4. 停止旧服务进程，启动新服务
5. 验证服务是否正常监听

如果构建失败，不会影响正在运行的服务。部署完成后向用户报告结果。
