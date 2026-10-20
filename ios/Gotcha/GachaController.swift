import SceneKit
import SwiftUI
import UIKit

/// Builds the 3D gachapon machine and runs the turn → dispense → open sequence.
@MainActor
final class GachaController: ObservableObject {
    enum Phase { case idle, turning, dispensed, opening, reading, closing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: Int = 0
    @Published private(set) var slip: DrawnMessage?
    let total = Affirmations.all.count

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let deck = DeckStore()
    private let stage = SCNNode()
    private let lookTarget = SCNNode()
    private let knob = SCNNode()
    private let gripMaterial = Mat.pbr(.white, roughness: 0.3, clearCoat: 0.8)
    private let flapPivot = SCNNode()
    private var pile: [SCNNode] = []
    private var baseY: [ObjectIdentifier: Float] = [:]
    private var capsuleColor: [ObjectIdentifier: UIColor] = [:]
    private var dispensed: SCNNode?
    private var aspect: Float = 0.5
    private var homeCamPos = SCNVector3(0, 3, 12)
    private let homeTarget = SCNVector3(0, 1.85, 0.9)
    private var panStartYaw: Float = 0

    private lazy var reduceMotion = UIAccessibility.isReduceMotionEnabled
    private var M: Double { reduceMotion ? 0.35 : 1 }
    private lazy var clickHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private lazy var softHaptic = UIImpactFeedbackGenerator(style: .soft)
    private lazy var popHaptic = UIImpactFeedbackGenerator(style: .medium)

    // Machine dimensions (scene units)
    private let W: Float = 2.4, D: Float = 2.2, bodyH: Float = 2.3, glassH: Float = 1.6, capH: Float = 0.45
    private var front: Float { D / 2 }
    private let knobY: Float = 1.55, exitY: Float = 0.62, exitW: Float = 0.98, exitH: Float = 0.66
    private let R: Float = 0.29

    // Shared capsule geometry
    private lazy var geoTop = Geo.hemisphere(radius: R, upper: true)
    private lazy var geoBottom = Geo.hemisphere(radius: R, upper: false)
    private lazy var clearMat = Mat.clear(UIColor(hex: 0xFFF4F7), opacity: 0.5)
    private var colorMats: [UIColor: SCNMaterial] = [:]
    private let paperMat = Mat.pbr(UIColor(hex: 0xFFF6EA), roughness: 0.85)
    private let tieMat = Mat.pbr(UIColor(hex: 0xC9506F), roughness: 0.4, clearCoat: 0.5)

    init() {
        remaining = deck.remaining
        buildWorld()
        buildMachine()
        for _ in 0..<26 { _ = addToPile(fromAbove: false) }
        startGlow()
    }

    // MARK: - Public actions

    var actionTitle: String {
        switch phase {
        case .idle: return "Turn the handle"
        case .turning: return "Turning…"
        case .dispensed: return "Open the capsule"
        case .opening: return "Opening…"
        case .reading, .closing: return "…"
        }
    }
    var actionJapanese: String {
        switch phase {
        case .idle: return "まわす"
        case .dispensed: return "あける"
        default: return ""
        }
    }
    var actionEnabled: Bool { phase == .idle || phase == .dispensed }

    func primaryAction() {
        if phase == .idle { Task { await turn() } }
        else if phase == .dispensed { Task { await open() } }
    }

    func tapped(kind: String) {
        if kind == "knob", phase == .idle { Task { await turn() } }
        if kind == "capsule", phase == .dispensed { Task { await open() } }
    }

    func panBegan() { panStartYaw = stage.eulerAngles.y }
    func panChanged(dx: CGFloat) {
        guard phase == .idle || phase == .dispensed else { return }
        stage.eulerAngles.y = max(-0.9, min(0.9, panStartYaw + Float(dx) * 0.008))
    }

    func close(turnAgain: Bool) {
        Task { await closeSlip(turnAgain: turnAgain) }
    }

