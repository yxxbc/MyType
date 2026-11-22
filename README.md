<p align="center">
  <img src="icons/mytype/app-256.png" width="112" alt="MyType">
</p>

<h1 align="center">MyType</h1>

<p align="center">
  macOS 上的拼音输入法 · 本地运行 · 长句一次打完
</p>

<p align="center">
  <a href="https://github.com/yxxbc/MyType/releases/latest"><img src="https://img.shields.io/github/v/release/yxxbc/MyType?display_name=tag&sort=semver&color=2ea44f" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-12%2B-black?logo=apple&logoColor=white" alt="macOS 12+">
  <a href="LICENSE-MIT"><img src="https://img.shields.io/badge/license-MIT%20%7C%20Apache--2.0-blue" alt="License"></a>
</p>

<p align="center">
  <a href="https://mytype.xynrin.cc.cd">官网</a> ·
  <a href="#界面">界面</a> ·
  <a href="#安装">安装</a> ·
  <a href="#功能">功能</a> ·
  <a href="#更新">更新</a> ·
  <a href="#性能">性能</a> ·
  <a href="docs/USAGE.md">文档</a>
</p>

---

## 界面

<p align="center">
  <img src="docs/images/candidate.png" width="680" alt="输入长句，第一个候选就是整句">
</p>

<p align="center">
  <img src="docs/images/voice.png" width="392" alt="语音输入浮层：麦克风、波形和识别中的文字">
  <br>
  <sub>按一下右 Option 开始说话，再按一下上屏；本机识别</sub>
</p>

## 安装

**要求**：macOS 12 以上，Apple 芯片或 Intel。

到 [Releases](https://github.com/yxxbc/MyType/releases/latest) 下载 `MyType-<版本>-macos.pkg`，双击安装。装到 `~/Library/Input Methods`，不需要管理员密码；装完自动登记、打开并切到 MyType。

也可以一行命令安装或升级：

```sh
curl -fsSL https://raw.githubusercontent.com/yxxbc/MyType/main/install.sh | bash
```

> 菜单栏的输入法菜单里没有 MyType：系统设置 → 键盘 → 文字输入 → 输入法 → 编辑 → ＋ → 简体中文 → MyType。

## 功能

| 特性 | 说明 |
|---|---|
| **整句输入** | 一次打完一整句，不用一个词一个词选；支持简拼、混拼、按错键纠正 |
| **双拼 / 五笔** | 自然码、小鹤、微软、搜狗、ABC、紫光、拼音加加；五笔 86 |
| **词库** | 自带雾凇拼音；可换万象拼音（词更多，多占约 300 MB 内存） |
| **本地语音** | 按一下右 Option 开始连续监听，再按一下上屏；本机识别，模型在设置里下载，录音不上传 |
| **互译** | 单按 Shift 在 中 → 英 → 译 之间切；也可用本地 HY-MT 模型 |
| **工具栏** | `v` + 空格：剪贴板、常用语、符号、表情 |
| **更新** | 设置 →「关于」里检查、下载、安装 |
| **轻** | 万象词库 + 语言模型峰值 188 MB；词库载入 0.2 s |

## 更新

设置 →「关于」里检查、下载、安装；每天最多自动检查一次，可以关。安装时 MyType 会退出，装完自动回来，设置和用户词都不动。

0.5.x 没有内置更新器，跑一次上面的安装命令（或双击新版 pkg）即可。

## 性能

相对上游 WowType 0.4.0：

| | 上游 | 这里 |
|---|---:|---:|
| 内存峰值（万象 + 语言模型） | 880 MB | **188 MB** |
| 词库常驻 | 590 MB | **39 MB** |
| 词库载入 | 1.3 s | **0.2 s** |
| 每次组句按键（平均） | ~4 ms | **2.35 ms** |

载入 0.2 s 指 `.wcache` 命中、模糊音索引已写进 v4 快照（mmap 的干净页）时的常驻载入；
首次建快照约 4–5 s（含写模糊音索引）。2026-11-23 复测：rime-ice 92.9 万条常驻载入
`--selftest` 显示 0.0 s（进程总耗时 0.06 s），5000 行 `user.tsv` 不再拖慢载入。

细节和评测见 [引擎文档](docs/ENGINE.md)。

## 数据

- 设置、用户词：`~/Library/Application Support/MyType`
- 词库：自带雾凇；万象拼音、语音模型、本地翻译模型都在设置里按需下载
- 录音和输入内容不上传；语音在本机识别

## 文档

- [示例与用法](docs/USAGE.md)
- [设置与配置](docs/CONFIG.md)
- [语音输入](docs/VOICE.md)
- [引擎与评测](docs/ENGINE.md)
- [词库与数据管线](docs/DATA.md)
- [开发与发布](docs/DEVELOPMENT.md)
- [目前做不到的](docs/LIMITATIONS.md)

## 许可

代码 MIT / Apache-2.0（[LICENSE-MIT](LICENSE-MIT)、[LICENSE-APACHE](LICENSE-APACHE)）；原项目 [Gloridust/WowType](https://github.com/Gloridust/WowType)，从 0.4.0 分出，原作者 Gloridust。

数据来源和许可见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。

<p align="center"><sub>MyType · made for macOS</sub></p>
