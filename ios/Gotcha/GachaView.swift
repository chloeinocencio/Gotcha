import SceneKit
import SwiftUI

final class StageView: SCNView {
    var onLayout: ((CGSize) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

/// Hosts the SceneKit stage; taps hit the knob or the capsule, horizontal drags turn the machine.
@MainActor
struct GachaView: UIViewRepresentable {
    let controller: GachaController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> StageView {
        let view = StageView(frame: .zero)
        view.scene = controller.scene
        view.pointOfView = controller.cameraNode
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.isPlaying = true
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        let controller = self.controller
        view.onLayout = { size in
            Task { @MainActor in controller.layout(size: size) }
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "A white Japanese gachapon machine full of pink capsules"
        return view
    }

    func updateUIView(_ uiView: StageView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let controller: GachaController
        init(controller: GachaController) { self.controller = controller }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            let hits = view.hitTest(g.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {
                    if n.name == "knob" || n.name == "capsule" {
                        controller.tapped(kind: n.name ?? "")
                        return
                    }
                    node = n.parent
                }
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began: controller.panBegan()
            case .changed: controller.panChanged(dx: g.translation(in: g.view).x)
            default: break
            }
        }
    }
}
