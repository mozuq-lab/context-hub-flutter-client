import Cocoa

// 同じベクター形状から両OSのアイコンを描画する。
func render(_ size: Int, _ path: String) throws {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let transform = AffineTransform(scale: CGFloat(size) / 1024)
  (transform as NSAffineTransform).concat()
  NSColor(calibratedRed: 0.09, green: 0.25, blue: 0.23, alpha: 1).setFill()
  NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 214, yRadius: 214).fill()
  for (x,y,alpha) in [(240.0,285.0,0.3),(330.0,345.0,0.6),(420.0,405.0,1.0)] {
    NSColor(calibratedRed: 0.66, green: 0.92, blue: 0.81, alpha: alpha).setFill()
    NSBezierPath(roundedRect: NSRect(x:x,y:y,width:340,height:390),xRadius:44,yRadius:44).fill()
  }
  NSColor(calibratedRed: 0.09, green: 0.25, blue: 0.23, alpha: 1).setStroke()
  for y in [665.0,585.0] {
    let line = NSBezierPath();line.lineWidth = 28;line.lineCapStyle = .round
    line.move(to:NSPoint(x:490,y:y));line.line(to:NSPoint(x:682,y:y));line.stroke()
  }
  NSColor(calibratedRed: 0.95, green: 0.79, blue: 0.43, alpha: 1).setFill()
  NSBezierPath(ovalIn:NSRect(x:637,y:205,width:172,height:172)).fill()
  NSGraphicsContext.restoreGraphicsState()
  try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
}
for size in [16,32,64,128,256,512,1024] {
  try render(size,"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_\(size).png")
}
for (density,size) in [("mdpi",48),("hdpi",72),("xhdpi",96),("xxhdpi",144),("xxxhdpi",192)] {
  try render(size,"android/app/src/main/res/mipmap-\(density)/ic_launcher.png")
}
