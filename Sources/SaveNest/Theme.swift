import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case cream, black
    static let preferenceKey = "appAppearance"
    static var saved: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .black
    }
    var id: String { rawValue }
    var title: String { self == .cream ? "Pearl" : "Midnight" }
    var subtitle: String { self == .cream ? "Frosted pearl & blue" : "Smoked glass & blue" }
    var colorScheme: ColorScheme { self == .cream ? .light : .dark }
    var nativeAppearance: NSAppearance? { NSAppearance(named: self == .cream ? .aqua : .darkAqua) }
    var previewPaper: Color { self == .cream ? Color(red: 0.929, green: 0.953, blue: 0.980) : Color(red: 0.067, green: 0.118, blue: 0.188) }
    var previewSurface: Color { self == .cream ? Color(red: 0.973, green: 0.984, blue: 1) : Color(red: 0.098, green: 0.169, blue: 0.259) }
    var previewAccent: Color { self == .cream ? Color(red: 0.031, green: 0.451, blue: 0.780) : Color(red: 0.427, green: 0.776, blue: 1) }
    var previewInk: Color { self == .cream ? Color(red: 0.110, green: 0.188, blue: 0.290) : Color(red: 0.941, green: 0.965, blue: 1) }
}

/// Each hosting surface observes the saved choice, including standalone floating panels.
private struct NestAppearance: ViewModifier {
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.black.rawValue
    private var selected: AppAppearance { AppAppearance(rawValue: appearance) ?? .black }
    func body(content: Content) -> some View {
        content.preferredColorScheme(selected.colorScheme).tint(Color.sage)
    }
}

extension Color {
    static let paper = adaptive(cream: (0.929, 0.953, 0.980), black: (0.067, 0.118, 0.188))
    static let sidebar = adaptive(cream: (0.890, 0.925, 0.969), black: (0.075, 0.137, 0.216))
    static let surface = adaptive(cream: (0.973, 0.984, 1), black: (0.098, 0.169, 0.259))
    static let raised = adaptive(cream: (1, 1, 1), black: (0.129, 0.224, 0.322))
    static let ink = adaptive(cream: (0.110, 0.188, 0.290), black: (0.941, 0.965, 1))
    static let sage = adaptive(cream: (0.031, 0.451, 0.780), black: (0.427, 0.776, 1))
    static let muted = adaptive(cream: (0.322, 0.412, 0.506), black: (0.678, 0.745, 0.816))
    static let line = adaptive(cream: (0.753, 0.816, 0.886), black: (0.188, 0.267, 0.357))
    static let onAccent = adaptive(cream: (1, 1, 1), black: (0.067, 0.118, 0.188))

    private static func adaptive(cream: (Double, Double, Double), black: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? black : cream
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// One shared surface treatment for editors, search fields, and inset cards.
struct NestSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 14
    var elevated = false
    private var solid: Bool { reduceTransparency || contrast == .increased }
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if solid {
                    shape.fill(elevated ? Color.raised : Color.surface)
                } else {
                    shape.fill((elevated ? Color.raised : Color.surface).opacity(0.86))
                        .background(.ultraThinMaterial, in: shape)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [
                        solid ? Color.ink.opacity(0.55) : Color.white.opacity(colorScheme == .dark ? 0.18 : 0.9),
                        Color.line.opacity(solid ? 1 : 0.65)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1
                ).allowsHitTesting(false)
            }
    }
}

extension View {
    func nestAppearance() -> some View { modifier(NestAppearance()) }
    func nestSurface(radius: CGFloat = 14, elevated: Bool = false) -> some View {
        modifier(NestSurface(radius: radius, elevated: elevated))
    }
}

struct NestIconButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium))
            .frame(width: 36, height: 36)
            .foregroundStyle(Color.ink.opacity(enabled ? 1 : 0.35))
            .nestSurface(radius: 11, elevated: configuration.isPressed)
    }
}
struct NestMark: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 32, sy = size.height / 32
            for points: [(CGFloat, CGFloat)] in [[(5,10.5),(16,17),(27,10.5)],[(5,16),(16,22.5),(27,16)],[(7,22),(16,27),(25,22)],[(11,7),(16,10),(21,7)]] {
                var path = Path(); path.move(to: CGPoint(x: points[0].0*sx, y: points[0].1*sy))
                for p in points.dropFirst() { path.addLine(to: CGPoint(x:p.0*sx, y:p.1*sy)) }
                context.stroke(path, with: .color(.sage), style: StrokeStyle(lineWidth: 2.5*sx, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityHidden(true)
    }
}
struct SageButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(Color.onAccent).background(Color.sage.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(Color.ink.opacity(enabled ? 1 : 0.35))
            .nestSurface(radius: 10, elevated: configuration.isPressed)
    }
}

struct DomainIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let domain: String
    var url: String? = nil
    var iconURL: String? = nil
    @State private var image: NSImage?
    private var requestID: String { (url ?? domain) + "|" + (iconURL ?? "") }
    private var hue: Double { Double(domain.utf8.reduce(0) { ($0 + Int($1)) % 360 }) / 360 }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(image == nil ? Color(hue: hue, saturation: colorScheme == .dark ? 0.18 : 0.10, brightness: colorScheme == .dark ? 0.24 : 0.94) : Color.raised)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Text(String(domain.prefix(1)).uppercased()).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hue: hue, saturation: colorScheme == .dark ? 0.22 : 0.28, brightness: colorScheme == .dark ? 0.84 : 0.50))
            }
        }.frame(width: 42, height: 42).accessibilityHidden(true)
            .task(id: requestID) {
                image = nil
                guard let url else { return }
                let data = await SiteIconLoader.shared.image(page: url, hint: iconURL)
                guard !Task.isCancelled else { return }
                image = data.flatMap(NSImage.init(data:))
            }
    }
}
