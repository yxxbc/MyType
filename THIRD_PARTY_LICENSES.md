# 第三方许可与数据来源

MyType 的**代码**按 MIT 或 Apache License 2.0 双许可发布：

- [LICENSE-MIT](LICENSE-MIT)
- [LICENSE-APACHE](LICENSE-APACHE)
- [NOTICE](NOTICE)

原项目是 [Gloridust/WowType](https://github.com/Gloridust/WowType)，原作者 Gloridust；本仓库的修改由 yxxbc 维护。

下面这些**数据、模型和可选下载**不是代码，许可和代码分开。随安装包分发的，许可证也随包放在
`MyType.app/Contents/Resources/` 里；不随包分发的，写明来源和下载方式。

## 随安装包分发

| 内容 | 文件 | 来源 | 许可 | 包里的许可文件 |
|---|---|---|---|---|
| 雾凇拼音词库 | `lexicon.tsv`、`english.txt` | [iDvel/rime-ice](https://github.com/iDvel/rime-ice)，提交 `927e1cf1…` | GPL-3.0 | `DATA-LICENSE` |
| 语料词频 | `data/tatoeba-freq.tsv`（构建时融进词库） | [Tatoeba](https://tatoeba.org) 中文句子，2026-11-05 导出 | CC BY 2.0 FR（作者：Tatoeba contributors） | 说明见 `DATA-SOURCE.txt` |
| 词级语言模型 | `words.lm`（构建时下载） | LCCC（清华 CoAI，MIT）+ 中文维基百科（CC BY-SA 4.0） | CC BY-SA 4.0 | `DATA-SOURCE.txt` |
| 五笔 86 码表 | `wubi86.tsv` | [rime/rime-wubi](https://github.com/rime/rime-wubi)，提交 `152a0d3f…` | LGPL-3.0 | `DATA-WUBI-LICENSE`、`DATA-WUBI-AUTHORS` |
| 简繁对照表 | `s2t.tsv` | [OpenCC](https://github.com/BYVoid/OpenCC) | Apache-2.0 | `OPENCC-LICENSE`（仓库里也有 `core/data/OPENCC-LICENSE`） |
| Emoji 表 | `core/src/emoji/cldr.tsv` | Unicode emoji-test 18.0、Unicode CLDR 注释 | Unicode License v3 | 文件头有版权和许可链接 |
| 图标 | `icons/mytype/app-source.png` 等 | 本项目生成 | 随代码按 MIT / Apache-2.0 发布 | — |
| GitHub 猫标 | `icons/mytype/github.png` | GitHub, Inc. 的 Octocat 标志 | GitHub 的商标；只用在「关于」页链接到项目仓库，不表示 GitHub 认可本项目 | — |

`lexicon.tsv` 的来源、版本和转换方式在 `dist/data/SOURCE.txt`（打包时复制成 `DATA-SOURCE.txt`）；
`wubi86.tsv` 的来源、版本和转换方式在 `dist/data/WUBI-SOURCE.txt`（`DATA-WUBI-SOURCE.txt`）。

## 可选下载，不随包分发

| 内容 | 何时下载 | 来源 | 许可 |
|---|---|---|---|
| 万象拼音词库 | 设置「输入」页手动下载 | [amzxyz/rime_wanxiang](https://github.com/amzxyz/rime_wanxiang) 转换 | CC BY 4.0（包里有 `LICENSE`） |
| 微信离线语音模型 | 设置「语音」页手动下载 | 腾讯微信输入法官方 CDN | 腾讯的资源包；不随本项目分发，再分发有风险 |
| 本地翻译模型 HY-MT 1.5 1.8B | 设置「翻译」页手动下载 | [腾讯 HY-MT1.5-1.8B-GGUF](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF) | Tencent HY Community License；不是开源协议，不适用于欧盟、英国和韩国，月活超过 1 亿要另找腾讯授权 |
| llama.cpp 的 `llama-server` | 下载本地翻译模型时可选 | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp/releases) | MIT |
| Rust 依赖 | 构建时由 Cargo 下载 | [crates.io](https://crates.io) | 各 crate 自己的许可，见 `Cargo.lock` 和 crate 元数据 |

## 语音识别代码

`voice/src/wtlocal/` 的离线识别实现来自 [J3n5en/voicekey](https://github.com/J3n5en/voicekey) 的
`crates/wtlocal`，经作者同意后引入，适配说明见 [voice/src/wtlocal/NOTICE.md](voice/src/wtlocal/NOTICE.md)。
模型本身是腾讯的资源包，不随仓库分发；下载、校验和解包在设置窗口「语音」页。
