import SwiftUI

// MARK: - GlassButton

/// Glass button used everywhere (Play, My List, Trailer ...).
/// primary: coral gradient, white bold text; secondary: glass capsule; icon: circular glass; destructive: red glass.
/// Hover brightens, press scales down; a regular `Button`, so it is focusable and keyboard-activatable.
struct GlassButton: View {
    var title: String? = nil
    var systemImage: String? = nil
    var style: GlassButtonStyleKind = .secondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            DSGlassButtonLabel(title: style == .icon ? nil : title, systemImage: systemImage, style: style)
        }
        .buttonStyle(DSGlassButtonStyle(kind: style, isCircular: isCircular))
        .accessibilityLabel(Text(accessibilityName))
        .help(helpText)
    }

    private var isCircular: Bool { style == .icon || title == nil }

    private var accessibilityName: String {
        if let title, !title.isEmpty { return title }
        return DSSymbolNames.spoken(systemImage)
    }

    private var helpText: String {
        guard style == .icon || title == nil else { return "" }
        if let title, !title.isEmpty { return title }
        return DSSymbolNames.spoken(systemImage)
    }
}

private struct DSGlassButtonLabel: View {
    var title: String?
    var systemImage: String?
    var style: GlassButtonStyleKind

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: title == nil ? 15 : 13.5, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
            }
            if let title, !title.isEmpty {
                Text(title)
                    .font(style == .primary ? Tuna.Fonts.buttonProminent : Tuna.Fonts.button)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(foreground)
    }

    private var foreground: Color {
        switch style {
        case .primary: return Color.white
        case .secondary, .icon: return Tuna.Palette.textPrimary
        case .destructive: return Color(hex: 0xFF8A82)
        }
    }
}

struct DSGlassButtonStyle: ButtonStyle {
    var kind: GlassButtonStyleKind
    var isCircular: Bool

    func makeBody(configuration: Configuration) -> some View {
        DSGlassButtonChrome(configuration: configuration, kind: kind, isCircular: isCircular)
    }
}

private struct DSGlassButtonChrome: View {
    let configuration: ButtonStyleConfiguration
    var kind: GlassButtonStyleKind
    var isCircular: Bool

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var height: CGFloat { isCircular ? Tuna.Metrics.iconButtonSize : Tuna.Metrics.buttonHeight }
    private var radius: CGFloat { height / 2 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .circular) }

    var body: some View {
        surface
            .overlay { shape.fill(Color.white.opacity(highlightOpacity)).allowsHitTesting(false) }
            .overlay { shape.strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 1).allowsHitTesting(false) }
            .contentShape(shape)
            .scaleEffect(scale)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { inside in isHovering = inside && isEnabled }
            .animation(Tuna.Motion.snappy, value: configuration.isPressed)
            .animation(Tuna.Motion.hover, value: isHovering)
    }

    @ViewBuilder
    private var sized: some View {
        if isCircular {
            configuration.label
                .frame(width: height, height: height)
        } else {
            configuration.label
                .padding(.horizontal, 18)
                .frame(height: height)
        }
    }

    @ViewBuilder
    private var surface: some View {
        switch kind {
        case .primary:
            sized
                .background(Tuna.Gradients.accent, in: shape)
                .shadow(color: Tuna.Palette.accent.opacity(isHovering ? 0.55 : 0.32), radius: isHovering ? 16 : 10, x: 0, y: 4)
        case .secondary, .icon:
            sized
                .tunaGlass(cornerRadius: radius)
        case .destructive:
            sized
                .tunaGlass(cornerRadius: radius, tint: Tuna.Palette.danger)
        }
    }

    private var highlightOpacity: Double {
        if configuration.isPressed { return 0.02 }
        return isHovering ? 0.1 : 0
    }

    private var strokeOpacity: Double {
        switch kind {
        case .primary: return isHovering ? 0.35 : 0.18
        case .secondary, .icon, .destructive: return isHovering ? 0.3 : 0.1
        }
    }

    private var scale: CGFloat {
        if configuration.isPressed { return 0.95 }
        return isHovering ? 1.03 : 1
    }
}

/// Spoken names for common symbols used without a title.
enum DSSymbolNames {
    static func spoken(_ symbol: String?) -> String {
        guard let symbol else { return "Button" }
        if symbol.hasPrefix("play") { return "Play" }
        if symbol.hasPrefix("plus") { return "Add to My List" }
        if symbol.hasPrefix("checkmark") { return "In My List" }
        if symbol.hasPrefix("chevron.left") { return "Previous" }
        if symbol.hasPrefix("chevron.right") { return "Next" }
        if symbol.hasPrefix("xmark") { return "Close" }
        if symbol.hasPrefix("heart") { return "Favourite" }
        if symbol.hasPrefix("speaker") { return "Sound" }
        if symbol.hasPrefix("info") { return "More info" }
        if symbol.hasPrefix("magnifyingglass") { return "Search" }
        if symbol.hasPrefix("gearshape") { return "Settings" }
        return symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ").capitalized
    }
}

// MARK: - SectionHeader

/// Section header with optional subtitle and a hoverable "See all ›".
struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var seeAll: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Tuna.Fonts.sectionTitle)
                    .foregroundStyle(Tuna.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Tuna.Fonts.caption)
                        .foregroundStyle(Tuna.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            if let seeAll {
                DSSeeAllButton(action: seeAll)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct DSSeeAllButton: View {
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("See all")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .offset(x: isHovering ? 3 : 0)
            }
            .foregroundStyle(isHovering ? Tuna.Palette.accent : Tuna.Palette.textSecondary)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Tuna.Motion.snappy) { isHovering = inside }
        }
        .accessibilityLabel(Text("See all"))
    }
}

// MARK: - ChipBar

/// Selectable chips (genres, filters). A sliding pill (matchedGeometryEffect) marks the selection;
/// the optional "All" chip maps to a nil selection.
struct ChipBar: View {
    var items: [String]
    @Binding var selection: String?
    var allLabel: String? = "All"

    @Namespace private var pillNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let allLabel {
                    DSChip(title: allLabel, isSelected: selection == nil, namespace: pillNamespace) {
                        select(nil)
                    }
                }
                ForEach(uniqueItems, id: \.self) { item in
                    DSChip(title: item, isSelected: selection == item, namespace: pillNamespace) {
                        select(item)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    private var uniqueItems: [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private func select(_ value: String?) {
        withAnimation(Tuna.Motion.snappy) { selection = value }
    }
}

private struct DSChip: View {
    var title: String
    var isSelected: Bool
    var namespace: Namespace.ID
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: Tuna.Metrics.chipHeight)
                .background { chipBackground }
                .overlay { chipStroke }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in isHovering = inside }
        .animation(Tuna.Motion.snappy, value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var textColor: Color {
        if isSelected { return Tuna.Palette.inkOnLight }
        return Tuna.Palette.textPrimary.opacity(isHovering ? 1 : 0.82)
    }

    @ViewBuilder
    private var chipBackground: some View {
        if isSelected {
            Capsule()
                .fill(Color.white.opacity(0.95))
                .matchedGeometryEffect(id: "tuna.chip.selection", in: namespace)
                .shadow(color: Color.white.opacity(0.18), radius: 8)
        } else {
            Capsule()
                .fill(Color.white.opacity(isHovering ? 0.12 : 0.06))
        }
    }

    @ViewBuilder
    private var chipStroke: some View {
        if !isSelected {
            Capsule().strokeBorder(Tuna.Palette.stroke, lineWidth: 1)
        }
    }
}