    func layout(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = Float(size.width / size.height)
        let tanH = tan(Float(17.5 * .pi / 180))
        let dist = max(3.6 / tanH, 2.05 / (tanH * aspect))
        let dir = SCNVector3(0, 0.22, 1)
        let len = sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
        homeCamPos = SCNVector3(homeTarget.x + dir.x / len * dist,
                                homeTarget.y + dir.y / len * dist,
                                homeTarget.z + dir.z / len * dist)
        if phase == .idle || phase == .turning || phase == .dispensed {
            cameraNode.position = homeCamPos
            lookTarget.position = homeTarget
        }
    }

    // MARK: - Sequences

    private func turn() async {
        guard phase == .idle else { return }
        phase = .turning
        clickHaptic.prepare()
        let stage = self.stage, knob = self.knob, flapPivot = self.flapPivot

        let yaw0 = stage.eulerAngles.y
        if abs(yaw0) > 0.01 {
            await animate(0.35 * M) { p, _ in stage.eulerAngles.y = lerp(yaw0, 0, p) }
        }
        jigglePile(duration: 1.2 * M)
        let start = knob.eulerAngles.z
        for i in 0..<4 {
            await animate(0.26 * M) { p, _ in knob.eulerAngles.z = start - (Float(i) + p) * .pi / 2 }
            clickHaptic.impactOccurred()
        }
        knob.eulerAngles.z = start - 2 * .pi

        // one capsule leaves the bin
        let by = baseY
        guard let taken = pile.max(by: { (by[ObjectIdentifier($0)] ?? 0) < (by[ObjectIdentifier($1)] ?? 0) }) else { return }
        pile.removeAll { $0 === taken }
        let color = capsuleColor[ObjectIdentifier(taken)] ?? Palette.capsules[0]
        baseY[ObjectIdentifier(taken)] = nil
        capsuleColor[ObjectIdentifier(taken)] = nil
        taken.runAction(.sequence([.scale(to: 0.01, duration: 0.25 * M), .removeFromParentNode()]))

        // out through the flap
        let c = makeCapsule(color: color, interactive: true)
        c.position = SCNVector3(0, exitY, front - 0.4)
        c.eulerAngles = SCNVector3(0.6, 0.4, 0.3)
        stage.addChildNode(c)
        dispensed = c
        softHaptic.impactOccurred(intensity: 0.8)
        let z0 = front - 0.4, z1 = front + 0.35
        await animate(0.32 * M, curve: Ease.out) { p, _ in
            c.position.z = lerp(z0, z1, p)
            flapPivot.eulerAngles.x = -sin(min(1, p * 1.3) * .pi) * 1.05
        }
        flapPivot.eulerAngles.x = 0

        let yA = exitY, zA = z1, zB = front + 1.2, r = R
        let rx0: Float = -0.55 - (zB - zA) / r
        await animate(0.85 * M, curve: Ease.out) { p, raw in
            c.position.z = lerp(zA, zB, p)
            c.position.y = r + (yA - r) * pow(1 - raw, 2) * abs(cos(raw * .pi * 2.5))
            c.eulerAngles.x = rx0 + (c.position.z - zA) / r
        }
        softHaptic.impactOccurred(intensity: 0.5)
        phase = .dispensed
        if !reduceMotion {
            let up = SCNAction.moveBy(x: 0, y: 0.12, z: 0, duration: 0.17)
            up.timingMode = .easeOut
            let down = SCNAction.moveBy(x: 0, y: -0.12, z: 0, duration: 0.17)
            down.timingMode = .easeIn
            c.runAction(.repeatForever(.sequence([.wait(duration: 1.6), up, down])), forKey: "hop")
        }

        if pile.count < 12 {
            var n = 0
            while n < 12 && addToPile(fromAbove: true) { n += 1 }
        }
    }

