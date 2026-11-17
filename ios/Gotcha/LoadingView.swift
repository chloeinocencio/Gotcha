import SwiftUI

/// The machine's turning knob, drawn flat: a white dial with a paddle, in a blue ring with a yellow arrow.
/// Used on the loading screen; the app icon is the same design.
struct KnobMark: View {
    var angle: Double

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 120
            ZStack {
                Circle().fill(Color(UIColor(hex: 0xF3EFE5))).frame(width: 112 * s, height: 112 * s)
                // yellow arc (clockwise, like the handle) with its arrowhead
                Circle()
                    .trim(from: 0, to: 0.85)
                    .stroke(Color(UIColor(hex: 0xF2C230)), lineWidth: 5 * s)
                    .rotationEffect(.degrees(111.6))
                    .frame(width: 100 * s, height: 100 * s)
                Path { p in
                    p.move(to: CGPoint(x: 80.3 * s, y: 106.6 * s))
                    p.addLine(to: CGPoint(x: 94.3 * s, y: 105.5 * s))
                    p.addLine(to: CGPoint(x: 87.0 * s, y: 94.1 * s))
                    p.closeSubpath()
                }
                .fill(Color(UIColor(hex: 0xF2C230)))
                .frame(width: 120 * s, height: 120 * s)
                Circle().stroke(Color(UIColor(hex: 0x2A4FA8)), lineWidth: 9 * s).frame(width: 86 * s, height: 86 * s)
                Circle().fill(Color(UIColor(hex: 0xD9D1BF))).frame(width: 77 * s, height: 77 * s)
                ZStack {
                    Circle().fill(Color(UIColor(hex: 0xFAF8F2)))
                        .overlay(Circle().stroke(Color(UIColor(hex: 0xDCD4C3)), lineWidth: 2 * s))
                        .frame(width: 68 * s, height: 68 * s)
                    Capsule().fill(Color(UIColor(hex: 0xCFC6B3)).opacity(0.6))
                        .frame(width: 66 * s, height: 16 * s).offset(y: 3 * s)
                    Capsule().fill(Color.white)
                        .overlay(Capsule().stroke(Color(UIColor(hex: 0xD4CCBB)), lineWidth: 1.5 * s))
                        .frame(width: 66 * s, height: 16 * s)
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
                    Text("daily affirmations").font(.rounded(12, .medium)).tracking(1.2).foregroundStyle(Color.gInkSoft)
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
