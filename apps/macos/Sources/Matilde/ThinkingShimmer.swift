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
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color(Paper.ink), location: 0.35),
                            .init(color: Color(Paper.ink), location: 0.65),
                            .init(color: .clear, location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.85)
                            .offset(x: sweeping ? geometry.size.width : -geometry.size.width * 0.85)
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
