import SwiftUI

/// The building blocks the tour's pages share, and the things drawn on its illustrated screens.
extension OnboardingPageView {
    // MARK: - Pieces

    /// A symbol over a short line, in a card; three of them sit side by side.
    struct OnboardingTile: View {
        let text: String
        let systemImage: String

        init(_ text: String, systemImage: String) {
            self.text = text
            self.systemImage = systemImage
        }

        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 22)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(OnboardingCardBackground())
            .accessibilityElement(children: .combine)
        }
    }

    /// A symbol beside a line or two of explanation.
    struct HintRow: View {
        let text: String
        let systemImage: String

        init(_ text: String, systemImage: String) {
            self.text = text
            self.systemImage = systemImage
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: StatusRow.textInset, alignment: .leading)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// A title with a switch at the trailing edge, like a row in System Settings.
    struct SwitchRow: View {
        let title: String
        @Binding var isOn: Bool

        init(_ title: String, isOn: Binding<Bool>) {
            self.title = title
            _isOn = isOn
        }

        var body: some View {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    /// A rounded, faintly filled box that groups a page's controls.
    struct OnboardingCard<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(OnboardingCardBackground())
        }
    }

    struct OnboardingCardBackground: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    /// An icon beside a bold line and a secondary detail line.
    struct StatusRow: View {
        /// How far the text sits from the leading edge, so things below can line up with it.
        static let textInset: CGFloat = 32

        let title: String
        let detail: String
        let systemImage: String
        let tint: Color

        init(_ title: String, detail: String, systemImage: String, tint: Color) {
            self.title = title
            self.detail = detail
            self.systemImage = systemImage
            self.tint = tint
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: Self.textInset, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The palette as a horizontal gradient, the primary taking its `balance` share.
    struct PaletteSwatch: View {
        let palette: GlowPalette

        var body: some View {
            let share = min(max(palette.balance, 0), 1)
            let primary = Color(nsColor: palette.primary.nsColor)
            let secondary = Color(nsColor: palette.secondary.nsColor)
            Capsule()
                .fill(LinearGradient(
                    stops: [
                        .init(color: primary, location: 0),
                        .init(color: primary, location: share * 0.5),
                        .init(color: secondary, location: share + (1 - share) * 0.5),
                        .init(color: secondary, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Things on the illustrated screen

    /// A plain app window on the pretend desktop.
    struct DesktopWindow: View {
        var body: some View {
            GeometryReader { proxy in
                let unit = proxy.size.height * 0.05
                VStack(alignment: .leading, spacing: unit * 1.2) {
                    HStack(spacing: unit * 0.6) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { color in
                            Circle().fill(color.opacity(0.75)).frame(width: unit, height: unit)
                        }
                    }
                    ForEach([0.8, 0.55, 0.7], id: \.self) { length in
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: proxy.size.width * 0.42 * length, height: unit * 0.8)
                    }
                }
                .padding(unit * 1.4)
                .frame(width: proxy.size.width * 0.46, height: proxy.size.height * 0.56, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: unit * 1.2, style: .continuous).fill(Color(white: 0.16)))
                .overlay(RoundedRectangle(cornerRadius: unit * 1.2, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
            }
        }
    }

    /// A terminal window with a prompt, for the coding-session page.
    struct TerminalWindow: View {
        var body: some View {
            GeometryReader { proxy in
                let unit = proxy.size.height * 0.05
                VStack(alignment: .leading, spacing: unit) {
                    HStack(spacing: unit * 0.6) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { color in
                            Circle().fill(color.opacity(0.75)).frame(width: unit, height: unit)
                        }
                    }
                    Text("~ % claude")
                        .font(.system(size: unit * 1.7, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Capsule()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: unit * 0.9, height: unit * 1.6)
                }
                .padding(unit * 1.4)
                .frame(width: proxy.size.width * 0.46, height: proxy.size.height * 0.56, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: unit * 1.2, style: .continuous).fill(Color(white: 0.08)))
                .overlay(RoundedRectangle(cornerRadius: unit * 1.2, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
            }
        }
    }

    /// An album cover in the palette's colors.
    struct AlbumCover: View {
        let palette: GlowPalette

        var body: some View {
            GeometryReader { proxy in
                let side = proxy.size.height * 0.5
                RoundedRectangle(cornerRadius: side * 0.08, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(nsColor: palette.primary.nsColor), Color(nsColor: palette.secondary.nsColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.42, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                    .frame(width: side, height: side)
                    .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
            }
        }
    }

    /// A large symbol in the middle of the pretend screen.
    struct CenterSymbol: View {
        let name: String

        var body: some View {
            GeometryReader { proxy in
                Image(systemName: name)
                    .font(.system(size: proxy.size.height * 0.3, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
            }
        }
    }
}