    private func open() async {
        guard phase == .dispensed, let c = dispensed else { return }
        phase = .opening
        popHaptic.prepare()
        c.removeAction(forKey: "hop")
        c.position.y = R
        let drawn = deck.draw()
        remaining = deck.remaining

        let stage = self.stage, cam = cameraNode, target = lookTarget
        let yaw0 = stage.eulerAngles.y
        // lift the capsule toward the viewer and frame it in the upper part of the screen
        let S: Float = 1.7, cy: Float = 1.35, cz = c.position.z + 0.6
        let tanH = tan(Float(17.5 * .pi / 180))
        let dist = max(1.6 / tanH, 1.0 / (tanH * aspect))
        let toT = SCNVector3(0, cy - tanH * dist * 0.42, cz)
        let toPos = SCNVector3(0, toT.y + dist * 0.18, cz + dist)
        let fromPos = cam.position, fromT = target.position
        let p0 = c.position, r0 = c.eulerAngles
        let tx = (r0.x / (2 * .pi)).rounded() * 2 * .pi
        await animate(0.8 * M) { p, _ in
            stage.eulerAngles.y = lerp(yaw0, 0, p)
            cam.position = lerp(fromPos, toPos, p)
            target.position = lerp(fromT, toT, p)
            c.position = SCNVector3(0, lerp(p0.y, cy, p), lerp(p0.z, cz, p))
            let s = lerp(1, S, p)
            c.scale = SCNVector3(s, s, s)
            c.eulerAngles = SCNVector3(lerp(r0.x, tx + 0.5, p), lerp(r0.y, 2 * .pi, p), lerp(r0.z, 0, p))
        }
        c.eulerAngles = SCNVector3(0.5, 0, 0)
        await animate(0.45 * M, curve: Ease.linear) { _, raw in
            c.eulerAngles.z = sin(raw * .pi * 8) * 0.16 * (1 - raw)
        }
        popHaptic.impactOccurred()
        if let lid = c.childNode(withName: "lid", recursively: false),
           let paper = c.childNode(withName: "paper", recursively: false) {
            let r = R
            await animate(0.55 * M, curve: Ease.back) { p, _ in
                lid.eulerAngles.x = -1.95 * p
                paper.position = SCNVector3(0, lerp(r * 0.18, r * 1.55, p), lerp(0, r * 0.35, p))
                paper.eulerAngles.x = p * 0.35
            }
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { slip = drawn }
        phase = .reading
    }

    private func closeSlip(turnAgain: Bool) async {
        guard phase == .reading else { return }
        phase = .closing
        withAnimation(.easeOut(duration: 0.2)) { slip = nil }
        let cam = cameraNode, target = lookTarget
        let fromPos = cam.position, fromT = target.position
        let toPos = homeCamPos, toT = homeTarget
        let c = dispensed
        await animate(0.6 * M) { p, _ in
            cam.position = lerp(fromPos, toPos, p)
            target.position = lerp(fromT, toT, p)
            if let c {
                let s = max(0.001, 1.7 * (1 - p))
                c.scale = SCNVector3(s, s, s)
            }
        }
        c?.removeFromParentNode()
        dispensed = nil
        phase = .idle
        if turnAgain { await turn() }
    }

    // MARK: - Animation helper

    /// Runs `step(easedProgress, rawProgress)` every frame for `duration` seconds on the render loop.
    private func animate(_ duration: Double, curve: @escaping @Sendable (Float) -> Float = Ease.inOut,
                         _ step: @escaping @Sendable (Float, Float) -> Void) async {
        let d = max(duration, 0.001)
        let holder = SCNNode()
        scene.rootNode.addChildNode(holder)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let action = SCNAction.customAction(duration: d) { @Sendable _, elapsed in
                let raw = Float(min(1, Double(elapsed) / d))
                step(curve(raw), raw)
            }
            holder.runAction(action) { @Sendable in cont.resume() }
        }
        holder.removeFromParentNode()
    }

