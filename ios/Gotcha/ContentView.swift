import SwiftUI

extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static let gBg = dynamic(light: 0xEFDDE3, dark: 0x1E171B)
    static let gBgDeep = dynamic(light: 0xD9BFC9, dark: 0x120D10)
    static let gInk = dynamic(light: 0x2B2228, dark: 0xF4ECEF)
    static let gInkSoft = dynamic(light: 0x77656F, dark: 0xB9A8B1)
    static let gAction = dynamic(light: 0xA8445E, dark: 0xF6BCCB)
    static let gActionText = dynamic(light: 0xFFFFFF, dark: 0x2B2228)
    static let gPaper = Color(UIColor(hex: 0xFFFDF9))
    static let gPaperInk = Color(UIColor(hex: 0x2B2228))
    static let gPaperSoft = Color(UIColor(hex: 0x8B7882))
    static let gStamp = Color(UIColor(hex: 0xA8445E))
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

struct ContentView: View {
    @StateObject private var gacha = GachaController()

    var body: some View {
        ZStack {
            RadialGradient(colors: [.gBg, .gBg, .gBgDeep], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 700)
                .ignoresSafeArea()

            GachaView(controller: gacha)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                actionButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .opacity(gacha.slip == nil ? 1 : 0.25)
            .allowsHitTesting(gacha.slip == nil)

            if let slip = gacha.slip {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { gacha.close(turnAgain: false) }
                    .transition(.opacity)
                VStack {
                    Spacer()
                    SlipView(message: slip, total: gacha.total,
                             onClose: { gacha.close(turnAgain: false) },
                             onAgain: { gacha.close(turnAgain: true) })
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .foregroundStyle(Color.gInk)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gotcha").font(.rounded(26, .black))
                Text("ガチャガチャ · daily affirmations")
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Color.gInkSoft)
            }
            Spacer()
            Group {
                if gacha.remaining > 0 {
                    (Text("\(gacha.remaining)").bold() + Text(" of \(gacha.total) left"))
                } else {
                    Text("New round next turn")
                }
            }
            .font(.rounded(13, .medium))
            .monospacedDigit()
            .foregroundStyle(Color.gInkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var actionButton: some View {
        Button { gacha.primaryAction() } label: {
            HStack(spacing: 6) {
                Text(gacha.actionTitle).font(.rounded(17, .bold))
                if !gacha.actionJapanese.isEmpty {
                    Text(gacha.actionJapanese).font(.rounded(14, .medium)).opacity(0.8)
                }
            }
            .foregroundStyle(Color.gActionText)
            .frame(maxWidth: 340)
            .padding(.vertical, 16)
            .background(Color.gAction, in: Capsule())
            .shadow(color: Color.gAction.opacity(0.4), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!gacha.actionEnabled)
        .opacity(gacha.actionEnabled ? 1 : 0.55)
        .animation(.easeOut(duration: 0.2), value: gacha.actionEnabled)
    }
}

struct SlipView: View {
    let message: DrawnMessage
    let total: Int
    let onClose: () -> Void
    let onAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("NO. \(message.number) / \(total)")
                    .font(.rounded(12, .medium))
                    .tracking(1.4)
                    .monospacedDigit()
                    .foregroundStyle(Color.gPaperSoft)
                Spacer()
                Text("今日のことば")
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Color.gStamp)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gStamp, lineWidth: 1.5))
                    .rotationEffect(.degrees(-4))
            }
            Text(message.text)
                .font(.rounded(22, .bold))
                .lineSpacing(6)
                .foregroundStyle(Color.gPaperInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(action: onClose) {
                    Text("Close").font(.rounded(15, .bold))
                        .foregroundStyle(Color.gStamp)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .overlay(Capsule().stroke(Color.gStamp, lineWidth: 1.5))
                }
                Button(action: onAgain) {
                    Text("Turn again").font(.rounded(15, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Color.gStamp, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .frame(maxWidth: 400)
        .background(
            ZStack {
                Color.gPaper
                // ruled lines like a fortune slip
                Canvas { ctx, size in
                    var y: CGFloat = 31
                    while y < size.height {
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                 with: .color(Color(UIColor(hex: 0xE9879F)).opacity(0.16)))
                        y += 32
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 20)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
