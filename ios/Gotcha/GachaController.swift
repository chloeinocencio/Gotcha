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
    private let homeTarget = SCNVector3(0, 2.3, 0.9)
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
        buildNeighbors()
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
        stage.eulerAngles.y = max(-0.42, min(0.42, panStartYaw + Float(dx) * 0.006))
    }

    func close(turnAgain: Bool) {
        Task { await closeSlip(turnAgain: turnAgain) }
    }

    func layout(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = Float(size.width / size.height)
        let tanH = tan(Float(17.5 * .pi / 180))
        let dist = max(3.35 / tanH, 1.7 / (tanH * aspect))
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

    // The scene recreates a capsule-toy corner: a tiled floor, a painted wall, and a row of three machines.
    // Every printed texture is baked from web/textures.js by tools/bake-textures.py (Textures/tex-*.png).
    private let machineNode = SCNNode()
    private let floorMat = SCNMaterial()
    private let wallMat = SCNMaterial()
    private let ambientLight = SCNLight()
    private let sunLight = SCNLight()
    private let fillLight = SCNLight()
    private let spotLight = SCNLight()
    private let neighborGrip = Mat.pbr(.white, roughness: 0.3, clearCoat: 0.8)
    private var wallZ: Float { -D / 2 - 0.08 }
    private var pitch: Float { W + 0.08 }

    private func tex(_ name: String) -> UIImage? { UIImage(named: "tex-\(name)") }

    private func repeatTexture(_ p: SCNMaterialProperty, _ sx: Float, _ sy: Float) {
        p.wrapS = .repeat
        p.wrapT = .repeat
        p.contentsTransform = SCNMatrix4MakeScale(sx, sy, 1)
    }

    private func buildWorld() {
        let cam = SCNCamera()
        cam.fieldOfView = 35
        cam.zNear = 0.1
        cam.zFar = 100
        cam.wantsHDR = true
        cam.exposureOffset = 0
        // contact shading in the crevices, a lens vignette and a touch of grain, so it reads as a photo
        cam.screenSpaceAmbientOcclusionIntensity = 0.9
        cam.screenSpaceAmbientOcclusionRadius = 0.35
        cam.screenSpaceAmbientOcclusionBias = 0.03
        cam.screenSpaceAmbientOcclusionDepthThreshold = 0.2
        cam.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        cam.vignettingPower = 0.6
        cam.vignettingIntensity = 0.45
        cam.grainIntensity = 0.035
        cam.grainScale = 1
        cam.grainIsColored = false
        cameraNode.camera = cam
        cameraNode.position = homeCamPos
        lookTarget.position = homeTarget
        scene.rootNode.addChildNode(lookTarget)
        let look = SCNLookAtConstraint(target: lookTarget)
        look.isGimbalLockEnabled = true
        cameraNode.constraints = [look]
        scene.rootNode.addChildNode(cameraNode)

        // shop-light reflections: rows of ceiling fluorescents and a softbox behind the viewer
        scene.lightingEnvironment.contents = tex("env") ?? environmentImage()
        scene.lightingEnvironment.intensity = 0.9
        scene.background.contents = UIColor(hex: 0xE9E6E0)

        ambientLight.type = .ambient
        ambientLight.intensity = 110
        ambientLight.color = UIColor(hex: 0xF3F0EA)
        let ambientNode = SCNNode(); ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        sunLight.type = .directional
        sunLight.intensity = 950
        sunLight.color = UIColor(hex: 0xFFFAF0)
        sunLight.castsShadow = true
        sunLight.shadowMode = .deferred
        sunLight.shadowColor = UIColor.black.withAlphaComponent(0.35)
        sunLight.shadowSampleCount = 16
        sunLight.shadowRadius = 8
        sunLight.automaticallyAdjustsShadowProjection = true
        sunLight.shadowMapSize = CGSize(width: 2048, height: 2048)
        let sunNode = SCNNode(); sunNode.light = sunLight
        sunNode.position = SCNVector3(3.4, 10, 4.6)
        sunNode.look(at: SCNVector3(0, 1.5, 0))
        scene.rootNode.addChildNode(sunNode)

        fillLight.type = .directional
        fillLight.intensity = 220
        fillLight.color = UIColor(hex: 0xDFE8FF)
        let fillNode = SCNNode(); fillNode.light = fillLight
        fillNode.position = SCNVector3(-5, 3, 4)
        fillNode.look(at: SCNVector3(0, 1.5, 0))
        scene.rootNode.addChildNode(fillNode)

        // a soft spot on the hero machine, so it reads brighter than its neighbours
        spotLight.type = .spot
        spotLight.intensity = 700
        spotLight.color = UIColor(hex: 0xFFF8EE)
        spotLight.spotInnerAngle = 16
        spotLight.spotOuterAngle = 40
        let spotNode = SCNNode(); spotNode.light = spotLight
        spotNode.position = SCNVector3(0, 9, 7)
        spotNode.look(at: SCNVector3(0, 2.2, 0))
        scene.rootNode.addChildNode(spotNode)

        scene.rootNode.addChildNode(stage)
        buildRoom()
    }

    /// Light or dark: the dark look is the shop after hours, with the hero machine under its own light.
    func applyTheme(dark: Bool) {
        floorMat.multiply.contents = dark ? UIColor(hex: 0x4C5059) : UIColor(hex: 0xE8E8E8)
        wallMat.multiply.contents = dark ? UIColor(hex: 0x3A3F4A) : UIColor(hex: 0xF2F0EC)
        ambientLight.intensity = dark ? 45 : 110
        sunLight.intensity = dark ? 480 : 950
        fillLight.intensity = dark ? 100 : 220
        spotLight.intensity = dark ? 1400 : 700
        scene.lightingEnvironment.intensity = dark ? 0.45 : 0.9
        scene.background.contents = dark ? UIColor(hex: 0x1A1D24) : UIColor(hex: 0xE9E6E0)
    }

    private func environmentImage() -> UIImage {
        renderLabel(size: CGSize(width: 512, height: 256)) { g, size in
            let colors = [UIColor(hex: 0xBDBCB8).cgColor, UIColor(hex: 0x86857F).cgColor, UIColor(hex: 0x3C3B39).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            g.setFillColor(UIColor.white.cgColor)
            for i in 0..<6 { g.fill(CGRect(x: CGFloat(i) * 85, y: 14, width: 55, height: 6)) }
            g.fill(CGRect(x: 215, y: 75, width: 85, height: 55))
        }
    }

    private func buildRoom() {
        floorMat.lightingModel = .physicallyBased
        floorMat.diffuse.contents = tex("floor") ?? UIColor(hex: 0xD9DADC)
        repeatTexture(floorMat.diffuse, 6, 6)
        floorMat.roughness.contents = 0.42
        floorMat.metalness.contents = 0.0
        let floorGeo = SCNPlane(width: 36, height: 36)
        floorGeo.materials = [floorMat]
        let floor = SCNNode(geometry: floorGeo)
        floor.eulerAngles.x = -.pi / 2
        floor.position = SCNVector3(0, 0, 8)
        floor.castsShadow = false
        stage.addChildNode(floor)

        wallMat.lightingModel = .physicallyBased
        wallMat.diffuse.contents = tex("wall") ?? UIColor(hex: 0xEFECE6)
        repeatTexture(wallMat.diffuse, 5, 2)
        wallMat.roughness.contents = 0.9
        wallMat.metalness.contents = 0.0
        let wallGeo = SCNPlane(width: 36, height: 14)
        wallGeo.materials = [wallMat]
        let wall = SCNNode(geometry: wallGeo)
        wall.position = SCNVector3(0, 7, wallZ)
        wall.castsShadow = false
        stage.addChildNode(wall)

        _ = add(SCNBox(width: 36, height: 0.16, length: 0.04, chamferRadius: 0), Mat.pbr(UIColor(hex: 0xCFCAC0), roughness: 0.6),
                at: SCNVector3(0, 0.08, wallZ + 0.02), shadow: false)

        // dark crevices where the machines stand shoulder to shoulder
        let totalH = bodyH + glassH + capH
        let crevice = Mat.pbr(UIColor(hex: 0x24221F), roughness: 1)
        for sx: Float in [-1, 1] {
            for k: Float in [0.5, 1.5] {
                _ = add(SCNBox(width: CGFloat(pitch - W + 0.02), height: CGFloat(totalH), length: CGFloat(D - 0.1), chamferRadius: 0), crevice,
                        at: SCNVector3(sx * pitch * k, totalH / 2 + 0.05, 0), shadow: false)
            }
        }
        // soft contact shadows under each machine and on the wall behind it
        for x: Float in [-pitch, 0, pitch] {
            let f = add(SCNPlane(width: CGFloat(W + 0.7), height: CGFloat(D + 0.7)), contactShadowMaterial(0.55), at: SCNVector3(x, 0.004, 0), shadow: false)
            f.eulerAngles.x = -.pi / 2
            _ = add(SCNPlane(width: CGFloat(W + 0.9), height: CGFloat(bodyH + glassH + 0.9)), contactShadowMaterial(0.35),
                    at: SCNVector3(x, (bodyH + glassH) / 2 + 0.1, wallZ + 0.004), shadow: false)
        }
    }

    private func contactShadowMaterial(_ opacity: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.transparent.contents = tex("ao")
        m.transparencyMode = .aOne
        m.transparency = opacity
        m.writesToDepthBuffer = false
        return m
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

    /// Moulded plastic with a fine surface grain in its roughness, so highlights break up like the real thing.
    private func plastic(_ color: UIColor, clearCoat: CGFloat = 0.3) -> SCNMaterial {
        let m = Mat.pbr(color, roughness: 0.42, clearCoat: clearCoat)
        if let grain = tex("grain") {
            m.roughness.contents = grain
            repeatTexture(m.roughness, 2, 2)
        }
        m.clearCoatRoughness.contents = 0.3
        return m
    }

    private func path(_ rect: CGRect, radius: CGFloat) -> UIBezierPath {
        let p = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        p.flatness = 0.002 // scene units are small; the default flatness would facet the curves
        return p
    }

    // Modelled on the classic capsule-toy machine: a clear display case on top with a printed card inside,
    // and a cream mechanism unit below with a big white dial in a raised blue ring, a coin mechanism,
    // a key lock and a smoked exit flap.
    private func buildMachine() {
        let shell = plastic(Palette.shell)
        let trim = plastic(Palette.trim, clearCoat: 0.15)
        let ringMat = plastic(UIColor(hex: 0x1D42A8), clearCoat: 0.35)
        let dialMat = plastic(UIColor(hex: 0xFBF9F3), clearCoat: 0.7)
        dialMat.isDoubleSided = true
        let chrome = Mat.pbr(UIColor(hex: 0xD4D7DC), roughness: 0.28)
        chrome.metalness.contents = 1.0
        let satin = Mat.pbr(UIColor(hex: 0xA9ADB4), roughness: 0.45)
        satin.metalness.contents = 0.9
        let dark = Mat.pbr(UIColor(hex: 0x15171B), roughness: 0.55)
        // Clear plastic: a faint body plus an additive layer that only carries reflections, so the case glints
        // without fogging the capsules behind it.
        let glassMat = Mat.clear(.white, opacity: 0.05)
        let glint = SCNMaterial()
        glint.lightingModel = .physicallyBased
        glint.diffuse.contents = UIColor.black
        glint.roughness.contents = 0.04
        glint.metalness.contents = 0.0
        glint.blendMode = .add
        glint.writesToDepthBuffer = false
        let clipMat = Mat.clear(UIColor(hex: 0xEEF4FF), opacity: 0.45)
        let cg = { (v: Float) in CGFloat(v) }
        let m = machineNode
        stage.addChildNode(m)

        // mechanism unit, raised face plate, base and the seam band under the display case
        _ = add(SCNBox(width: cg(W), height: cg(bodyH), length: cg(D), chamferRadius: 0.16), shell, at: SCNVector3(0, bodyH / 2, 0), to: m)
        _ = add(SCNBox(width: cg(W - 0.14), height: cg(bodyH - 0.18), length: 0.1, chamferRadius: 0.05), shell,
                at: SCNVector3(0, bodyH / 2 + 0.02, front + 0.01), to: m)
        _ = add(SCNBox(width: cg(W + 0.06), height: 0.1, length: cg(D + 0.06), chamferRadius: 0.04), trim, at: SCNVector3(0, 0.05, 0), to: m)
        _ = add(SCNBox(width: cg(W + 0.04), height: 0.12, length: cg(D + 0.04), chamferRadius: 0.05), trim, at: SCNVector3(0, bodyH + 0.04, 0), to: m)
        for sx: Float in [-1, 1] { // moulded groove where the two shells meet
            _ = add(SCNBox(width: 0.012, height: cg(bodyH - 0.4), length: cg(D - 0.3), chamferRadius: 0), dark,
                    at: SCNVector3(sx * (W / 2 + 0.001), bodyH / 2, 0), shadow: false, to: m)
        }

        // display case
        let caseY = glassY0 + glassH / 2
        let glass = add(SCNBox(width: cg(W - 0.04), height: cg(glassH), length: cg(D - 0.04), chamferRadius: 0.16), glassMat,
                        at: SCNVector3(0, caseY, 0), shadow: false, to: m)
        glass.renderingOrder = 10
        let glintNode = add(SCNBox(width: cg(W - 0.04), height: cg(glassH), length: cg(D - 0.04), chamferRadius: 0.16), glint,
                            at: SCNVector3(0, caseY, 0), shadow: false, to: m)
        glintNode.renderingOrder = 11
        for sx: Float in [-1, 1] {
            _ = add(SCNBox(width: 0.12, height: cg(glassH), length: 0.12, chamferRadius: 0.04), shell,
                    at: SCNVector3(sx * (W / 2 - 0.08), caseY, -(D / 2 - 0.08)), to: m)
        }
        _ = add(SCNBox(width: cg(W - 0.12), height: 0.02, length: cg(D - 0.12), chamferRadius: 0), trim,
                at: SCNVector3(0, glassY0 + 0.01, 0), shadow: false, to: m)
        _ = add(SCNBox(width: cg(W + 0.04), height: cg(capH), length: cg(D + 0.04), chamferRadius: 0.13), shell,
                at: SCNVector3(0, glassY1 + capH / 2, 0), to: m)
        _ = add(SCNBox(width: cg(W + 0.05), height: 0.014, length: cg(D + 0.05), chamferRadius: 0), dark,
                at: SCNVector3(0, glassY1 + 0.07, 0), shadow: false, to: m) // lid seam

        // printed parts
        if let img = tex("badge") {
            _ = add(SCNPlane(width: 0.9, height: 0.2), Mat.label(img), at: SCNVector3(0, glassY1 + capH / 2, front + 0.025), shadow: false, to: m)
        }
        let cardW: Float = 1.7, cardH: Float = 1.3
        let card = add(SCNPlane(width: cg(cardW), height: cg(cardH)), Mat.label(tex("card-hero") ?? UIImage()),
                       at: SCNVector3(0, glassY0 + 0.08 + cardH / 2, front - 0.08), to: m)
        card.name = "card"
        for sx: Float in [-1, 1] { // clear clips holding the card up
            let clip = add(SCNBox(width: 0.1, height: 0.16, length: 0.05, chamferRadius: 0.01), clipMat,
                           at: SCNVector3(sx * (cardW / 2 - 0.06), glassY0 + 0.08 + cardH - 0.04, front - 0.08), shadow: false, to: m)
            clip.renderingOrder = 9
        }
        let lw = W - 0.18, lh = bodyH - 0.22, ly = bodyH / 2 + 0.02
        if let img = tex("face") {
            _ = add(SCNPlane(width: cg(lw), height: cg(lh)), Mat.label(img), at: SCNVector3(0, ly, face + 0.002), shadow: false, to: m)
        }

        // screws in the face plate
        for (x, y) in [(-(W / 2 - 0.15), bodyH - 0.14), (W / 2 - 0.15, bodyH - 0.14), (-(W / 2 - 0.15), Float(0.26)), (W / 2 - 0.15, Float(0.26))] {
            let head = add(SCNCylinder(radius: 0.035, height: 0.016), chrome, at: SCNVector3(x, y, face + 0.008), shadow: false, to: m)
            head.eulerAngles.x = .pi / 2
            for a: Float in [0.4, 0.4 + .pi / 2] {
                let slot = add(SCNBox(width: 0.046, height: 0.008, length: 0.006, chamferRadius: 0), dark,
                               at: SCNVector3(x, y, face + 0.0165), shadow: false, to: m)
                slot.eulerAngles.z = a
            }
        }
        // raised blue ring around the dial
        let ring = add(SCNTorus(ringRadius: 0.465, pipeRadius: 0.045), ringMat, at: SCNVector3(0, knobY, face + 0.01), to: m)
        ring.scale = SCNVector3(1, 0.6, 1)
        ring.eulerAngles.x = .pi / 2

        // coin mechanism: satin plate, chrome slot boss, return lever
        _ = add(SCNBox(width: 0.34, height: 0.3, length: 0.03, chamferRadius: 0.014), satin, at: SCNVector3(slotX, slotY, face + 0.015), to: m)
        let boss = add(SCNCone(topRadius: 0.105, bottomRadius: 0.115, height: 0.05), chrome, at: SCNVector3(slotX, slotY, face + 0.045), to: m)
        boss.eulerAngles.x = .pi / 2
        _ = add(SCNBox(width: 0.032, height: 0.16, length: 0.03, chamferRadius: 0.012), dark, at: SCNVector3(slotX, slotY, face + 0.062), shadow: false, to: m)
        let lever = add(SCNBox(width: 0.05, height: 0.1, length: 0.04, chamferRadius: 0.018), chrome,
                        at: SCNVector3(slotX + 0.13, slotY - 0.07, face + 0.04), to: m)
        lever.eulerAngles.z = -0.3

        // key lock beside the dial
        let lock = add(SCNCone(topRadius: 0.075, bottomRadius: 0.08, height: 0.05), chrome, at: SCNVector3(returnX, knobY, face + 0.025), to: m)
        lock.eulerAngles.x = .pi / 2
        let lockFace = add(SCNCylinder(radius: 0.056, height: 0.01), satin, at: SCNVector3(returnX, knobY, face + 0.052), shadow: false, to: m)
        lockFace.eulerAngles.x = .pi / 2
        let key = add(SCNBox(width: 0.016, height: 0.07, length: 0.01, chamferRadius: 0), dark, at: SCNVector3(returnX, knobY, face + 0.056), shadow: false, to: m)
        key.eulerAngles.z = 0.15

        // exit bezel, take-out lip and hinge pins
        let bezelPath = path(CGRect(x: -cg(exitW + 0.14) / 2, y: -cg(exitH + 0.14) / 2, width: cg(exitW + 0.14), height: cg(exitH + 0.14)), radius: 0.1)
        bezelPath.append(path(CGRect(x: -cg(exitW) / 2, y: -cg(exitH) / 2, width: cg(exitW), height: cg(exitH)), radius: 0.06))
        bezelPath.usesEvenOddFillRule = true
        let bezel = SCNShape(path: bezelPath, extrusionDepth: 0.07)
        bezel.chamferRadius = 0.02
        _ = add(bezel, shell, at: SCNVector3(0, exitY, face + 0.025), to: m)
        _ = add(SCNBox(width: cg(exitW + 0.14), height: 0.06, length: 0.16, chamferRadius: 0.025), shell,
                at: SCNVector3(0, exitY - exitH / 2 - 0.1, face + 0.06), to: m)
        for sx: Float in [-1, 1] {
            let pin = add(SCNCylinder(radius: 0.018, height: 0.05), chrome,
                          at: SCNVector3(sx * (exitW / 2 - 0.01), exitY + exitH / 2 - 0.02, face + 0.05), shadow: false, to: m)
            pin.eulerAngles.z = .pi / 2
        }

        // smoked flap with the brand moulded into it (swings on the hero machine)
        flapPivot.position = SCNVector3(0, exitY + exitH / 2 - 0.02, face + 0.07)
        stage.addChildNode(flapPivot)
        let flapMat = Mat.pbr(UIColor(hex: 0x0F1115), roughness: 0.2, clearCoat: 0.6)
        flapMat.transparency = 0.9
        flapMat.blendMode = .alpha
        flapMat.isDoubleSided = true
        flapMat.writesToDepthBuffer = false
        let fw = cg(exitW - 0.04), fh = cg(exitH - 0.04)
        let flap = add(SCNPlane(width: fw, height: fh), flapMat, at: SCNVector3(0, -(exitH - 0.04) / 2, 0), shadow: false, to: flapPivot)
        flap.renderingOrder = 11
        if let img = tex("flap") {
            let mould = Mat.label(img)
            mould.writesToDepthBuffer = false
            let n = add(SCNPlane(width: fw, height: fh), mould, at: SCNVector3(0, -(exitH - 0.04) / 2, 0.003), shadow: false, to: flapPivot)
            n.renderingOrder = 12
        }

        // Knob: a moulded white dial (lathe profile: a stepped rim rising to a shallow dome) with a raised paddle
        knob.position = SCNVector3(0, knobY, face)
        knob.name = "knob"
        stage.addChildNode(knob)
        let profile: [(Float, Float)] = [(0.425, 0), (0.425, 0.04), (0.415, 0.062), (0.395, 0.072), (0.37, 0.078),
                                         (0.3, 0.098), (0.2, 0.112), (0.1, 0.12), (0, 0.122)]
        let dial = add(Geo.lathe(profile), dialMat, at: SCNVector3(0, 0, 0), to: knob)
        dial.eulerAngles.x = .pi / 2
        let paddle = SCNShape(path: path(CGRect(x: -0.35, y: -0.065, width: 0.7, height: 0.13), radius: 0.065), extrusionDepth: 0.21)
        paddle.chamferRadius = 0.035
        gripMaterial.emission.contents = Palette.blue
        gripMaterial.emission.intensity = 0
        _ = add(paddle, gripMaterial, at: SCNVector3(0, 0, 0.16), to: knob)
        knob.enumerateHierarchy { n, _ in n.name = n.name ?? "knob" }
    }

    /// The other machines in the row: copies of the hero with their own card, a static dial and a pile of capsules.
    private func buildNeighbors() {
        let rows: [(Float, String, [UInt32])] = [
            (-1, "snack", [0xF59BB8, 0xF7C66A, 0x9BE29B, 0xFFFFFF]),
            (1, "cloud", [0xB8AFF0, 0xA8DCD1, 0xFFFFFF, 0x8FA8F0])
        ]
        for (side, variant, tints) in rows {
            let n = SCNNode()
            n.position = SCNVector3(side * pitch, 0, 0)
            let body = machineNode.clone()
            if let cardNode = body.childNode(withName: "card", recursively: true),
               let g = cardNode.geometry?.copy() as? SCNGeometry {
                g.materials = [Mat.label(tex("card-\(variant)") ?? UIImage())]
                cardNode.geometry = g
            }
            n.addChildNode(body)
            let k = knob.clone()
            k.eulerAngles.z = side * 0.6
            k.enumerateHierarchy { node, _ in
                node.name = "deco" // not tappable
                if let g = node.geometry, g.firstMaterial === self.gripMaterial, let gc = g.copy() as? SCNGeometry {
                    gc.materials = [self.neighborGrip]
                    node.geometry = gc
                }
            }
            n.addChildNode(k)
            n.addChildNode(flapPivot.clone())
            for (i, c) in pile.prefix(20).enumerated() {
                let cap = makeCapsule(color: UIColor(hex: tints[i % tints.count]), interactive: false)
                cap.position = SCNVector3(c.position.x, baseY[ObjectIdentifier(c)] ?? c.position.y, c.position.z)
                cap.eulerAngles = SCNVector3(c.eulerAngles.x, c.eulerAngles.y + side, c.eulerAngles.z)
                n.addChildNode(cap)
            }
            stage.addChildNode(n)
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