    private func jigglePile(duration: Double) {
        for node in pile {
            let base = node.position
            let ph = Float.random(in: 0...(2 * .pi))
            let shake = SCNAction.customAction(duration: duration) { @Sendable n, elapsed in
                let t = Float(elapsed)
                n.position = SCNVector3(base.x + sin(t * 38 + ph) * 0.018,
                                        base.y + abs(sin(t * 31 + ph)) * 0.025,
                                        base.z)
            }
            node.runAction(.sequence([shake, .move(to: base, duration: 0.05)]))
        }
    }

    private func startGlow() {
        let grip = gripMaterial
        let glow = SCNAction.customAction(duration: 2 * .pi / 3) { @Sendable _, elapsed in
            grip.emission.intensity = 0.1 + 0.1 * sin(elapsed * 3)
        }
        knob.runAction(.repeatForever(glow), forKey: "glow")
    }

    // MARK: - World

    private func buildWorld() {
        let cam = SCNCamera()
        cam.fieldOfView = 35
        cam.zNear = 0.1
        cam.zFar = 100
        cam.wantsHDR = true
        cam.exposureOffset = 0.1
        cameraNode.camera = cam
        cameraNode.position = homeCamPos
        lookTarget.position = homeTarget
        scene.rootNode.addChildNode(lookTarget)
        let look = SCNLookAtConstraint(target: lookTarget)
        look.isGimbalLockEnabled = true
        cameraNode.constraints = [look]
        scene.rootNode.addChildNode(cameraNode)

        scene.lightingEnvironment.contents = environmentImage()
        scene.lightingEnvironment.intensity = 1.1
        scene.background.contents = UIColor.clear

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 180
        ambient.color = UIColor(hex: 0xF5E8EC)
        let ambientNode = SCNNode(); ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1100
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowColor = UIColor.black.withAlphaComponent(0.16)
        sun.shadowSampleCount = 16
        sun.shadowRadius = 6
        sun.automaticallyAdjustsShadowProjection = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        let sunNode = SCNNode(); sunNode.light = sun
        sunNode.position = SCNVector3(2.2, 9, 5)
        sunNode.look(at: SCNVector3(0, 1.5, 0))
        scene.rootNode.addChildNode(sunNode)

        let floor = SCNFloor()
        floor.reflectivity = 0
        let floorMat = SCNMaterial()
        floorMat.lightingModel = .shadowOnly
        floor.materials = [floorMat]
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        scene.rootNode.addChildNode(stage)
    }

