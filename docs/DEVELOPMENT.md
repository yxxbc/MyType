# 开发与发布

面向改代码的人；普通安装看 [README](../README.md)。

## 构建

要 Rust 工具链（`cargo`）和 Xcode 命令行工具（`swiftc`）。

```sh
export PATH="$HOME/.cargo/bin:$PATH"

scripts/make-data.sh     # 雾凇词库 + english.txt + words.lm（联网下载，约一分钟）
scripts/make-wubi.sh     # 五笔 86 码表
macos/build.sh dist/data dist/macos
macos/install.sh dist/macos/MyType-0.6.3-macos.zip
```

产物在 `dist/macos/`：`MyType.app`、`MyType-0.6.3-macos.zip`、`MyType-0.6.3-macos.pkg`。

## 测试

```sh
cargo test -p mytype-core
macos/test.sh
macos/ShellTests/run.sh dist/data   # 有词库数据时
```

## 发布

打 tag 会触发 `.github/workflows/release.yml`：核对 tag 和 `core/Cargo.toml` 的版本、生成词库/码表、
跑测试、打 pkg/zip、写 `SHA256SUMS`，然后发 GitHub Release。

```sh
git tag v0.6.3
git push origin v0.6.3
```

也可以在 Actions → Release → Run workflow 填一个已有的 tag；`dry_run` 默认只构建并上传 Actions artifact，
不创建/更新 Release。CI 见 `.github/workflows/ci.yml`。

## 仓库

- `core/`：Rust 引擎
- `voice/`：离线语音识别
- `macos/`：Swift 外壳
- `icons/`：图标（`icons/mytype/make-icons.swift` 生成菜单栏 `menu.pdf`、光标提示 `caret@2x.pdf`、程序坞 `app-1024.png`）
- `spec/`：设置契约
- `scripts/`、`tools/`：词库/码表的构建管线

fcitx5 插件、Linux 设置界面和 `wowtype-config`、Nix/deb/rpm 打包、GNOME 主题都删掉了，需要 Linux 版请用上游。

## 和上游的关系

从 [Gloridust/WowType](https://github.com/Gloridust/WowType) 0.4.0（commit `d145a93`）分出来，之后不跟上游同步，自己走。
代码许可照旧（[MIT](../LICENSE-MIT) / [Apache-2.0](../LICENSE-APACHE)），原作者是 Gloridust。

| 项目 | 上游 0.4.0 | 这里 0.6.3 |
|---|---|---|
| 名字 / bundle id / 设置文件 | WowType / `io.github.gloridust…` / `wowtype.conf` | **MyType / `io.github.yxxbc.inputmethod.MyType` / `mytype.conf`** |
| 版本 | 0.4.0 | 从 **0.5.0** 起自己编 |
| 内置更新 | 无 | **设置「关于」页：检查、下载、安装 pkg** |
