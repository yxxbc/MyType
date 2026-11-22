# MyType 项目约定

## 临时目录与清理

跑基准测试、截图之类需要临时目录时：

- 用固定字面路径，例如 `/tmp/mytype-bench`、`/tmp/mytype-shots`，需要干净就先 `rm -rf /tmp/mytype-bench && mkdir -p /tmp/mytype-bench`；
- 不要在 `mktemp -d` 出来的变量上做 `rm -rf "$d"`。

原因：LiteMiyu 对「目标要等运行时才知道的递归删除」（`rm -rf "$VAR"`、`rm -rf $(…)`）一定会弹确认，用户每个实验都得手动批准一次；字面路径（`rm -rf /tmp/mytype-bench`）不会弹。