    private func environmentImage() -> UIImage {
        renderLabel(size: CGSize(width: 512, height: 256)) { g, size in
            let colors = [UIColor.white.cgColor, UIColor(hex: 0xF1E6EA).cgColor, UIColor(hex: 0xB9A9B0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            g.setFillColor(UIColor.white.cgColor)
            g.fill(CGRect(x: 60, y: 30, width: 120, height: 50))
            g.fill(CGRect(x: 320, y: 40, width: 140, height: 40))
            g.fill(CGRect(x: 200, y: 10, width: 90, height: 25))
        }
    }

    // MARK: - Machine

    private func add(_ geo: SCNGeometry, _ mat: SCNMaterial, at p: SCNVector3, shadow: Bool = true, to parent: SCNNode? = nil) -> SCNNode {
        geo.materials = [mat]
        let n = SCNNode(geometry: geo)
        n.position = p
        n.castsShadow = shadow
        (parent ?? stage).addChildNode(n)
        return n
    }

    private func buildMachine() {
        let shell = Mat.pbr(Palette.shell, roughness: 0.36, clearCoat: 0.6)
        let trim = Mat.pbr(Palette.trim, roughness: 0.45, clearCoat: 0.3)
        let glassMat = Mat.clear(.white, opacity: 0.13)

        let cg = { (v: Float) in CGFloat(v) }
        _ = add(SCNBox(width: cg(W), height: cg(bodyH), length: cg(D), chamferRadius: 0.2), shell, at: SCNVector3(0, bodyH / 2, 0))
        _ = add(SCNBox(width: cg(W + 0.12), height: 0.14, length: cg(D + 0.12), chamferRadius: 0.06), trim, at: SCNVector3(0, 0.07, 0))

        let glassY0 = bodyH, glassY1 = bodyH + glassH
        let glass = add(SCNBox(width: cg(W - 0.1), height: cg(glassH), length: cg(D - 0.1), chamferRadius: 0.1), glassMat,
                        at: SCNVector3(0, glassY0 + glassH / 2, 0), shadow: false)
        glass.renderingOrder = 10

        for sx: Float in [-1, 1] {
            for sz: Float in [-1, 1] {
                _ = add(SCNBox(width: 0.16, height: cg(glassH + 0.02), length: 0.16, chamferRadius: 0.05), shell,
                        at: SCNVector3(sx * (W / 2 - 0.1), glassY0 + glassH / 2, sz * (D / 2 - 0.1)))
            }
        }
        _ = add(SCNBox(width: cg(W - 0.2), height: 0.02, length: cg(D - 0.2), chamferRadius: 0), trim,
                at: SCNVector3(0, glassY0 + 0.01, 0), shadow: false)
        _ = add(SCNBox(width: cg(W + 0.06), height: cg(capH), length: cg(D + 0.06), chamferRadius: 0.16), shell,
                at: SCNVector3(0, glassY1 + capH / 2, 0))

        // Top band label
        let topImg = renderLabel(size: CGSize(width: 1024, height: 150)) { g, size in
            let rect = CGRect(x: 4, y: 6, width: size.width - 8, height: size.height - 12)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 40)
            g.saveGState(); g.addPath(path.cgPath); g.clip()
            let colors = [UIColor(hex: 0xF29BB2).cgColor, UIColor(hex: 0xE47F99).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            g.restoreGState()
            drawText("ガチャガチャ", font: roundedFont(78, .black), color: .white, center: CGPoint(x: 54, y: 78), align: .left)
            drawText("GOTCHA", font: roundedFont(64, .black), color: .white, center: CGPoint(x: size.width - 58, y: 78), align: .right)
        }
        _ = add(SCNPlane(width: cg(W - 0.2), height: cg(capH - 0.12)), Mat.label(topImg),
                at: SCNVector3(0, glassY1 + capH / 2, front + 0.031), shadow: false)

        // Front panel label
        let labelH: Float = 2.05, labelY: Float = 0.25 + 2.05 / 2
        let toY = { (y: Float) -> CGFloat in CGFloat((labelY + labelH / 2 - y) / labelH * 1000) }
        let toX = { (x: Float) -> CGFloat in CGFloat((x + 1.05) / 2.1 * 1024) }
        let kY = knobY, eY = exitY, eW = exitW, eH = exitH
        let frontImg = renderLabel(size: CGSize(width: 1024, height: 1000)) { g, size in
            let ky = toY(kY), cx = size.width / 2
            g.setFillColor(Palette.pink.withAlphaComponent(0.16).cgColor)
            g.fillEllipse(in: CGRect(x: cx - 300, y: ky - 300, width: 600, height: 600))
            drawText("1回", font: roundedFont(58, .black), color: Palette.pinkInk, center: CGPoint(x: 112, y: ky - 60))
            drawText("¥200", font: roundedFont(62, .black), color: Palette.pinkInk, center: CGPoint(x: 112, y: ky + 14))
            drawText("ONE TURN", font: roundedFont(26, .bold), color: Palette.soft, center: CGPoint(x: 112, y: ky + 70))
            drawText("まわす", font: roundedFont(54, .black), color: Palette.pinkInk, center: CGPoint(x: 912, y: ky - 40))
            drawText("TURN", font: roundedFont(26, .bold), color: Palette.soft, center: CGPoint(x: 912, y: ky + 8))
            g.setStrokeColor(Palette.pink.cgColor); g.setLineWidth(12); g.setLineCap(.round)
            g.addArc(center: CGPoint(x: cx, y: ky), radius: 330, startAngle: -0.55, endAngle: 0.45, clockwise: false)
            g.strokePath()
            let ax = cx + 330 * cos(0.45), ay = ky + 330 * sin(0.45)
            g.setFillColor(Palette.pink.cgColor)
            g.move(to: CGPoint(x: ax - 34, y: ay - 6)); g.addLine(to: CGPoint(x: ax + 20, y: ay - 22)); g.addLine(to: CGPoint(x: ax + 6, y: ay + 34))
            g.closePath(); g.fillPath()
            // exit mouth
            let ex = toX(-eW / 2), ey = toY(eY + eH / 2)
            let ew = CGFloat(eW / 2.1 * 1024), eh = CGFloat(eH / labelH * 1000)
            let mouth = UIBezierPath(roundedRect: CGRect(x: ex, y: ey, width: ew, height: eh), cornerRadius: 46)
            g.saveGState(); g.addPath(mouth.cgPath); g.clip()
            let colors = [UIColor(hex: 0x120C0F).cgColor, UIColor(hex: 0x3B2D34).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                g.drawLinearGradient(grad, start: CGPoint(x: 0, y: ey), end: CGPoint(x: 0, y: ey + eh), options: [])
            }
            g.restoreGState()
            drawText("とりだしぐち  ·  TAKE OUT", font: roundedFont(24, .bold), color: Palette.soft, center: CGPoint(x: cx, y: ey - 26))
        }
        _ = add(SCNPlane(width: 2.1, height: cg(labelH)), Mat.label(frontImg), at: SCNVector3(0, labelY, front + 0.004), shadow: false)

        // Exit bezel
        let bezelPath = Geo.roundedRectPath(width: cg(exitW + 0.16), height: cg(exitH + 0.16), radius: 0.2)
        bezelPath.append(Geo.roundedRectPath(width: cg(exitW), height: cg(exitH), radius: 0.1))
        bezelPath.usesEvenOddFillRule = true
        let bezel = SCNShape(path: bezelPath, extrusionDepth: 0.07)
        bezel.chamferRadius = 0.02
        _ = add(bezel, shell, at: SCNVector3(0, exitY, front + 0.035))

        // Flap
        flapPivot.position = SCNVector3(0, exitY + exitH / 2 - 0.02, front + 0.08)
        stage.addChildNode(flapPivot)
        let flapMat = Mat.clear(UIColor(hex: 0xD8C4CC), opacity: 0.38)
        let flap = add(SCNPlane(width: cg(exitW - 0.04), height: cg(exitH - 0.04)), flapMat,
                       at: SCNVector3(0, -(exitH - 0.04) / 2, 0), shadow: false, to: flapPivot)
        flap.renderingOrder = 11

        // Knob
        knob.position = SCNVector3(0, knobY, front)
        knob.name = "knob"
        stage.addChildNode(knob)
        let disk = add(SCNCylinder(radius: 0.58, height: 0.14), shell, at: SCNVector3(0, 0, 0.07), to: knob)
        disk.eulerAngles.x = .pi / 2
        let ring = add(SCNTorus(ringRadius: 0.56, pipeRadius: 0.035), trim, at: SCNVector3(0, 0, 0.14), to: knob)
        ring.eulerAngles.x = .pi / 2
        gripMaterial.emission.contents = Palette.pink
        gripMaterial.emission.intensity = 0
        _ = add(SCNBox(width: 1.02, height: 0.24, length: 0.24, chamferRadius: 0.1), gripMaterial, at: SCNVector3(0, 0, 0.24), to: knob)
        let hub = add(SCNCylinder(radius: 0.1, height: 0.06), Mat.pbr(Palette.pink, roughness: 0.35, clearCoat: 0.8),
                      at: SCNVector3(0, 0, 0.37), to: knob)
        hub.eulerAngles.x = .pi / 2
        knob.enumerateHierarchy { n, _ in n.name = n.name ?? "knob" }
    }

    // MARK: - Capsules

    private func colorMat(_ c: UIColor) -> SCNMaterial {
        if let m = colorMats[c] { return m }
        let m = Mat.pbr(c, roughness: 0.3, clearCoat: 0.8)
        colorMats[c] = m
        return m
    }

    private func makeCapsule(color: UIColor, interactive: Bool) -> SCNNode {
        let g = SCNNode()
        let bottom = SCNNode(geometry: geoBottom.copy() as? SCNGeometry)
        bottom.geometry?.materials = [colorMat(color)]
        let band = SCNNode(geometry: SCNTube(innerRadius: CGFloat(R * 0.99), outerRadius: CGFloat(R * 1.03), height: CGFloat(R * 0.16)))
        band.geometry?.materials = [colorMat(color)]

        let lid = SCNNode()
        lid.name = "lid"
        lid.position = SCNVector3(0, 0, -R)
        let top = SCNNode(geometry: geoTop.copy() as? SCNGeometry)
        top.geometry?.materials = [clearMat]
        top.position = SCNVector3(0, 0.002, R)
        top.renderingOrder = 5
        top.castsShadow = false
        lid.addChildNode(top)

        let paper = SCNNode()
        paper.name = "paper"
        let roll = SCNNode(geometry: SCNCylinder(radius: CGFloat(R * 0.28), height: CGFloat(R * 1.05)))
        roll.geometry?.materials = [paperMat]
        roll.eulerAngles.z = .pi / 2
        let tie = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(R * 0.3), pipeRadius: CGFloat(R * 0.05)))
        tie.geometry?.materials = [tieMat]
        tie.eulerAngles.z = .pi / 2
        paper.addChildNode(roll); paper.addChildNode(tie)
        paper.position = SCNVector3(0, R * 0.18, 0)

        g.addChildNode(bottom); g.addChildNode(band); g.addChildNode(paper); g.addChildNode(lid)
        if interactive {
            g.name = "capsule"
            g.enumerateChildNodes { n, _ in if n.name == nil { n.name = "capsule" } }
        }
        return g
    }

