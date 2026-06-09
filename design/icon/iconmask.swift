// iconmask.swift — turn a Gemini-generated squircle-on-white into a clean,
// transparent-cornered macOS icon plate. Usage:
//   swiftc iconmask.swift -o iconmask && ./iconmask <in.png> <out.png> <size>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func die(_ m: String) -> Never { FileHandle.standardError.write((m+"\n").data(using:.utf8)!); exit(1) }

let args = CommandLine.arguments
guard args.count == 4, let target = Int(args[3]) else { die("usage: iconmask <in> <out> <size>") }
let inURL = URL(fileURLWithPath: args[1]), outURL = URL(fileURLWithPath: args[2])

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("cannot read \(inURL.path)") }
let W = img.width, H = img.height
let cs = CGColorSpaceCreateDeviceRGB()

// --- read pixels (RGBA8) ---
var buf = [UInt8](repeating: 0, count: W*H*4)
guard let rctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W*4,
                           space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { die("ctx") }
rctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

// --- bounding box of "colorful" pixels (saturated squircle; excludes white bg + gray shadow) ---
var minX = W, minY = H, maxX = -1, maxY = -1
let chromaThresh = 28, alphaThresh: UInt8 = 24
for y in 0..<H {
    for x in 0..<W {
        let i = (y*W + x)*4
        let a = buf[i+3]; if a < alphaThresh { continue }
        let r = Int(buf[i]), g = Int(buf[i+1]), b = Int(buf[i+2])
        let chroma = max(r,g,b) - min(r,g,b)
        if chroma > chromaThresh {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
if maxX < 0 { die("no colored content found") }
let bw = maxX - minX + 1, bh = maxY - minY + 1
let side = max(bw, bh)
let cx = Double(minX + maxX) / 2.0, cy = Double(minY + maxY) / 2.0
FileHandle.standardError.write("bbox \(bw)x\(bh) at center (\(Int(cx)),\(Int(cy)))\n".data(using:.utf8)!)

// --- compose into target plate ---
let T = Double(target)
let liveFrac = 0.96          // squircle occupies 96% of canvas (2% transparent margin each side)
let overscan = 0.055         // draw source ~5.5% larger than the mask → no white edge halo
let radiusFrac = 0.2237      // Apple-ish corner radius of the rounded square
let live = T * liveFrac
let liveOrigin = (T - live) / 2.0
let radius = live * radiusFrac

guard let octx = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                           space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { die("octx") }
octx.clear(CGRect(x: 0, y: 0, width: target, height: target))

// Default CGContext is bottom-left origin; CGImage draws upright. The rounded-rect
// mask is symmetric. Only the source bbox center (top-left px) needs Y flipped.
let maskRect = CGRect(x: liveOrigin, y: liveOrigin, width: live, height: live)
let path = CGPath(roundedRect: maskRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
octx.addPath(path); octx.clip()

let scale = (live * (1.0 + overscan)) / Double(side)
let drawW = Double(W) * scale, drawH = Double(H) * scale
let originX = T/2.0 - cx*scale
let originY = T/2.0 + cy*scale - drawH    // map source-top-left cy into bottom-left space
octx.draw(img, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))

guard let outImg = octx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { die("encode") }
CGImageDestinationAddImage(dest, outImg, nil)
guard CGImageDestinationFinalize(dest) else { die("write \(outURL.path)") }
FileHandle.standardError.write("wrote \(outURL.path) (\(target)x\(target))\n".data(using:.utf8)!)
