import SwiftUI

/// The machine's turning knob, drawn flat. Used on the loading screen; the app icon is the same design.
struct KnobMark: View {
    var angle: Double

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 120
            ZStack {
                Circle().fill(Color.white)
                Circle().strokeBorder(Color(UIColor(hex: 0x2F6FD0)), lineWidth: 7 * s)
                Circle().fill(Color(UIColor(hex: 0xEEF2F8))).padding(20 * s)
                ZStack {
                    Capsule()
                        .fill(Color.white)
                        .overlay(Capsule().strokeBorder(Color(UIColor(hex: 0xC6D3E5)), lineWidth: 2 * s))
                        .frame(width: 88 * s, height: 22 * s)
                    Path { p in
                        p.move(to: CGPoint(x: 95 * s, y: 60 * s))
                        p.addLine(to: CGPoint(x: 88 * s, y: 54 * s))
                        p.addLine(to: CGPoint(x: 88 * s, y: 66 * s))
                        p.closeSubpath()
                    }
                    .fill(Color(UIColor(hex: 0x2F6FD0)))
                    .frame(width: 120 * s, height: 120 * s)
                    Circle().fill(Color(UIColor(hex: 0x2F6FD0))).frame(width: 20 * s, height: 20 * s)
                    Circle().fill(Color.white.opacity(0.55)).frame(width: 6 * s, height: 6 * s).offset(x: -3 * s, y: -3 * s)
                }
                .rotationEffect(.degrees(angle))
            }
            .frame(width: 120 * s, height: 120 * s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

/// Launch screen: the knob makes quarter turns, like someone cranking the handle, before the machine appears.
struct LoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            RadialGradient(colors: [.gBg, .gBg, .gBgDeep], center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 700)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                KnobMark(angle: angle)
                    .frame(width: 132, height: 132)
                    .shadow(color: Color(UIColor(hex: 0x18223A)).opacity(0.22), radius: 14, y: 12)
                VStack(spacing: 4) {
                    Text("Gotcha").font(.rounded(26, .black))
                    Text("ガチャガチャ").font(.rounded(12, .medium)).tracking(1.6).foregroundStyle(Color.gInkSoft)
                }
            }
            .foregroundStyle(Color.gInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Gotcha")
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { angle += 90 }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }
}
