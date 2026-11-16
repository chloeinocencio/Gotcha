import SwiftUI

@main
struct GotchaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Shows the knob-turning loading screen while the 3D machine builds behind it.
struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loading = true

    var body: some View {
        ZStack {
            ContentView()
            if loading {
                LoadingView().transition(.opacity)
            }
        }
        .task {
            // One full turn of the knob (four quarter turns), or a short beat with Reduce Motion on.
            try? await Task.sleep(nanoseconds: reduceMotion ? 500_000_000 : 2_400_000_000)
            withAnimation(.easeOut(duration: 0.45)) { loading = false }
        }
    }
}
