// Gera AppIcon.icns a partir de Resources/icon-source.png:
// recorta o quadrado escuro, aplica a máscara arredondada e a margem padrão do macOS (824 px em 1024).
// Uso: swift make_icon.swift
import AppKit

let src = NSImage(contentsOfFile: "Resources/icon-source.png")!
let rep0 = NSBitmapImageRep(data: src.tiffRepresentation!)!
let W = rep0.pixelsWide, H = rep0.pixelsHigh

// Caixa do fundo escuro (ignora bordas brancas/transparentes)
func dark(_ x: Int, _ y: Int) -> Bool {
    guard let c = rep0.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
    return c.alphaComponent > 0.5 && c.redComponent + c.greenComponent + c.blueComponent < 0.6
}
var minX = W, maxX = 0, minY = H, maxY = 0
for y in stride(from: 0, to: H, by: 2) { for x in stride(from: 0, to: W, by: 2) where dark(x, y) {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
let crop = NSRect(x: minX, y: H - maxY - 1, width: maxX - minX + 1, height: maxY - minY + 1)

let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px), side = s * 824 / 1024, o = (s - side) / 2
    let rect = NSRect(x: o, y: o, width: side, height: side)
    NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225).addClip()
    NSColor(calibratedRed: 0x15/255.0, green: 0x15/255.0, blue: 0x19/255.0, alpha: 1).setFill()
    rect.fill()
    // amplia um pouco o recorte para a borda arredondada original ficar fora da máscara
    let inset = crop.insetBy(dx: crop.width * 0.075, dy: crop.height * 0.075)
    src.draw(in: rect, from: inset, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
