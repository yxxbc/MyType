# MyType

macOS 上的拼音输入法，自己维护的一支。本地运行、打字不联网，雾凇 / 万象词库，长句一次打完。

界面和用法跟原项目一模一样（[docs/USAGE.md](docs/USAGE.md)、[docs/CONFIG.md](docs/CONFIG.md)），这里只说这个仓库自己的事。

## 和上游的关系

从 [Gloridust/WowType](https://github.com/Gloridust/WowType) 0.4.0（commit `d145a93`）分出来，之后**不跟上游同步**，自己走。代码许可照旧（MIT / Apache-2.0），原作者是 Gloridust。

相对上游的改动：

| | 上游 0.4.0 | 这里 0.5.1 |
|---|---|---|
| `--selftest` 峰值内存（万象 174 万条 + 语言模型） | 880 MB | **188 MB**（脏页 89 MB） |
| 词库常驻（单独测） | 590 MB | **39 MB**（脏页 3.4 MB） |
| 语言模型 `words.lm` | 105 MB | **9 MB** |
| 词库载入 | 1.3 s | **0.2 s** |
| 每次组句按键（200 例逐键） | 平均 ~4 ms / P99 36 ms（万象自己测的） | **平均 2.35 ms / P99 5.97 ms** |
| 名字 / bundle id | WowType / io.github.gloridust… | **MyType / io.github.yxxbc.inputmethod.MyType** |
| 版本 | 0.4.0 | 从 **0.5.0** 起自己编 |

内存的改法是三层：
1. 词条从「一条词一个 `LexEntry`（`String` + 两个 `Vec`）」换成扁平表，索引从 `HashMap<Vec<_>, Vec<_>>` 换成按哈希排好的 `(u64, u32)` 数组 + 二分；
2. 词库快照升级成可随机访问的 v3（记录 + 偏移表 + 索引），打开时 `mmap` 只读——常驻的只是被查到的文件页，系统随时能回收；
3. `words.lm` 同样 `mmap`，只留词表偏移和排好序的词号。

都只在 `core/src/lexicon.rs`、`core/src/wordlm.rs`，`Lexicon` / `LanguageModel` 两个 trait 没动。

仓库里只剩 macOS 要用的东西：`core/`（Rust 引擎）、`voice/`（离线语音识别）、`macos/`（Swift 外壳）、`icons/`、`spec/`（设置契约）、`scripts/` 和 `tools/`（词库/码表的构建管线）。fcitx5 插件、Linux 的 `wowtype-config`、Nix/deb/rpm 打包、主题都已经删掉，需要 Linux 版请用上游。

## 构建（macOS）

要 Rust 工具链（`cargo`）、Xcode 命令行工具（`swiftc`）。

```sh
export PATH="$HOME/.cargo/bin:$PATH"

scripts/make-data.sh     # 雾凇词库 + english.txt + words.lm（联网下载，约一分钟）
scripts/make-wubi.sh     # 五笔 86 码表
macos/build.sh dist/data dist/macos
macos/install.sh dist/macos/MyType-0.5.2-macos.zip
```

产物在 `dist/macos/`：`MyType.app`、`MyType-0.5.2-macos.zip`（给 `install.sh`）、`MyType-0.5.2-macos.pkg`（双击装，装到 `~/Library/Input Methods`，不用管理员密码）。

装完 `install.sh` 会登记、打开并试着切过去。如果菜单栏的输入法菜单里没有它，
到「系统设置 → 键盘 → 文字输入 → 输入法 → 编辑 → ＋ → 简体中文 → MyType」加一次，
或者注销重新登录（组件那一条系统有时不认 `TISEnableInputSource`，只打开了 `.Hans` 模式时不显示）。

已经装过上游版本的话，把 `~/Library/Application Support/WowType` 复制成 `~/Library/Application Support/MyType`，配置、用户词、语音模型、万象词库都在里面，不用重新下载；`wowtype.conf` 里的 `Lexicon=` 记的绝对路径要跟着改。

- 数据目录：`~/Library/Application Support/MyType`（设置文件 `wowtype.conf` 沿用这个名字，键名和 Linux 那份一样）
- 图标：`icons/mytype/make-icons.swift` 生成菜单栏的 `menu.pdf`、光标旁提示的 `caret@2x.pdf` 和程序坞的 `app-1024.png`
- 测试：`cargo test -p wowtype-core`、`macos/test.sh`

## 许可与数据

代码 MIT / Apache-2.0（见 `core/data`）。词库 rime-ice（GPL-3.0）、可选的万象词库、词级语言模型 `words.lm`（CC-BY-SA-4.0）、五笔码表 rime-wubi（LGPL-3.0）、简繁表 OpenCC（Apache-2.0），各自的许可证随包和仓库都在。
