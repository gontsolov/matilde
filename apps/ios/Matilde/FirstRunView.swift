import SwiftUI
import UIKit
import MatildeKit

/// The launch splash: the launch screen's colour and logo (Assets: LaunchBackground, LaunchLogo),
/// held for a moment and faded out so the app doesn't pop in.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            Image("LaunchLogo")
                .accessibilityHidden(true)
        }
    }
}

/// The first-run tour (`FirstRunTour` in MatildeKit), shown once: a welcome, three pages that
/// show what Matilde does, and a finish page. Settings → Show Welcome Again plays it again.
struct FirstRunView: View {
    /// Called when the tour ends; `true` when the user chose to turn on sync.
    let finish: (_ setUpSync: Bool) -> Void
    @State private var tour = FirstRunTour()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if tour.screen == .welcome {
                WelcomeScreen { tour.next() }
                    .transition(.opacity)
            } else {
                carousel
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.1), value: tour.screen == .welcome)
        .sensoryFeedback(.selection, trigger: tour.carouselIndex)
    }

    private var carousel: some View {
        let index = Binding(get: { tour.carouselIndex ?? 0 }, set: { tour.show(carouselIndex: $0) })
        return ZStack(alignment: .bottom) {
            Paper.background.ignoresSafeArea()
            TabView(selection: index) {
                TourPage(title: "A quiet page", text: "Give each note a goal, then just write. Markdown stays plain text, and every word is yours.") {
                    EditorVignette()
                }
                .tag(0)
                TourPage(title: "Ask Matilde", text: "Highlight a passage and ask. Matilde answers in the margin: questions and notes, never a rewrite unless you accept it.") {
                    CommentVignette()
                }
                .tag(1)
                TourPage(title: "Yours, on every device", text: "Your notes sync between your Mac and iPhone, encrypted before they leave. Nobody else can read them.") {
                    SyncVignette()
                }
                .tag(2)
                FinishPage(finish: finish)
                    .tag(FirstRunTour.pageCount)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            VStack(spacing: 18) {
                PageDots(count: FirstRunTour.pageCount + 1, current: tour.carouselIndex ?? 0)
                if tour.screen != .finish {
                    Button("Next") { withAnimation { tour.next() } }
                        .buttonStyle(.matildePrimary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .topTrailing) {
            if tour.screen != .finish {
                Button("Skip") { finish(false) }
                    .buttonStyle(.matildeSecondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

private struct WelcomeScreen: View {
    let start: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Image("LaunchLogo")
                    .accessibilityHidden(true)
                    .offset(y: appeared || reduceMotion ? 0 : 30)
                VStack(spacing: 12) {
                    Text("Matilde")
                        .font(Paper.body(46))
                        .foregroundStyle(Color(red: 0.965, green: 0.949, blue: 0.918))
                    Text("You write every word.\nMatilde reads along.")
                        .font(Paper.body(21).italic())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(red: 0.965, green: 0.949, blue: 0.918).opacity(0.72))
                }
                .padding(.top, 28)
                .opacity(appeared ? 1 : 0)
                Spacer()
                Button("Get Started", action: start)
                    .buttonStyle(InvertedPrimaryButtonStyle())
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                    .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) { appeared = true }
        }
    }
}

/// The primary button on the dark welcome screen: light capsule, dark text.
private struct InvertedPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color(red: 0.169, green: 0.153, blue: 0.141))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color(red: 0.965, green: 0.949, blue: 0.918).opacity(configuration.isPressed ? 0.85 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

private struct TourPage<Vignette: View>: View {
    let title: String
    let text: String
    @ViewBuilder var vignette: Vignette

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            vignette
                .frame(maxWidth: 340)
                .padding(.horizontal, 28)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(title)
                    .font(Font(MarkdownStyle.bodyFont(28, bold: true)))
                    .foregroundStyle(Paper.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(text)
                    .font(.system(size: 17))
                    .foregroundStyle(Paper.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            Spacer(minLength: 140)
        }
    }
}

private struct FinishPage: View {
    let finish: (_ setUpSync: Bool) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.and.pencil")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(Paper.accent)
                .accessibilityHidden(true)
            Text("Ready when you are")
                .font(Font(MarkdownStyle.bodyFont(28, bold: true)))
                .foregroundStyle(Paper.ink)
            Text("Start a note now. You can turn on sync whenever you like.")
                .font(.system(size: 17))
                .foregroundStyle(Paper.muted)
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: 6) {
                Button("Start Writing") { finish(false) }
                    .buttonStyle(.matildePrimary)
                Button("Turn On Sync") { finish(true) }
                    .buttonStyle(.matildeSecondary)
            }
            .padding(.bottom, 44)
        }
        .padding(.horizontal, 28)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Paper.ink : Paper.muted.opacity(0.3))
                    .frame(width: index == current ? 18 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: Vignettes (small SwiftUI mock-ups of the app, not screenshots)

/// A card that looks like a page in the editor.
private struct VignetteCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Paper.muted.opacity(0.18)))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
    }
}

private struct EditorVignette: View {
    var body: some View {
        VignetteCard {
            Text("Letter to Ines")
                .font(Font(MarkdownStyle.bodyFont(22, bold: true)))
                .foregroundStyle(Paper.ink)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "flag").font(.system(size: 12)).padding(.top, 3)
                Text("Say thank you without rushing")
                    .font(Paper.body(15).italic())
            }
            .foregroundStyle(Paper.muted)
            Text("Dear Ines, the garden came back this spring, and I kept thinking of the afternoon you showed me where to plant the beans.")
                .font(Paper.body(16))
                .foregroundStyle(Paper.ink)
                .lineSpacing(4)
                .padding(.top, 4)
            HStack {
                Spacer()
                Text("214 words").font(.caption).foregroundStyle(Paper.muted)
            }
        }
    }
}

private struct CommentVignette: View {
    /// A paragraph with one passage highlighted like a comment in the editor.
    static var passage: AttributedString {
        var before = AttributedString("The beans grew taller than the fence. ")
        var marked = AttributedString("I think I finally understood what you meant about patience")
        marked.backgroundColor = Color(uiColor: Paper.commentHighlight)
        let after = AttributedString(", and about letting things be slow.")
        before.append(marked)
        before.append(after)
        return before
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VignetteCard {
                Text(Self.passage)
                    .font(Paper.body(16))
                    .foregroundStyle(Paper.ink)
                    .lineSpacing(4)
                Spacer(minLength: 60)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Matilde", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Paper.accent)
                Text("Is this the moment the letter turns? It could carry the ending.")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 230, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .leading) {
                Rectangle().fill(Paper.commentRule).frame(width: 3).padding(.vertical, 12)
            }
            .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
            .offset(x: 10, y: 24)
        }
        .padding(.bottom, 24)
    }
}

private struct SyncVignette: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VignetteCard {
            HStack(alignment: .center) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 50, weight: .ultraLight))
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Paper.accent)
                        .scaleEffect(pulse ? 1.12 : 1)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16))
                        .foregroundStyle(Paper.muted)
                }
                Spacer()
                Image(systemName: "iphone")
                    .font(.system(size: 44, weight: .ultraLight))
            }
            .foregroundStyle(Paper.ink)
            .padding(.vertical, 18)
            .padding(.horizontal, 8)
            Text("End-to-end encrypted · Stored in the EU")
                .font(.footnote)
                .foregroundStyle(Paper.muted)
                .frame(maxWidth: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