    // Heap-settle placement inside the glass bin
    private func settleY(x: Float, z: Float, y0: Float) -> Float {
        var y = y0
        let s = 2 * R * 0.97
        for c in pile {
            let b = c.position
            let dx = x - b.x, dz = z - b.z, d2 = dx * dx + dz * dz
            let by = baseY[ObjectIdentifier(c)] ?? b.y
            if d2 < s * s { y = max(y, by + sqrt(s * s - d2)) }
        }
        return y
    }

    @discardableResult
    private func addToPile(fromAbove: Bool) -> Bool {
        let bx = W / 2 - 0.2 - R, bz = D / 2 - 0.2 - R
        let y0 = bodyH + 0.02 + R, y1 = bodyH + glassH - R - 0.04
        var best: SCNVector3?
        for _ in 0..<50 {
            let x = Float.random(in: -bx...bx), z = Float.random(in: -bz...bz)
            let y = settleY(x: x, z: z, y0: y0)
            if best == nil || y < best!.y { best = SCNVector3(x, y, z) }
        }
        guard let pos = best, pos.y <= y1 else { return false }
        let color = Palette.capsules.randomElement() ?? Palette.pink
        let c = makeCapsule(color: color, interactive: false)
        c.eulerAngles = SCNVector3(Float.random(in: 0...(2 * .pi)), Float.random(in: 0...(2 * .pi)), Float.random(in: 0...(2 * .pi)))
        baseY[ObjectIdentifier(c)] = pos.y
        capsuleColor[ObjectIdentifier(c)] = color
        stage.addChildNode(c)
        pile.append(c)
        if fromAbove {
            c.position = SCNVector3(pos.x, bodyH + glassH + 0.6, pos.z)
            let drop = SCNAction.move(to: pos, duration: 0.45 * M)
            drop.timingMode = .easeIn
            c.runAction(drop)
        } else {
            c.position = pos
        }
        return true
    }
}
