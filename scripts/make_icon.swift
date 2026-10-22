// 앱 아이콘(1024×1024 PNG) 그리기 — 둥근 사각형 + 그라데이션 배경 + 가운데 흰 SF Symbol
// 사용법: swift scripts/make_icon.swift <출력.png> [SF Symbol 이름] [색1] [색2] [색3] [frame]
//   예: swift scripts/make_icon.swift Resources/icon_1024.png eyedropper.full 6C4DF6 E9458F FF9F43 frame
//   색은 HEX(# 없이), 왼쪽 위 → 오른쪽 아래 그라데이션. 마지막에 frame을 붙이면 네 모서리 괄호(캡처 느낌)를 그림
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon_1024.png"
let symbolName = args.count > 2 ? args[2] : "sparkles"
let colorArgs = args.count > 5 ? [args[3], args[4], args[5]] : ["6C4DF6", "E9458F", "FF9F43"]
let drawFrame = args.contains("frame")
let canvas: CGFloat = 1024

func hex(_ v: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// macOS 아이콘 규격: 1024 캔버스 안에 824 크기의 둥근 사각형
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 1) 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: hex(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(hex(0x000000))
ctx.fillPath()
ctx.restoreGState()

// 2) 배경 그라데이션 (보라 → 분홍 → 주황)
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: srgb,
                    colors: colorArgs.map { hex(Int($0, radix: 16) ?? 0x888888) } as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY),
                       end: CGPoint(x: body.maxX, y: body.minY), options: [])

// 위쪽 은은한 빛
let shine = CGGradient(colorsSpace: srgb,
                       colors: [hex(0xFFFFFF, 0.28), hex(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: body.maxY),
                       end: CGPoint(x: 512, y: 480), options: [])

// 3) (선택) 캡처 영역 모서리 괄호
if drawFrame {
let frame = body.insetBy(dx: 150, dy: 150)
let arm: CGFloat = 125
ctx.setStrokeColor(hex(0xFFFFFF, 0.92))
ctx.setLineWidth(40)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let corners: [(CGPoint, CGFloat, CGFloat)] = [
    (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
    (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
    (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
    (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
]
for (p, dx, dy) in corners {
    ctx.move(to: CGPoint(x: p.x, y: p.y + dy * arm))
    ctx.addLine(to: p)
    ctx.addLine(to: CGPoint(x: p.x + dx * arm, y: p.y))
}
ctx.strokePath()
}
ctx.restoreGState()

// 4) 가운데 스포이드 (SF Symbol)
let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let rect = CGRect(x: (canvas - s.width) / 2, y: (canvas - s.height) / 2, width: s.width, height: s.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: hex(0x3A1466, 0.35))
    symbol.draw(in: rect)
    ctx.restoreGState()
} else {
    print("경고: SF Symbol '\(symbolName)'을 찾지 못해 배경만 그렸어요")
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("저장: \(outPath)")
