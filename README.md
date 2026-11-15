<p align="center">
  <img src="icons/mytype/app-256.png" width="112" alt="MyType">
</p>

<h1 align="center">MyType</h1>

<p align="center">
  macOS 上的拼音输入法 · 本地运行 · 打字不联网 · 长句一次打完
</p>

<p align="center">
  <a href="https://github.com/yxxbc/MyType/releases/latest"><img src="https://img.shields.io/github/v/release/yxxbc/MyType?display_name=tag&sort=semver&color=2ea44f" alt="Release"></a>
  <a href="https://github.com/yxxbc/MyType/actions/workflows/ci.yml"><img src="https://github.com/yxxbc/MyType/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-12%2B-black?logo=apple&logoColor=white" alt="macOS 12+">
  <img src="https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-lightgrey" alt="arm64 | x86_64">
  <a href="LICENSE-MIT"><img src="https://img.shields.io/badge/license-MIT%20%7C%20Apache--2.0-blue" alt="License"></a>
  <img src="https://img.shields.io/github/downloads/yxxbc/MyType/total?color=orange" alt="Downloads">
</p>

<p align="center">
  <a href="#安装">安装</a> ·
  <a href="#功能">功能</a> ·
  <a href="#更新">更新</a> ·
  <a href="#性能">性能</a> ·
  <a href="#构建">构建</a> ·
  <a href="docs/USAGE.md">文档</a>
</p>

---

<p align="center">
  <img src="docs/images/candidate.png" width="600" alt="输入 zhe'shi'w'd'shu'ru'fa'hen'gao'x'yu'ni'jian'm，候选「这是我的输入法很高兴与你见面」">
  <br>
  <sub>打 <code>zhe'shi'w'd'shu'ru'fa'hen'gao'x'yu'ni'jian'm</code>，第一个候选就是「这是我的输入法很高兴与你见面」</sub>
</p>

## 功能

| 特性 | 说明 |
|---|---|
| **整句输入** | 一次打完一整句，不用一个词一个词选；支持简拼、混拼、按错键纠正 |
| **双拼 / 五笔** | 自然码、小鹤、微软、搜狗、ABC、紫光、拼音加加；五笔 86 |
| **词库** | 自带雾凇拼音；可换万象拼音（词更多，多占约 300 MB 内存） |
| **本地语音** | 按住右 Option 说话，本机识别；模型在设置里下载，录音不上传 |
| **互译** | 单按 Shift 在 中 → 英 → 译 之间切；可接在线服务，也可用本地 HY-MT 模型 |
| **工具栏** | `v` + 空格：剪贴板、常用语、符号、表情 |
| **内置更新** | 设置「关于」页检查、下载、安装；不走 GitHub API |
| **轻** | 万象词库 + 语言模型峰值 188 MB；词库载入 0.2 s |

## 安装

**要求**：macOS 12 以上，Apple 芯片或 Intel。

### 下载 pkg（推荐）

