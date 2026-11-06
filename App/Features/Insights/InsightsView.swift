import SwiftUI
import Charts
import TunaCore

/// "Your library, decoded": what curation did with the provider's catalog (route `.insights`).
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var report: InsightsReport?
    @State private var revealed = false

    init() {}

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if let report {
                        if report.totalTitles == 0 && report.totalRaw == 0 {
                            EmptyStateView(symbol: "chart.bar.xaxis",
                                           title: "Nothing to decode yet",
                                           message: "Add a provider (or try the demo) and Tuna TV will show you what it found.")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            InsightsDashboard(report: report, revealed: revealed)
                        }
                    } else {
                        InsightsSkeleton()
                    }
                }
                .tunaPageInset()
                .padding(.top, Tuna.Metrics.topBarHeight + 76)
                .padding(.bottom, 80)
            }
            TDBackButton()
        }
        .task {
            await Task.yield()
            report = model.insights()
            if systemReduceMotion || model.settings.reduceMotion {
                revealed = true
            } else {
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.smooth(duration: 1.0)) { revealed = true }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INSIGHTS")
                .font(Tuna.Fonts.micro)
                .tracking(2)
                .foregroundStyle(Tuna.Palette.accentCool)
            Text("Your library, decoded")
                .font(Tuna.Fonts.pageTitle)
                .foregroundStyle(Tuna.Palette.textPrimary)
            if let report, report.totalRaw > 0 {
                Text(InsightsDashboard.storyLine(report))
                    .font(Tuna.Fonts.bodyLarge)
                    .foregroundStyle(Tuna.Palette.textSecondary)
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }
}

struct InsightsBar: Identifiable {
    let id: String
    let label: String
    let value: Int
    let color: Color
}

/// Glass card with a title, an SF Symbol and content.
struct InsightsCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Tuna.Palette.textSecondary)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .tunaGlass(cornerRadius: Tuna.Metrics.panelRadius)
    }
}

struct InsightsDashboard: View {
    let report: InsightsReport
    let revealed: Bool

    static func storyLine(_ report: InsightsReport) -> String {
        let vaultShare = Int(((1 - report.showcaseShare) * 100).rounded())
        return "Tuna TV turned \(report.totalRaw.formatted()) messy provider records into \(report.totalTitles.formatted()) clean titles"
            + " — \(report.duplicatesMerged.formatted()) duplicates merged, and \(max(0, vaultShare))% tucked away in The Vault."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                InsightsCard("Raw items → titles", symbol: "arrow.triangle.merge") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TDCountUpText(value: Double(report.totalRaw), font: Tuna.Fonts.rounded(26, weight: .heavy))
                            .foregroundStyle(Tuna.Palette.textSecondary)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(Tuna.Palette.textTertiary)
                        TDCountUpText(value: Double(report.totalTitles), font: Tuna.Fonts.rounded(30, weight: .heavy))
                            .foregroundStyle(Tuna.Palette.textPrimary)
                    }
                    caption("Every provider record, merged into one clean entry per title.")
                }
                .staggeredAppear(index: 0)
                InsightsCard("Duplicates merged", symbol: "square.stack.3d.down.right.fill") {
                    TDCountUpText(value: Double(report.duplicatesMerged))
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    caption(ratioText)
                }
                .staggeredAppear(index: 1)
                InsightsCard("Showcase share", symbol: "sparkles.tv.fill") {
                    HStack(spacing: 16) {
                        InsightsDonut(share: report.showcaseShare, revealed: revealed)
                            .frame(width: 92, height: 92)
                        VStack(alignment: .leading, spacing: 6) {
                            legend(color: Tuna.Palette.accent, text: "Showcase")
                            legend(color: Tuna.Palette.surfaceRaised, text: "The Vault")
                        }
                    }
                }
                .staggeredAppear(index: 2)
                InsightsCard("Metadata coverage", symbol: "text.magnifyingglass") {
                    HStack(spacing: 16) {
                        InsightsRing(fraction: report.metadataCoverage, revealed: revealed)
                            .frame(width: 92, height: 92)
                        caption("Titles matched with posters, cast and ratings.")
                    }
                }
                .staggeredAppear(index: 3)
                InsightsCard("Hours watched", symbol: "play.circle.fill") {
                    TDCountUpText(value: report.hoursWatched, format: { value in TDFormat.oneDecimal(value) + " h" })
                        .foregroundStyle(Tuna.Palette.textPrimary)
                    caption("Movies, series and live TV on this Mac.")
                }
                .staggeredAppear(index: 4)
            }
            InsightsChartsGrid(report: report, revealed: revealed)
        }
    }

    private var ratioText: String {
        guard report.totalTitles > 0, report.totalRaw > report.totalTitles else { return "Your provider keeps things tidy." }
        let ratio = Double(report.totalRaw) / Double(report.totalTitles)
        return "\(TDFormat.oneDecimal(ratio))× fewer things to scroll through."
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Tuna.Fonts.caption)
            .foregroundStyle(Tuna.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text)
                .font(Tuna.Fonts.caption)
                .foregroundStyle(Tuna.Palette.textSecondary)
        }
    }
}

/// Showcase vs Vault donut (SectorMark) with the percentage in the middle.
struct InsightsDonut: View {
    let share: Double
    let revealed: Bool

    var body: some View {
        let clamped = min(1, max(0, share.isFinite ? share : 0))
        let shown = revealed ? clamped : 0
        Chart {
            SectorMark(angle: .value("Share", max(0.0001, shown)), innerRadius: .ratio(0.66), angularInset: 1.5)
                .foregroundStyle(Tuna.Gradients.accent)
                .cornerRadius(3)
            SectorMark(angle: .value("Share", max(0.0001, 1 - shown)), innerRadius: .ratio(0.66), angularInset: 1.5)
                .foregroundStyle(Tuna.Palette.surfaceRaised)
                .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .overlay {
            TDCountUpText(value: clamped * 100, font: Tuna.Fonts.rounded(18, weight: .heavy),
                          format: { value in "\(Int(value.rounded()))%" })
                .foregroundStyle(Tuna.Palette.textPrimary)
        }
    }
}

/// Circular progress ring.
struct InsightsRing: View {
    let fraction: Double
    let revealed: Bool

    var body: some View {
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        ZStack {
            Circle()
                .stroke(Tuna.Palette.surfaceRaised, lineWidth: 9)
            Circle()
                .trim(from: 0, to: revealed ? clamped : 0)
                .stroke(Tuna.Gradients.cool, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            TDCountUpText(value: clamped * 100, font: Tuna.Fonts.rounded(18, weight: .heavy),
                          format: { value in "\(Int(value.rounded()))%" })
                .foregroundStyle(Tuna.Palette.textPrimary)
        }
        .padding(5)
    }
}

struct InsightsSkeleton: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], spacing: 18) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Tuna.Metrics.panelRadius, style: .continuous)
                    .fill(Tuna.Palette.surfaceElevated)
                    .frame(height: 150)
            }
        }
        .shimmering()
    }
}
