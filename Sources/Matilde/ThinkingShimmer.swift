import SwiftUI

/// A moving highlight confined to the letters, without changing text layout.
struct ThinkingShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        Text("Thinking…")
            .font(.body)
            .foregroundStyle(Color(Paper.muted))
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, Color(Paper.ink).opacity(0.85), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.6)
                            .offset(x: sweeping ? geometry.size.width : -geometry.size.width * 0.6)
                    }
                    .mask(Text("Thinking…").font(.body))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear {
                        sweeping = false
                        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                            sweeping = true
                        }
                    }
                }
            }
            .fixedSize()
    }
}
