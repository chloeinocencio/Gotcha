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
    private let homeTarget = SCNVector3(0, 2.05, 0.9)
    private var panStartYaw: Float = 0

    private lazy var reduceMotion = UIAccessibility.isReduceMotionEnabled
    private var M: Double { reduceMotion ? 0.35 : 1 }
    private lazy var clickHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private lazy var softHaptic = UIImpactFeedbackGenerator(style: .soft)
    private lazy var popHaptic = UIImpactFeedbackGenerator(style: .medium)

    // Machine dimensions (scene units)
    private let W: Float = 2.4, D: Float = 2.2, bodyH: Float = 2.5, glassH: Float = 1.75, capH: Float = 0.3
    private var front: Float { D / 2 }
    private var face: Float { front + 0.06 } // front of the raised face plate on the mechanism unit
    private var glassY0: Float { bodyH + 0.1 }
    private var glassY1: Float { glassY0 + glassH }
    private let knobY: Float = 1.62, exitY: Float = 0.6, exitW: Float = 0.8, exitH: Float = 0.66
    private let slotX: Float = 0.78, slotY: Float = 2.24, returnX: Float = 0.82
    private let R: Float = 0.29

    // Shared capsule geometry
    private lazy var geoTop = Geo.hemisphere(radius: R, upper: true)
    private lazy var geoBottom = Geo.hemisphere(radius: R, upper: false)
    private lazy var clearMat = Mat.clear(UIColor(hex: 0xF4F8FF), opacity: 0.5)
    private var colorMats: [UIColor: SCNMaterial] = [:]
    private let paperMat = Mat.pbr(UIColor(hex: 0xFFF6EA), roughness: 0.85)
    private let tieMat = Mat.pbr(UIColor(hex: 0x1C4A94), roughness: 0.4, clearCoat: 0.5)

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
        let dist = max(3.75 / tanH, 2.05 / (tanH * aspect))
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
        c.position = SCNVector3(0, exitY, face - 0.4)
        c.eulerAngles = SCNVector3(0.6, 0.4, 0.3)
        stage.addChildNode(c)
        dispensed = c
        softHaptic.impactOccurred(intensity: 0.8)
        let z0 = face - 0.4, z1 = face + 0.35
        await animate(0.32 * M, curve: Ease.out) { p, _ in
            c.position.z = lerp(z0, z1, p)
            flapPivot.eulerAngles.x = -sin(min(1, p * 1.3) * .pi) * 1.05
        }
        flapPivot.eulerAngles.x = 0

        let yA = exitY, zA = z1, zB = face + 1.2, r = R
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
        if reduceMotion { grip.emission.intensity = 0.12; return }
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
        ambient.color = UIColor(hex: 0xE8EEF7)
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
            let colors = [UIColor.white.cgColor, UIColor(hex: 0xE6ECF4).cgColor, UIColor(hex: 0xA9B4C4).cgColor] as CFArray
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

    // Modelled on the classic capsule-toy machine: a clear display case on top with a printed card inside,
    // and a cream mechanism unit below with a big white dial in a blue ring, a coin slot and a smoked exit flap.
    private func buildMachine() {
        let shell = Mat.pbr(Palette.shell, roughness: 0.45, clearCoat: 0.35)
        let trim = Mat.pbr(Palette.trim, roughness: 0.5, clearCoat: 0.2)
        let grey = Mat.pbr(UIColor(hex: 0x8C8F96), roughness: 0.35)
        grey.metalness.contents = 0.6
        let dark = Mat.pbr(UIColor(hex: 0x1B1D22), roughness: 0.6)
        let glassMat = Mat.clear(.white, opacity: 0.07)
        let cg = { (v: Float) in CGFloat(v) }

        // Mechanism unit, its raised face plate, the base and the seam band under the display case
        _ = add(SCNBox(width: cg(W), height: cg(bodyH), length: cg(D), chamferRadius: 0.16), shell, at: SCNVector3(0, bodyH / 2, 0))
        _ = add(SCNBox(width: cg(W - 0.14), height: cg(bodyH - 0.18), length: 0.1, chamferRadius: 0.05), shell,
                at: SCNVector3(0, bodyH / 2 + 0.02, front + 0.01))
        _ = add(SCNBox(width: cg(W + 0.06), height: 0.1, length: cg(D + 0.06), chamferRadius: 0.04), trim, at: SCNVector3(0, 0.05, 0))
        _ = add(SCNBox(width: cg(W + 0.04), height: 0.12, length: cg(D + 0.04), chamferRadius: 0.05), trim, at: SCNVector3(0, bodyH + 0.04, 0))

        // Display case: one clear window, back posts only, cap on top
        let glass = add(SCNBox(width: cg(W - 0.04), height: cg(glassH), length: cg(D - 0.04), chamferRadius: 0.16), glassMat,
                        at: SCNVector3(0, glassY0 + glassH / 2, 0), shadow: false)
        glass.renderingOrder = 10
        for sx: Float in [-1, 1] {
            _ = add(SCNBox(width: 0.12, height: cg(glassH), length: 0.12, chamferRadius: 0.04), shell,
                    at: SCNVector3(sx * (W / 2 - 0.08), glassY0 + glassH / 2, -(D / 2 - 0.08)))
        }
        _ = add(SCNBox(width: cg(W - 0.12), height: 0.02, length: cg(D - 0.12), chamferRadius: 0), trim,
                at: SCNVector3(0, glassY0 + 0.01, 0), shadow: false)
        _ = add(SCNBox(width: cg(W + 0.04), height: cg(capH), length: cg(D + 0.04), chamferRadius: 0.13), shell,
                at: SCNVector3(0, glassY1 + capH / 2, 0))

        // Brand badge on the cap
        let badgeImg = renderLabel(size: CGSize(width: 512, height: 114)) { g, size in
            let r = UIBezierPath(roundedRect: CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12), cornerRadius: 18)
            g.setFillColor(UIColor.white.cgColor); g.addPath(r.cgPath); g.fillPath()
            g.setStrokeColor(Palette.blueInk.cgColor); g.setLineWidth(8); g.addPath(r.cgPath); g.strokePath()
            drawText("GOTCHA", font: roundedFont(64, .black), color: Palette.blueInk, center: CGPoint(x: size.width / 2, y: size.height / 2 + 2))
        }
        _ = add(SCNPlane(width: 0.9, height: 0.2), Mat.label(badgeImg), at: SCNVector3(0, glassY1 + capH / 2, front + 0.025), shadow: false)

        // Printed card standing just behind the front of the display case
        let cardW: Float = 1.7, cardH: Float = 1.3
        _ = add(SCNPlane(width: cg(cardW), height: cg(cardH)), Mat.label(cardImage()),
                at: SCNVector3(0, glassY0 + 0.08 + cardH / 2, front - 0.08), shadow: false)

        // Mechanism face
        let lw = W - 0.18, lh = bodyH - 0.22, ly = bodyH / 2 + 0.02
        _ = add(SCNPlane(width: cg(lw), height: cg(lh)), Mat.label(faceImage(lw: lw, lh: lh, ly: ly)),
                at: SCNVector3(0, ly, face + 0.002), shadow: false)

        // Exit bezel and the small take-out lip under it
        let bezelPath = Geo.roundedRectPath(width: cg(exitW + 0.14), height: cg(exitH + 0.14), radius: 0.1)
        bezelPath.append(Geo.roundedRectPath(width: cg(exitW), height: cg(exitH), radius: 0.06))
        bezelPath.usesEvenOddFillRule = true
        let bezel = SCNShape(path: bezelPath, extrusionDepth: 0.07)
        bezel.chamferRadius = 0.02
        _ = add(bezel, shell, at: SCNVector3(0, exitY, face + 0.025))
        _ = add(SCNBox(width: cg(exitW + 0.14), height: 0.06, length: 0.16, chamferRadius: 0.025), shell,
                at: SCNVector3(0, exitY - exitH / 2 - 0.1, face + 0.06))

        // Smoked flap with the brand moulded into it
        flapPivot.position = SCNVector3(0, exitY + exitH / 2 - 0.02, face + 0.07)
        stage.addChildNode(flapPivot)
        let flapMat = Mat.pbr(UIColor(hex: 0x101216), roughness: 0.25, clearCoat: 0.3)
        flapMat.transparency = 0.92
        flapMat.blendMode = .alpha
        flapMat.isDoubleSided = true
        flapMat.writesToDepthBuffer = false
        let flap = add(SCNPlane(width: cg(exitW - 0.04), height: cg(exitH - 0.04)), flapMat,
                       at: SCNVector3(0, -(exitH - 0.04) / 2, 0), shadow: false, to: flapPivot)
        flap.renderingOrder = 11
        let flapImg = renderLabel(size: CGSize(width: 512, height: 440)) { _, size in
            let f = roundedFont(120, .black)
            for (t, dy) in [("GOT", -66.0), ("CHA", 66.0)] {
                drawText(t, font: f, color: UIColor.black.withAlphaComponent(0.35), center: CGPoint(x: size.width / 2 + 3, y: size.height / 2 + dy + 3))
                drawText(t, font: f, color: UIColor.white.withAlphaComponent(0.1), center: CGPoint(x: size.width / 2, y: size.height / 2 + dy))
            }
        }
        let flapLabelMat = Mat.label(flapImg)
        flapLabelMat.writesToDepthBuffer = false
        let flapLabel = add(SCNPlane(width: cg(exitW - 0.04), height: cg(exitH - 0.04)), flapLabelMat,
                            at: SCNVector3(0, -(exitH - 0.04) / 2, 0.003), shadow: false, to: flapPivot)
        flapLabel.renderingOrder = 12

        // Coin slot and coin-return button
        let boss = add(SCNCone(topRadius: 0.12, bottomRadius: 0.13, height: 0.05), grey, at: SCNVector3(slotX, slotY, face + 0.025))
        boss.eulerAngles.x = .pi / 2
        _ = add(SCNBox(width: 0.035, height: 0.15, length: 0.02, chamferRadius: 0), dark, at: SCNVector3(slotX, slotY, face + 0.052), shadow: false)
        let btn = add(SCNCone(topRadius: 0.075, bottomRadius: 0.085, height: 0.06), grey, at: SCNVector3(returnX, knobY, face + 0.03))
        btn.eulerAngles.x = .pi / 2
        let btnFace = add(SCNCylinder(radius: 0.05, height: 0.01), dark, at: SCNVector3(returnX, knobY, face + 0.062), shadow: false)
        btnFace.eulerAngles.x = .pi / 2

        // Knob: a big white dial with a raised paddle across it
        knob.position = SCNVector3(0, knobY, face)
        knob.name = "knob"
        stage.addChildNode(knob)
        let dialMat = Mat.pbr(UIColor(hex: 0xFAF8F2), roughness: 0.35, clearCoat: 0.6)
        let disk = add(SCNCone(topRadius: 0.39, bottomRadius: 0.42, height: 0.1), dialMat, at: SCNVector3(0, 0, 0.05), to: knob)
        disk.eulerAngles.x = .pi / 2
        let dome = add(Geo.hemisphere(radius: 0.37, upper: true), dialMat, at: SCNVector3(0, 0, 0.1), to: knob)
        dome.scale = SCNVector3(1, 0.22, 1)
        dome.eulerAngles.x = .pi / 2
        let rim = add(SCNTorus(ringRadius: 0.405, pipeRadius: 0.022), trim, at: SCNVector3(0, 0, 0.1), to: knob)
        rim.eulerAngles.x = .pi / 2
        gripMaterial.emission.contents = Palette.blue
        gripMaterial.emission.intensity = 0
        _ = add(SCNBox(width: 0.74, height: 0.18, length: 0.24, chamferRadius: 0.08), gripMaterial, at: SCNVector3(0, 0, 0.2), to: knob)
        knob.enumerateHierarchy { n, _ in n.name = n.name ?? "knob" }
    }

    /// An original card in the spirit of the printed capsule-toy cards.
    private func cardImage() -> UIImage {
        renderLabel(size: CGSize(width: 768, height: 586)) { g, size in
            let w = size.width, h = size.height
            let colors = [UIColor(hex: 0x9FC4FB).cgColor, UIColor(hex: 0x5F97EA).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h), options: [])
            }
            g.setFillColor(UIColor.white.withAlphaComponent(0.55).cgColor) // clouds
            for (cx, cy, r) in [(90.0, 120.0, 46.0), (140, 110, 36), (640, 90, 40), (690, 104, 30), (600, 420, 34)] {
                g.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            g.setFillColor(Palette.yellow.cgColor) // corner burst
            for i in 0..<24 {
                let a = CGFloat(i) / 24 * 2 * .pi, r: CGFloat = i % 2 == 1 ? 54 : 66
                let p = CGPoint(x: 670 + cos(a) * r, y: 396 + sin(a) * r)
                if i == 0 { g.move(to: p) } else { g.addLine(to: p) }
            }
            g.closePath(); g.fillPath()
            drawText("1", font: roundedFont(30, .black), color: Palette.blueInk, center: CGPoint(x: 670, y: 378))
            drawText("TURN", font: roundedFont(20, .bold), color: Palette.blueInk, center: CGPoint(x: 670, y: 408))
            let title = roundedFont(64, .black)
            for (t, y) in [("Daily", 92.0), ("Affirmations", 158.0)] {
                drawOutlinedText(t, font: title, fill: .white, stroke: Palette.blueInk, strokePercent: 22, center: CGPoint(x: w / 2, y: y))
            }
            fillRounded(g, CGRect(x: w / 2 - 150, y: 196, width: 300, height: 40), 20, .white)
            drawText("Collect all 9 messages", font: roundedFont(22, .bold), color: Palette.blue, center: CGPoint(x: w / 2, y: 216))
            // three capsules with a rolled message peeking out
            for (cx, cy, col) in [(200.0, 340.0, UIColor(hex: 0x2F6FD0)), (384, 330, UIColor.white), (568, 340, UIColor(hex: 0x5C94E3))] {
                let c = CGPoint(x: cx, y: cy)
                g.setFillColor(UIColor(hex: 0x1C4A94).withAlphaComponent(0.18).cgColor)
                g.fillEllipse(in: CGRect(x: cx - 62, y: cy + 62, width: 124, height: 24))
                g.setStrokeColor(UIColor(hex: 0x1C4A94).withAlphaComponent(0.35).cgColor); g.setLineWidth(3)
                g.setFillColor(col.cgColor)
                g.addArc(center: CGPoint(x: cx, y: cy + 6), radius: 64, startAngle: 0, endAngle: .pi, clockwise: false)
                g.drawPath(using: .fillStroke)
                g.setFillColor(UIColor.white.withAlphaComponent(0.7).cgColor)
                g.addArc(center: c, radius: 64, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
                g.drawPath(using: .fillStroke)
                g.saveGState()
                g.translateBy(x: cx + 6, y: cy - 6); g.rotate(by: -0.5)
                fillRounded(g, CGRect(x: -14, y: -60, width: 28, height: 86), 10, UIColor(hex: 0xFFF6EA))
                g.setStrokeColor(UIColor(hex: 0x1C4A94).cgColor); g.setLineWidth(4)
                g.move(to: CGPoint(x: -14, y: -30)); g.addLine(to: CGPoint(x: 14, y: -30)); g.strokePath()
                g.restoreGState()
            }
            // the fine-print strip real cards carry along the bottom
            g.setFillColor(UIColor.white.cgColor); g.fill(CGRect(x: 0, y: h - 104, width: w, height: 104))
            g.setFillColor(Palette.yellow.cgColor); g.fill(CGRect(x: 24, y: h - 92, width: 120, height: 18))
            g.setFillColor(UIColor(hex: 0x282C34).withAlphaComponent(0.25).cgColor)
            for i in 0..<4 { g.fill(CGRect(x: 24, y: h - 64 + CGFloat(i) * 14, width: w * (0.5 + CGFloat(i % 3) * 0.12), height: 5)) }
            drawText("Gotcha", font: roundedFont(26, .black), color: Palette.blue, center: CGPoint(x: w - 24, y: h - 44), align: .right)
        }
    }

    /// The printed face of the mechanism unit: dial rings, coin badge, counter window, stickers and the exit mouth.
    private func faceImage(lw: Float, lh: Float, ly: Float) -> UIImage {
        let cw: CGFloat = 1024, ch = CGFloat((1024 * lh / lw).rounded())
        let toX = { (x: Float) -> CGFloat in CGFloat((x + lw / 2) / lw) * cw }
        let toY = { (y: Float) -> CGFloat in CGFloat((ly + lh / 2 - y) / lh) * ch }
        let px = { (u: Float) -> CGFloat in CGFloat(u / lw) * cw }
        let kY = knobY, eY = exitY, eW = exitW, eH = exitH, sX = slotX, sY = slotY
        let ringBlue = Palette.ringBlue
        return renderLabel(size: CGSize(width: cw, height: ch)) { g, _ in
            let kx = toX(0), ky = toY(kY)
            // yellow arc with a clockwise arrowhead, then the thick blue ring around the dial
            let rY = px(0.545), rB = px(0.465)
            let a0 = CGFloat.pi * 0.62, a1 = CGFloat.pi * 2.32
            g.setStrokeColor(Palette.yellow.cgColor); g.setLineWidth(px(0.05))
            g.addArc(center: CGPoint(x: kx, y: ky), radius: rY, startAngle: a0, endAngle: a1, clockwise: false); g.strokePath()
            arrowHead(g, kx + rY * cos(a1), ky + rY * sin(a1), a1 + .pi / 2, px(0.09), Palette.yellow)
            g.setStrokeColor(ringBlue.cgColor); g.setLineWidth(px(0.09))
            g.strokeEllipse(in: CGRect(x: kx - rB, y: ky - rB, width: rB * 2, height: rB * 2))
            let rW = rB - px(0.045)
            g.setFillColor(UIColor(hex: 0xD9D1BF).cgColor)
            g.fillEllipse(in: CGRect(x: kx - rW, y: ky - rW, width: rW * 2, height: rW * 2))
            g.setFillColor(ringBlue.cgColor)
            g.fill(CGRect(x: kx - rY - px(0.2), y: ky - px(0.03), width: px(0.12), height: px(0.06)))
            arrowHead(g, kx - rY - px(0.06), ky, 0, px(0.06), ringBlue)

            // COIN IN badge pointing at the slot
            let bx = toX(-0.44), by = toY(2.35), bw = px(0.9), bh = px(0.2)
            fillRounded(g, CGRect(x: bx, y: by, width: bw, height: bh), bh / 2, ringBlue)
            g.setStrokeColor(ringBlue.cgColor); g.setLineWidth(4); g.setFillColor(UIColor.white.cgColor)
            for i in 0..<3 {
                let cx = bx + px(0.13) + CGFloat(i) * px(0.065), r = px(0.07)
                g.addEllipse(in: CGRect(x: cx - r, y: by + bh / 2 - r, width: r * 2, height: r * 2)); g.drawPath(using: .fillStroke)
            }
            drawText("COIN IN", font: roundedFont(px(0.1), .black), color: .white, center: CGPoint(x: bx + px(0.34), y: by + bh / 2), align: .left)
            arrowHead(g, bx + bw + px(0.06), by + bh / 2, 0, px(0.06), ringBlue)
            let sr = px(0.17)
            g.setFillColor(UIColor(hex: 0xD9D4C8).cgColor)
            g.fillEllipse(in: CGRect(x: toX(sX) - sr, y: toY(sY) - sr, width: sr * 2, height: sr * 2))

            // coin badge and green counter window, top left
            fillRounded(g, CGRect(x: toX(-1.05), y: toY(2.36), width: px(0.26), height: px(0.26)), 8, ringBlue)
            let cr = px(0.08)
            g.setFillColor(UIColor.white.cgColor)
            g.fillEllipse(in: CGRect(x: toX(-0.92) - cr, y: toY(2.23) - cr, width: cr * 2, height: cr * 2))
            drawText("1", font: roundedFont(px(0.08), .black), color: ringBlue, center: CGPoint(x: toX(-0.92), y: toY(2.23)))
            fillRounded(g, CGRect(x: toX(-1.06), y: toY(1.98), width: px(0.4), height: px(0.16)), 6, UIColor(hex: 0x2B2F36))
            fillRounded(g, CGRect(x: toX(-1.04), y: toY(1.96), width: px(0.36), height: px(0.12)), 4, UIColor(hex: 0x46C774))
            drawText("1 TURN", font: roundedFont(px(0.075), .black), color: UIColor(hex: 0x0E3B1F), center: CGPoint(x: toX(-0.86), y: toY(1.9)))

            // instruction sticker (left)
            let sx = toX(-1.06), sy = toY(1.5), sw = px(0.34), sh = px(0.3)
            fillRounded(g, CGRect(x: sx, y: sy, width: sw, height: sh), 8, .white)
            g.setStrokeColor(ringBlue.cgColor); g.setLineWidth(3)
            g.addPath(UIBezierPath(roundedRect: CGRect(x: sx, y: sy, width: sw, height: sh), cornerRadius: 8).cgPath); g.strokePath()
            arrowHead(g, sx + 18, sy + 22, 0, 10, UIColor(hex: 0xD8352A))
            for (i, t) in ["Turn the", "handle slowly,", "one full turn."].enumerated() {
                drawText(t, font: roundedFont(px(0.045), .bold), color: UIColor(hex: 0x2B2F36),
                         center: CGPoint(x: sx + (i == 0 ? 32 : 10), y: sy + 22 + CGFloat(i) * px(0.065)), align: .left)
            }
            // notice sticker (right)
            let nx = toX(0.6), ny = toY(1.3), nw = px(0.46), nh = px(0.44)
            fillRounded(g, CGRect(x: nx, y: ny, width: nw, height: nh), 8, .white)
            g.setFillColor(Palette.yellow.cgColor); g.fill(CGRect(x: nx + 8, y: ny + 8, width: nw - 16, height: 18))
            g.setFillColor(UIColor(hex: 0x282C34).withAlphaComponent(0.28).cgColor)
            var lineY = ny + 38
            while lineY < ny + nh - 10 {
                let k = CGFloat(Int(lineY * 7) % 5) / 5
                g.fill(CGRect(x: nx + 12, y: lineY, width: (nw - 24) * (0.6 + 0.4 * k), height: 5))
                lineY += 13
            }
            // coin return pocket and the dark take-out mouth behind the flap
            fillRounded(g, CGRect(x: toX(0.62), y: toY(0.7), width: px(0.24), height: px(0.3)), 8, UIColor(hex: 0xD9D4C8))
            fillRounded(g, CGRect(x: toX(0.66), y: toY(0.64), width: px(0.16), height: px(0.2)), 6, UIColor(hex: 0xC6C0B2))
            let ex = toX(-eW / 2), ey = toY(eY + eH / 2), ew = px(eW), eh = px(eH)
            g.saveGState()
            g.addPath(UIBezierPath(roundedRect: CGRect(x: ex, y: ey, width: ew, height: eh), cornerRadius: px(0.06)).cgPath); g.clip()
            let colors = [UIColor(hex: 0x08090B).cgColor, UIColor(hex: 0x24272D).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                g.drawLinearGradient(grad, start: CGPoint(x: 0, y: ey), end: CGPoint(x: 0, y: ey + eh), options: [])
            }
            g.restoreGState()
        }
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
        let y0 = glassY0 + 0.02 + R, y1 = glassY1 - R - 0.04
        var best: SCNVector3?
        for _ in 0..<50 {
            let x = Float.random(in: -bx...bx), z = Float.random(in: -bz...bz)
            let y = settleY(x: x, z: z, y0: y0)
            if best == nil || y < best!.y { best = SCNVector3(x, y, z) }
        }
        guard let pos = best, pos.y <= y1 else { return false }
        let color = Palette.capsules.randomElement() ?? Palette.blue
        let c = makeCapsule(color: color, interactive: false)
        c.eulerAngles = SCNVector3(Float.random(in: 0...(2 * .pi)), Float.random(in: 0...(2 * .pi)), Float.random(in: 0...(2 * .pi)))
        baseY[ObjectIdentifier(c)] = pos.y
        capsuleColor[ObjectIdentifier(c)] = color
        stage.addChildNode(c)
        pile.append(c)
        if fromAbove {
            c.position = SCNVector3(pos.x, glassY1 + 0.6, pos.z)
            let drop = SCNAction.move(to: pos, duration: 0.45 * M)
            drop.timingMode = .easeIn
            c.runAction(drop)
        } else {
            c.position = pos
        }
        return true
    }
}
