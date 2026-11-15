// 生成 MyType 的图标（macOS 输入法 + 程序坞）。
//
//   swift icons/mytype/make-icons.swift [输出目录]     # 默认 icons/mytype
//
// 三个文件：
//   app-1024.png  程序坞 / 关于页的彩色图标：水墨锦鲤（app-source.png）裁成 macOS squircle。
//   menu.pdf      16×16 pt：锦鲤剪影。菜单栏、输入法菜单、系统设置的输入法列表用它。
//   caret@2x.pdf  32×36 pt：同一条锦鲤。切换输入法时光标旁的提示用它（系统画蓝色气泡，图是白色）。
// app-source.png 是 AI 生成的 1254×1254 原图，留着重出用；生成的文件提交在仓库里，build.sh 直接拷。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons/mytype"
let outURL = URL(fileURLWithPath: out)

// 128×128（y 朝下）里的一条锦鲤：头在左下，背向右上，尾巴分叉。
func fishPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 20, y: 82)) // 嘴
    p.addCurve(to: CGPoint(x: 62, y: 46), control1: CGPoint(x: 24, y: 62), control2: CGPoint(x: 40, y: 48))
    p.addCurve(to: CGPoint(x: 88, y: 56), control1: CGPoint(x: 74, y: 44), control2: CGPoint(x: 84, y: 48))
    p.addLine(to: CGPoint(x: 112, y: 30)) // 上尾尖
    p.addLine(to: CGPoint(x: 102, y: 58)) // 尾叉
    p.addLine(to: CGPoint(x: 112, y: 84)) // 下尾尖
    p.addLine(to: CGPoint(x: 88, y: 66))
    p.addCurve(to: CGPoint(x: 52, y: 92), control1: CGPoint(x: 78, y: 82), control2: CGPoint(x: 66, y: 92))
    p.addCurve(to: CGPoint(x: 20, y: 82), control1: CGPoint(x: 36, y: 92), control2: CGPoint(x: 24, y: 90))
    p.closeSubpath()
    // 背鳍
    p.move(to: CGPoint(x: 52, y: 48))
    p.addLine(to: CGPoint(x: 58, y: 26))
    p.addLine(to: CGPoint(x: 70, y: 50))
    p.closeSubpath()
    // 胸鳍
    p.move(to: CGPoint(x: 36, y: 78))
    p.addLine(to: CGPoint(x: 28, y: 96))
    p.addLine(to: CGPoint(x: 50, y: 86))
    p.closeSubpath()
    return p
}

/// 把 128×128 的鱼按比例放到页面上并居中（PDF 坐标 y 朝上）。
func fishOnPage(_ page: CGSize, margin: CGFloat) -> CGPath {
    let bbox = fishPath().boundingBoxOfPath
    let scale = min((page.width - margin * 2) / bbox.width, (page.height - margin * 2) / bbox.height)
    let w = bbox.width * scale, h = bbox.height * scale
    var t = CGAffineTransform(translationX: (page.width - w) / 2 - bbox.minX * scale,
                              y: (page.height + h) / 2 + bbox.minY * scale)
        .scaledBy(x: scale, y: -scale)
    return fishPath().copy(using: &t)!
}

func writePDF(_ name: String, page: CGSize, path: CGPath) {
    let url = outURL.appendingPathComponent(name) as CFURL
    var box = CGRect(origin: .zero, size: page)
    let info = [kCGPDFContextCreator as String: "MyType icons/mytype/make-icons.swift"] as CFDictionary
    guard let ctx = CGContext(url, mediaBox: &box, info) else { fatalError("写不了 \(name)") }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.endPDFPage()
    ctx.closePDF()
    print("\(out)/\(name)")
}

// 菜单栏：16 pt，锦鲤剪影；四周留 1.5 pt
let menuPage = CGSize(width: 16, height: 16)
writePDF("menu.pdf", page: menuPage, path: fishOnPage(menuPage, margin: 1.5))

// 光标旁的提示：32×36，鱼大一点，四周留 2 pt
let caretPage = CGSize(width: 32, height: 36)
writePDF("caret@2x.pdf", page: caretPage, path: fishOnPage(caretPage, margin: 2))

// 程序坞图标：水墨锦鲤原图裁成 macOS squircle（圆角比原图稍大，去掉原图的白角）
let side = 1024
let sourceURL = outURL.appendingPathComponent("app-source.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("读不了 app-source.png")
}
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("建不了位图")
}
let radius = CGFloat(side) * 0.26
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                   cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.interpolationQuality = .high
// 去掉原图最外圈的 1–2 px 白边，免得圆角边缘留一圈白
let inset: CGFloat = 4
let cropped = image.cropping(to: CGRect(x: inset, y: inset,
                                         width: CGFloat(image.width) - inset * 2,
                                         height: CGFloat(image.height) - inset * 2)) ?? image
ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
let pngURL = outURL.appendingPathComponent("app-1024.png")
guard let outImage = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("写不了 app-1024.png")
}
CGImageDestinationAddImage(dest, outImage, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("写不了 app-1024.png") }
print("\(out)/app-1024.png")
