import SceneKit
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}

enum Palette {
    static let shell = UIColor(hex: 0xF8F6F7)
    static let trim = UIColor(hex: 0xEBE5E8)
    static let pink = UIColor(hex: 0xE9879F)
    static let pinkInk = UIColor(hex: 0xA8445E)
    static let soft = UIColor(hex: 0x8B7882)
    static let capsules: [UIColor] = [0xF2A2B6, 0xF7BCCB, 0xEC8EA6, 0xF5C3CD, 0xF0AFC3, 0xE98AA3].map { UIColor(hex: $0) }
}

enum Ease {
    static func inOut(_ t: Float) -> Float { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func out(_ t: Float) -> Float { 1 - pow(1 - t, 3) }
    static func back(_ t: Float) -> Float {
        let c1: Float = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
    static func linear(_ t: Float) -> Float { t }
}

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
func lerp(_ a: SCNVector3, _ b: SCNVector3, _ t: Float) -> SCNVector3 {
    SCNVector3(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t))
}

enum Mat {
    static func pbr(_ color: UIColor, roughness: CGFloat, clearCoat: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        m.clearCoat.contents = clearCoat
        m.clearCoatRoughness.contents = 0.2
        return m
    }

    static func clear(_ color: UIColor, opacity: CGFloat) -> SCNMaterial {
        let m = pbr(color, roughness: 0.05, clearCoat: 1)
        m.transparency = opacity
        m.blendMode = .alpha
        m.transparencyMode = .dualLayer
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }

    static func label(_ image: UIImage) -> SCNMaterial {
        let m = pbr(.white, roughness: 0.4, clearCoat: 0.4)
        m.diffuse.contents = image
        m.transparent.contents = image
        m.transparencyMode = .aOne
        m.blendMode = .alpha
        return m
    }
}

enum Geo {
    /// Half of a UV sphere, built by hand because SCNSphere is always whole.
    static func hemisphere(radius r: Float, upper: Bool, segments: Int = 40, rings: Int = 16) -> SCNGeometry {
        var verts: [SCNVector3] = []
        var norms: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var idx: [UInt32] = []
        for i in 0...rings {
            let t = Float(i) / Float(rings) * (.pi / 2)
            let phi = upper ? t : (.pi / 2 + t)
            for j in 0...segments {
                let th = Float(j) / Float(segments) * 2 * .pi
                let x = sin(phi) * cos(th), y = cos(phi), z = sin(phi) * sin(th)
                verts.append(SCNVector3(x * r, y * r, z * r))
                norms.append(SCNVector3(x, y, z))
                uvs.append(CGPoint(x: CGFloat(j) / CGFloat(segments), y: CGFloat(i) / CGFloat(rings)))
            }
        }
        let cols = segments + 1
        for i in 0..<rings {
            for j in 0..<segments {
                let a = UInt32(i * cols + j), b = UInt32((i + 1) * cols + j)
                let c = a + 1, d = b + 1
                idx += [a, c, b, c, d, b]
            }
        }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts),
                                        SCNGeometrySource(normals: norms),
                                        SCNGeometrySource(textureCoordinates: uvs)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        return geo
    }

    static func roundedRectPath(width w: CGFloat, height h: CGFloat, radius r: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: r)
    }
}

/// Draws a texture for a label plane.
func renderLabel(size: CGSize, draw: (CGContext, CGSize) -> Void) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        draw(ctx.cgContext, size)
    }
}

func roundedFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: d, size: size) }
    return base
}

func drawText(_ text: String, font: UIFont, color: UIColor, center: CGPoint, align: NSTextAlignment = .center) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let s = NSAttributedString(string: text, attributes: attrs)
    let sz = s.size()
    var x = center.x - sz.width / 2
    if align == .left { x = center.x }
    if align == .right { x = center.x - sz.width }
    s.draw(at: CGPoint(x: x, y: center.y - sz.height / 2))
}