到 [Releases](https://github.com/yxxbc/MyType/releases/latest) 下载 `MyType-<版本>-macos.pkg`，双击安装。
装到 `~/Library/Input Methods`，不需要管理员密码；装完自动登记、打开并切到 MyType。

### 一行命令

```sh
curl -fsSL https://raw.githubusercontent.com/yxxbc/MyType/main/install.sh | bash
```

下载最新 pkg、按 `SHA256SUMS` 校验，再装给当前用户；再跑一遍就是升级。

> 装好后如果菜单栏的输入法菜单里没有 MyType：
> 系统设置 → 键盘 → 文字输入 → 输入法 → 编辑 → ＋ → 简体中文 → MyType；还没有就注销重新登录。

## 更新

0.6.0 起，设置窗口侧栏的「关于」页可以检查更新：读 GitHub 发布页的 302 取最新版本（不用 GitHub API），
下载 `MyType-<版本>-macos.pkg`，按同一页的 `SHA256SUMS` 校验，交给系统的 `installer` 只装给当前用户。
安装时 MyType 会退出，装完 `postinstall` 自动登记、打开并切回来；设置、用户词、自定义词都不动。
启动后最多一天自动检查一次，可在「关于」页关掉（`CheckUpdate=False`）。

0.5.x 没有内置更新器，跑一次上面的 `install.sh`（或双击 0.6.x pkg）升上来；数据目录和设置会自动迁移。

## 性能

相对上游 WowType 0.4.0：

| | 上游 0.4.0 | 这里 0.6.1 |
|---|---:|---:|
| `--selftest` 峰值内存（万象 174 万条 + 语言模型） | 880 MB | **188 MB** |
| 词库常驻（单独测） | 590 MB | **39 MB** |
| 语言模型 `words.lm` | 105 MB | **9 MB** |
| 词库载入 | 1.3 s | **0.2 s** |
| 每次组句按键（200 例逐键） | 平均 ~4 ms / P99 36 ms | **平均 2.35 ms / P99 5.97 ms** |

<details>
<summary>怎么做到的</summary>

1. 词条从「一条词一个 `LexEntry`（`String` + 两个 `Vec`）」换成扁平表，索引从 `HashMap<Vec<_>, Vec<_>>` 换成按哈希排好的 `(u64, u32)` 数组 + 二分；
2. 词库快照升级成可随机访问的 v3（记录 + 偏移表 + 索引），打开时 `mmap` 只读——常驻的只是被查到的文件页，系统随时能回收；
3. `words.lm` 同样 `mmap`，只留词表偏移和排好序的词号。

都只在 `core/src/lexicon.rs`、`core/src/wordlm.rs`，`Lexicon` / `LanguageModel` 两个 trait 没动。
</details>

## 构建

要 Rust 工具链（`cargo`）和 Xcode 命令行工具（`swiftc`）。

```sh
export PATH="$HOME/.cargo/bin:$PATH"

scripts/make-data.sh     # 雾凇词库 + english.txt + words.lm（联网下载，约一分钟）
scripts/make-wubi.sh     # 五笔 86 码表
macos/build.sh dist/data dist/macos
macos/install.sh dist/macos/MyType-0.6.1-macos.zip
```

产物在 `dist/macos/`：`MyType.app`、`MyType-0.6.1-macos.zip`、`MyType-0.6.1-macos.pkg`。

测试：

```sh
cargo test -p mytype-core
macos/test.sh
macos/ShellTests/run.sh dist/data   # 有词库数据时
```

## 发布

打 tag 会触发 `.github/workflows/release.yml`：核对 tag 和 `core/Cargo.toml` 的版本、生成词库/码表、
跑测试、打 pkg/zip、写 `SHA256SUMS`，然后发 GitHub Release。

```sh
git tag v0.6.2
git push origin v0.6.2
```

也可以在 Actions → Release → Run workflow 填一个已有的 tag；`dry_run` 默认只构建并上传 Actions artifact，
不创建/更新 Release。CI 跑 `cargo test` 和 `macos/test.sh`，见 `.github/workflows/ci.yml`。

## 数据与目录

- 数据目录：`~/Library/Application Support/MyType`（设置文件 `mytype.conf`）
- 词库：自带雾凇；万象装在 `dicts/wanxiang/`，可从设置里下载
- 语音模型：`wtlocal/`，在设置「语音」页下载
- 本地翻译模型：`models/`、`llama/`，在设置「翻译」页下载
- 图标：`icons/mytype/make-icons.swift` 生成菜单栏 `menu.pdf`、光标提示 `caret@2x.pdf`、程序坞 `app-1024.png`

## 文档

- [示例与用法](docs/USAGE.md)
- [设置与配置](docs/CONFIG.md)
- [引擎、评测与调参](docs/ENGINE.md)
- [语音输入](docs/VOICE.md)
- [词库与数据管线](docs/DATA.md)
- [目前做不到的](docs/LIMITATIONS.md)

## 和上游的关系

从 [Gloridust/WowType](https://github.com/Gloridust/WowType) 0.4.0（commit `d145a93`）分出来，之后不跟上游同步，自己走。代码许可照旧（[MIT](LICENSE-MIT) / [Apache-2.0](LICENSE-APACHE)），原作者是 Gloridust。

<details>
<summary>相对上游的其它改动</summary>

| 项目 | 上游 0.4.0 | 这里 0.6.1 |
|---|---|---|
| 名字 / bundle id / 设置文件 | WowType / `io.github.gloridust…` / `wowtype.conf` | **MyType / `io.github.yxxbc.inputmethod.MyType` / `mytype.conf`** |
| 版本 | 0.4.0 | 从 **0.5.0** 起自己编 |
| 内置更新 | 无 | **设置「关于」页：检查、下载、安装 pkg** |

仓库里只剩 macOS 要用的东西：`core/`（Rust 引擎）、`voice/`（离线语音识别）、`macos/`（Swift 外壳）、`icons/`、`spec/`（设置契约）、`scripts/` 和 `tools/`（词库/码表的构建管线）。fcitx5 插件、Linux 的设置界面和 `wowtype-config`、Nix/deb/rpm 打包、GNOME 主题都删掉了，需要 Linux 版请用上游。
</details>

## 许可与数据

代码 MIT / Apache-2.0（[LICENSE-MIT](LICENSE-MIT)、[LICENSE-APACHE](LICENSE-APACHE)，另有 [NOTICE](NOTICE)）。原项目 WowType 由 Gloridust 编写。

数据：雾凇拼音（GPL-3.0）、Tatoeba 词频（CC BY 2.0 FR）、`words.lm`（CC BY-SA 4.0）、五笔码表（LGPL-3.0）、简繁表（Apache-2.0）、可选的万象词库（CC BY 4.0）。完整的来源、许可和包内许可文件见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。

<p align="center"><sub>MyType · made for macOS</sub></p>
