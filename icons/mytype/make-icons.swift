// 生成 MyType 的图标（macOS 输入法 + 程序坞）。
//
//   swift icons/mytype/make-icons.swift [输出目录]     # 默认 icons/mytype
//
// 三个文件，都是同一条 M 笔画（单笔：左下起，上到顶、下到中间、再上到顶、落到右下）：
//   menu.pdf      16×16 pt：实心圆里挖出 M。菜单栏、输入法菜单、系统设置的输入法列表用它。
//   caret@2x.pdf  只有 M 一笔。切换输入法时光标旁边的提示用它（系统画蓝色气泡，M 画成白色）。
//   app-1024.png  程序坞里的彩色图标：墨绿圆角方块 + 白色 M，build.sh 缩成 iconset 打 icns。
// 生成的文件提交在仓库里，build.sh 直接拷，打包时不用再跑这个脚本。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons/mytype"

// 128×128（y 朝下）里的一条 M 笔画：和原来那笔 W 上下对折，粗细、留白一样。
func mPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 31, y: 78))
    p.addCurve(to: CGPoint(x: 47, y: 42), control1: CGPoint(x: 36, y: 56), control2: CGPoint(x: 40, y: 42))
    p.addCurve(to: CGPoint(x: 64, y: 68), control1: CGPoint(x: 55, y: 42), control2: CGPoint(x: 57, y: 68))
    p.addCurve(to: CGPoint(x: 81, y: 42), control1: CGPoint(x: 71, y: 68), control2: CGPoint(x: 73, y: 42))
    p.addCurve(to: CGPoint(x: 99, y: 88), control1: CGPoint(x: 89, y: 42), control2: CGPoint(x: 94, y: 62))
    return p
}

/// 一笔描成轮廓（圆头圆角），换到 PDF 坐标（y 朝上）并缩放、平移。
func strokeOutline(width: CGFloat, scale: CGFloat, page: CGSize, offset: CGPoint) -> CGPath {
    let outline = mPath().copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    var t = CGAffineTransform(translationX: offset.x, y: page.height - offset.y).scaledBy(x: scale, y: -scale)
    return outline.copy(using: &t)!
}

func writePDF(_ name: String, page: CGSize, path: CGPath) {
    let url = URL(fileURLWithPath: out).appendingPathComponent(name) as CFURL
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

// 菜单栏：16 pt 的圆，直径 15，M 笔画比圆里那笔稍粗，16 pt 下看得清
let menuPage = CGSize(width: 16, height: 16)
let menuScale = menuPage.width / 128
let disc = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: 15, height: 15), transform: nil)
let menuM = strokeOutline(width: 14, scale: menuScale, page: menuPage, offset: .zero)
writePDF("menu.pdf", page: menuPage, path: disc.subtracting(menuM))

// 光标旁的提示：照系统自带输入法（AinuIM 的 Ainu@2x.pdf，28×36）的做法只给字形，四周留一点边
let caretPage = CGSize(width: 32, height: 36)
let raw = mPath().copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 10).boundingBoxOfPath
let caretScale = (caretPage.width - 4) / raw.width
let glyphHeight = raw.height * caretScale
let caretM = strokeOutline(width: 14, scale: caretScale, page: caretPage,
                           offset: CGPoint(x: 2 - raw.minX * caretScale,
                                           y: (caretPage.height - glyphHeight) / 2 - raw.minY * caretScale))
writePDF("caret@2x.pdf", page: caretPage, path: caretM)

// 程序坞的彩色图标：墨绿圆角方块，白色 M 居中，四周留白
let side: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("建不了位图")
}
let corner = side * 0.2237 // 和系统图标差不多的圆角半径
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                   cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.setFillColor(CGColor(srgbRed: 0.122, green: 0.227, blue: 0.196, alpha: 1)) // #1F3A32
ctx.fillPath()

// 笔画缩到画布宽度的 60%，按包围盒居中（不用管 y 朝哪边）
let iconScale = side * 0.60 / raw.width
let iconWidth = raw.width * iconScale
let iconHeight = raw.height * iconScale
var transform = CGAffineTransform(translationX: (side - iconWidth) / 2, y: (side - iconHeight) / 2)
    .scaledBy(x: iconScale, y: iconScale)
    .translatedBy(x: -raw.minX, y: -raw.minY)
let iconM = mPath().copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.addPath(iconM.copy(using: &transform)!)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()

let pngURL = URL(fileURLWithPath: out).appendingPathComponent("app-1024.png")
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    fatalError("写不了 app-1024.png")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("写不了 app-1024.png") }
print("\(out)/app-1024.png")
