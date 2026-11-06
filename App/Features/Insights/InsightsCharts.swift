import SwiftUI
import Charts
import TunaCore

/// Quality, languages, countries, genres, decades and the Vault breakdown.
struct InsightsChartsGrid: View {
    let report: InsightsReport
    let revealed: Bool

    var body: some View {
        let quality = InsightsData.quality(report)
        let languages = InsightsData.languages(report)
        let countries = InsightsData.countries(report)
        let genres = InsightsData.genres(report)
        let decades = InsightsData.decades(report)
        let vault = report.vaultBreakdown.filter { $0.count > 0 }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
            if !quality.isEmpty {
                InsightsCard("Picture quality", symbol: "sparkles.tv") {
                    InsightsBarChart(bars: quality, revealed: revealed)
                }
                .staggeredAppear(index: 5)
            }
            if !languages.isEmpty {
                InsightsCard("Languages", symbol: "character.bubble.fill") {
                    InsightsBarChart(bars: languages, revealed: revealed)
                }
                .staggeredAppear(index: 6)
            }
            if !countries.isEmpty {
                InsightsCard("Countries", symbol: "globe.europe.africa.fill") {
                    InsightsBarChart(bars: countries, revealed: revealed)
                }
                .staggeredAppear(index: 7)
            }
            if !genres.isEmpty {
                InsightsCard("Genres", symbol: "theatermasks.fill") {
                    InsightsBarChart(bars: genres, revealed: revealed)
                }
                .staggeredAppear(index: 8)
            }
            if !decades.isEmpty {
                InsightsCard("Decades", symbol: "calendar") {
                    InsightsDecadeChart(bars: decades, revealed: revealed)
                }
                .staggeredAppear(index: 9)
            }
            if !vault.isEmpty {
                InsightsCard("The Vault", symbol: "shippingbox.fill") {
                    InsightsVaultBreakdown(rows: vault.map { InsightsVaultRow(shelf: $0.shelf, count: $0.count) }, revealed: revealed)
                }
                .staggeredAppear(index: 10)
            }
        }
    }
}

enum InsightsData {
    static func quality(_ report: InsightsReport) -> [InsightsBar] {
        report.qualityBreakdown.filter { $0.count > 0 }.enumerated().map { item in
            InsightsBar(id: "q\(item.offset)", label: item.element.label, value: item.element.count,
                        color: qualityColor(item.element.label))
        }
    }

    static func qualityColor(_ label: String) -> Color {
        let match = Quality.allCases.first { $0.label.lowercased() == label.lowercased() }
        switch match {
        case .some(.uhd): return Tuna.Palette.uhd
        case .some(.fhd): return Tuna.Palette.fhd
        case .some(.hd): return Tuna.Palette.hd
        case .some(.sd): return Tuna.Palette.sd
        case .some(.unknown), .none: return Tuna.Palette.textTertiary
        }
    }

    static func languages(_ report: InsightsReport) -> [InsightsBar] {
        var seen = Set<String>()
        return report.languageBreakdown.filter { $0.count > 0 }.prefix(10).map { item in
            let flag = TDFormat.languageFlagCountry(item.code).map { Flags.emoji(for: $0) } ?? ""
            let label = unique(flag.isEmpty ? TDFormat.languageName(item.code) : "\(flag) \(TDFormat.languageName(item.code))",
                               code: item.code, seen: &seen)
            return InsightsBar(id: "l-\(item.code)", label: label, value: item.count, color: Tuna.Palette.accentCool)
        }
    }

    static func countries(_ report: InsightsReport) -> [InsightsBar] {
        var seen = Set<String>()
        return report.countryBreakdown.filter { $0.count > 0 }.prefix(10).map { item in
            let flag = Flags.emoji(for: item.code)
            let label = unique(flag.isEmpty ? TDFormat.countryName(item.code) : "\(flag) \(TDFormat.countryName(item.code))",
                               code: item.code, seen: &seen)
            return InsightsBar(id: "c-\(item.code)", label: label, value: item.count, color: Tuna.Palette.accent)
        }
    }

    static func genres(_ report: InsightsReport) -> [InsightsBar] {
        var seen = Set<String>()
        return report.genreBreakdown.filter { $0.count > 0 }.prefix(12).map { item in
            let label = unique(item.name, code: item.name, seen: &seen)
            return InsightsBar(id: "g-\(item.name)", label: label, value: item.count, color: Tuna.Palette.gold)
        }
    }

    static func decades(_ report: InsightsReport) -> [InsightsBar] {
        report.decadeBreakdown.filter { $0.count > 0 }.sorted { $0.decade < $1.decade }.map { item in
            InsightsBar(id: "d\(item.decade)", label: String(item.decade) + "s", value: item.count, color: Tuna.Palette.accentCool)
        }
    }

    /// Chart categories must be unique strings.
    private static func unique(_ label: String, code: String, seen: inout Set<String>) -> String {
        var candidate = label
        if seen.contains(candidate) { candidate = "\(label) (\(code.uppercased()))" }
        seen.insert(candidate)
        return candidate
    }
}

/// Horizontal bars with the value at the end of each bar.
struct InsightsBarChart: View {
    let bars: [InsightsBar]
    let revealed: Bool

    var body: some View {
        let maxValue = bars.map(\.value).max() ?? 1
        Chart(bars) { bar in
            BarMark(x: .value("Titles", revealed ? bar.value : 0), y: .value("Item", bar.label))
                .foregroundStyle(bar.color.gradient)
                .cornerRadius(5)
                .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                    Text(bar.value.formatted())
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Tuna.Palette.textSecondary)
                }
        }
        .chartXScale(domain: 0...max(1, Int(Double(maxValue) * 1.22)))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
            }
        }
        .frame(height: CGFloat(bars.count) * 28 + 12)
    }
}

/// Vertical decade histogram.
struct InsightsDecadeChart: View {
    let bars: [InsightsBar]
    let revealed: Bool

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Decade", bar.label), y: .value("Titles", revealed ? bar.value : 0))
                .foregroundStyle(Tuna.Gradients.cool)
                .cornerRadius(4)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
            }
        }
        .frame(height: 210)
    }
}

struct InsightsVaultRow: Identifiable {
    let shelf: VaultShelf
    let count: Int
    var id: String { shelf.rawValue }
}

/// Vault shelves with their logo symbols and proportional bars.
struct InsightsVaultBreakdown: View {
    let rows: [InsightsVaultRow]
    let revealed: Bool

    var body: some View {
        let maxCount = max(1, rows.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    VaultShelfLogo(shelf: row.shelf, size: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row.shelf.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Tuna.Palette.textPrimary)
                            Spacer()
                            Text(row.count.formatted())
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Tuna.Palette.textSecondary)
                        }
                        ProgressLine(fraction: revealed ? Double(row.count) / Double(maxCount) : 0,
                                     tint: VaultLook.tint(row.shelf), height: 6)
                    }
                }
            }
        }
    }
}
