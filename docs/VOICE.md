# 语音输入

按住语音键说话，松开上屏；点一下开始说，停顿一会儿自动上屏；Esc 取消。识别在本机做，录音不上传。
默认语音键是右 Option（`VoiceKey=Alt_R`），设置窗口「语音」页可以改成右 Control、F8–F10 或关掉。

## 链路

```
MyTypeInputController（输入法进程）
  │  flagsChanged / keyDown / keyUp  ── VoiceInput.swift
  ▼
mytype_voice_key_down / key_up / poll / text / cancel   （core/src/voice_ffi.rs）
  │
  ├─ 工作线程：cpal 开默认输入设备 → 16kHz 单声道 → 20ms 分帧 + 能量 VAD
  │            → wtlocal 识别（边说边出中间结果）→ 松开后整段定稿
  └─ 模型线程：第一次按语音键时把模型读进内存，只做一次；没读完时音频先攒着
```

| 层 | 文件 | 做什么 |
|---|---|---|
| 外壳 | `macos/Sources/App/VoiceInput.swift` | 热键状态、编辑区里的中间结果、候选框里的麦克风和波形、上屏 / 取消 |
| C 接口 | `core/src/voice_ffi.rs` | `mytype_voice_new/key_down/key_up/poll/text/model_state/cancel`；都不阻塞，外壳每 50ms 取一次状态 |
| 采集 | `voice/src/capture.rs` | cpal，CoreAudio；优先直接要 16kHz 单声道，设备不支持时降混、低通、重采样 |
| 分段 | `voice/src/audio.rs`、`vad.rs` | 重采样、320 样本定长帧、自适应噪声底 + 起始确认 100ms + 挂起 480ms |
| 识别 | `voice/src/wtlocal/` | 微信输入法的离线模型，纯 Rust int8 推理，4 线程 |

## 麦克风权限

第一次按语音键（或在设置「语音」页点「测试」）时，macOS 会问要不要允许 MyType 使用麦克风。
允许后**再按一次**语音键；设置页会把输入法进程重新加载，重新读模型和权限。
被拒绝时到「系统设置 → 隐私与安全性 → 麦克风」里打开 MyType。

设置「语音」页的「麦克风」一行会显示权限状态，点「测试」录 3 秒，走和输入法一样的核心识别，
结果写在「上次测试」里——可以先确认麦克风和模型是否正常，再去输入框里试。

命令行也能测麦克风（会录 4 秒）：

```sh
"$HOME/Library/Input Methods/MyType.app/Contents/MacOS/MyType" --voice-mic-test 4
```

## 规则

- 按住 ≥300ms 松开即结束；更短算点按，说完约 2 秒（挂起 480ms + 静音 1.5 秒）或再按一次结束；单次最长 120 秒。
- 正在打拼音时语音键交给应用，不抢；`Option+方向键` 这类组合会让麦克风亮一下就停。
- 说话时按 `Esc` 丢掉；按别的键也丢掉，那个键照常处理；切走输入框（失去焦点、切输入法）丢掉。
- 结果只往开始说话的那个输入框上屏。
- 没下载模型时按语音键只提示「去设置里下载」，不碰麦克风、不下载。设置里语音输入的开关在下载好模型前是灰的（显示为关）。
- `VoiceCopy=True` 时说的话上屏后也复制到剪贴板（密码框里不复制）。

## 模型

模型是微信输入法的离线语音包（约 103 MB），**MyType 不分发它**：

- 设置窗口「语音」页点「下载」，从腾讯的服务器下载，校验后解到 `~/Library/Application Support/MyType/wtlocal/`（约 130 MB）；
  断了再点会接着下。和这台电脑装没装微信输入法无关。
- 命令行：`~/Library/Input\ Methods/MyType.app/Contents/MacOS/MyType --install-voice-model`（也接受下载好的 `.apk`）、
  `--remove-voice-model`。
- 地址、大小、MD5 钉在 `macos/Sources/App/VoiceModelInstaller.swift` 和 `voice/src/wtlocal/pack.rs`，两边的测试核对。
- 第一次说话时系统会问要不要允许 MyType 使用麦克风（下载完模型时设置窗口会先问一次）；MyType 更新后系统可能会再问一次。

识别效果（macOS TTS 合成语音，5 句全部正确）：

| 原文 | 识别 |
|---|---|
| 今天天气不错 | 今天天气不错。 |
| 明天下午三点开会 | 明天下午三点开会。 |
| 把这个文件发送给张三 | 把这个文件发送给张三。 |

1.7 秒音频推理约 0.16 秒（4 线程）。来源与适配说明见 `voice/src/wtlocal/NOTICE.md`。

## 测试

```sh
# 不开麦克风，读一个 16kHz 单声道 WAV 当成说的话，打印识别结果
"$HOME/Library/Input Methods/MyType.app/Contents/MacOS/MyType" --voice-test 说的话.wav

# 核心里的采集、VAD、热键状态机、识别
cargo test -p mytype-core voice
cargo test -p mytype-voice
```

`MYTYPE_VOICE_WAV` 也能让核心直接读 WAV（`--voice-test` 就是这么做的）。不设时用麦克风。

## 限制

- 只有一个识别结果，不能在候选里改；不能选麦克风（用系统默认的输入设备）。
- 模型不是开源许可，来源和再分发说明见 `voice/src/wtlocal/NOTICE.md`。
- 长句偶尔断句不对；识别结果直接上屏，标点由模型给。
