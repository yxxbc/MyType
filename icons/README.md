# 图标

macOS 输入法是单色模板图（黑色 + 透明的矢量 PDF），系统按菜单栏深浅色自己上色，
和系统自带的输入法、微信输入法一样。

- `mytype/menu.pdf`：16 pt，实心圆里挖出 M。菜单栏、输入法菜单、系统设置的输入法列表用它
- `mytype/caret@2x.pdf`：只有 M 那一笔。切换输入法时光标旁边的提示气泡用它
- `mytype/app-1024.png`：程序坞和「关于」页的彩色图标（墨绿圆角方块 + 白色 M），`macos/build.sh` 缩成 `AppIcon.icns`

三个文件由 `icons/mytype/make-icons.swift` 生成（只能在 macOS 上跑），生成的文件提交在仓库里，打包时直接拷：

```bash
swift icons/mytype/make-icons.swift
```

`macos/build.sh` 把 `menu.pdf`、`caret@2x.pdf` 和 `AppIcon.icns` 放进 `MyType.app/Contents/Resources/`，
`Info.plist` 的 `tsInputMethodIconFileKey`、`TISIconLabels` 指到它们。
