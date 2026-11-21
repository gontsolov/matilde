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
            VStack(spacing: 0) {
                // Skip sits in its own row so the pages never run under it.
                HStack {
                    Spacer()
                    Button("Skip") { finish(false) }
                        .buttonStyle(.matildeSecondary)
                        .padding(.horizontal, 16)
                        .opacity(tour.screen == .finish ? 0 : 1)
                        .disabled(tour.screen == .finish)
                }
                .frame(height: 44)
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
            }
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
                        .font(Font(MarkdownStyle.bodyFont(46)))
                        .foregroundStyle(Color(red: 0.965, green: 0.949, blue: 0.918))
                    Text("You write every word.\nMatilde reads along.")
                        .font(Font(MarkdownStyle.bodyFont(21, italic: true)))
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
                    .font(Font(MarkdownStyle.bodyFont(26, bold: true)))
                    .foregroundStyle(Paper.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(text)
                    .font(.callout)
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
                .font(Font(MarkdownStyle.bodyFont(26, bold: true)))
                .foregroundStyle(Paper.ink)
            Text("Start a note now. You can turn on sync whenever you like.")
                .font(.callout)
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
            .fixedSize(horizontal: false, vertical: true)
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
                    .font(Font(MarkdownStyle.bodyFont(15, italic: true)))
            }
            .foregroundStyle(Paper.muted)
            Text("Dear Ines, the garden came back this spring, and I kept thinking of the afternoon you showed me where to plant the beans.")
                .font(Font(MarkdownStyle.bodyFont(16)))
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
        // The note hugs its paragraph; Matilde's card floats over its lower edge like a margin
        // comment on the Mac (lighter surface, hairline border, soft shadow, accent bar).
        VStack(alignment: .trailing, spacing: -26) {
            VignetteCard {
                Text(Self.passage)
                    .font(Font(MarkdownStyle.bodyFont(16)))
                    .foregroundStyle(Paper.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 22)
            }
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Paper.commentRule)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Matilde", systemImage: "sparkles")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Paper.accent)
                    Text("Is this the moment the letter turns? It could carry the ending.")
                        .font(.subheadline)
                        .foregroundStyle(Paper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(width: 236, alignment: .leading)
            .background(Paper.elevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Paper.ink.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.trailing, -8)
        }
    }
}

private struct SyncVignette: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VignetteCard {
            // Three equal columns on one centre line, the group centred in the card.
            HStack(spacing: 0) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 44, weight: .ultraLight))
                    .frame(maxWidth: .infinity)
                VStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Paper.accent)
                        .scaleEffect(pulse ? 1.12 : 1)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 15))
                        .foregroundStyle(Paper.muted)
                }
                .frame(maxWidth: .infinity)
                Image(systemName: "iphone")
                    .font(.system(size: 40, weight: .ultraLight))
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 64, alignment: .center)
            .foregroundStyle(Paper.ink)
            .padding(.top, 6)
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
