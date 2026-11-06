import Foundation
import TunaCore

/// `--self-test`: quick sanity check of the shipped binary (no UI, no network), then exit.
enum SelfTest {
    @MainActor
    static func runAndExit() -> Never {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        print("Tuna TV \(version) (\(build)) self-test")

        var failures: [String] = []
        let now = Date()
        let catalog = DemoContent.catalog(now: now)
        let library = Library(catalog: Curator(preferences: ContentPreferences()).curate([catalog]))
        let showcaseMovies = library.showcase(.movie).count
        let showcaseSeries = library.showcase(.series).count
        let showcaseChannels = library.liveShowcase.count
        let showcase = showcaseMovies + showcaseSeries + showcaseChannels
        let vault = library.vaultCounts.values.reduce(0, +)
        print("Demo curation: raw \(catalog.items.count) | showcase \(showcase) "
              + "(movies \(showcaseMovies), series \(showcaseSeries), channels \(showcaseChannels)) | vault \(vault)")
        if catalog.items.isEmpty { failures.append("demo catalog is empty") }
        if showcase == 0 { failures.append("demo showcase is empty") }

        let account = DemoContent.account(now: now)
        let expires = account.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        print("Demo account: authorized \(account.isAuthorized) | status \(account.status ?? "-") | "
              + "connections \(account.activeConnections ?? 0)/\(account.maxConnections ?? 0) | expires \(expires)")
        if !account.isAuthorized { failures.append("demo account is not authorized") }

        let parsed = NameParser.parse("EN| The Matrix (1999) 4K", kind: .movie)
        print("NameParser: \"\(parsed.title)\" \(parsed.year.map(String.init) ?? "-") \(parsed.quality.label)")

        let pinHash = CoreHash.sha256Hex("1234")
        if pinHash != "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4" {
            failures.append("SHA-256 PIN hash mismatch")
        }

        if failures.isEmpty {
            print("SELF-TEST PASSED")
            exit(0)
        }
        print("SELF-TEST FAILED: " + failures.joined(separator: "; "))
        exit(1)
    }
}
