# MyType

macOS 上的拼音输入法，自己维护的一支。本地运行、打字不联网，雾凇 / 万象词库，长句一次打完。

界面和用法跟原项目一模一样（[docs/USAGE.md](docs/USAGE.md)、[docs/CONFIG.md](docs/CONFIG.md)），这里只说这个仓库自己的事。

## 和上游的关系

从 [Gloridust/WowType](https://github.com/Gloridust/WowType) 0.4.0（commit `d145a93`）分出来，之后**不跟上游同步**，自己走。代码许可照旧（MIT / Apache-2.0），原作者是 Gloridust。

相对上游的改动：

| | 上游 0.4.0 | 这里 |
|---|---|---|
| 词库常驻内存（万象 174 万条） | 590 MB | **247 MB** |
| 词库载入 | 907 ms | **321 ms** |
| 最慢一次按键 | 2.64 ms | 2.66 ms |
| 名字 / bundle id | WowType / io.github.gloridust… | **MyType / io.github.yxxbc.inputmethod.MyType** |
| 版本 | 0.4.0 | 从 **0.5.0** 起自己编 |

词库内存的改法：`LexEntry` 那种「一条词几个堆对象」的结构换成扁平表（词正文一个 `String`、音节键一个 `Vec<u16>`、频次一个 `Vec<f64>`，每条两个 `Span`），索引从 `HashMap<Vec<_>, Vec<_>>` 换成按哈希排好的 `(u64, u32)` 数组 + 二分。只在 `core/src/lexicon.rs`，`Lexicon` trait 没动。

Linux 那半（fcitx5 插件、`settings/wowtype-config`、nix/deb/rpm 打包）跟着仓库在，但这里**不维护**，文件里的仓库地址指向本仓库，发布包得自己传。

## 构建（macOS）

要 Rust 工具链（`cargo`）、Xcode 命令行工具（`swiftc`）。

```sh
export PATH="$HOME/.cargo/bin:$PATH"

scripts/make-data.sh     # 雾凇词库 + english.txt + words.lm（联网下载，约一分钟）
scripts/make-wubi.sh     # 五笔 86 码表
macos/build.sh dist/data dist/macos
macos/install.sh dist/macos/MyType-0.5.0-macos.zip
```

产物在 `dist/macos/`：`MyType.app`、`MyType-0.5.0-macos.zip`（给 `install.sh`）、`MyType-0.5.0-macos.pkg`（双击装，装到 `~/Library/Input Methods`，不用管理员密码）。

已经装过上游版本的话，把 `~/Library/Application Support/WowType` 复制成 `~/Library/Application Support/MyType`，配置、用户词、语音模型、万象词库都在里面，不用重新下载；`wowtype.conf` 里的 `Lexicon=` 记的绝对路径要跟着改。

- 数据目录：`~/Library/Application Support/MyType`（设置文件 `wowtype.conf` 沿用这个名字，键名和 Linux 那份一样）
- 图标：`icons/mytype/make-icons.swift` 生成菜单栏的 `menu.pdf`、光标旁提示的 `caret@2x.pdf` 和程序坞的 `app-1024.png`
- 测试：`cargo test -p wowtype-core`、`macos/test.sh`

## 许可与数据

代码 MIT / Apache-2.0（见 `core/data`）。词库 rime-ice（GPL-3.0）、可选的万象词库、词级语言模型 `words.lm`（CC-BY-SA-4.0）、五笔码表 rime-wubi（LGPL-3.0）、简繁表 OpenCC（Apache-2.0），各自的许可证随包和仓库都在。
