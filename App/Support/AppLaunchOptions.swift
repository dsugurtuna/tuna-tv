import Foundation

/// Command-line modes: `--self-test` and `--snapshots <dir>` (CI). Both use the `.snapshot` environment.
enum AppLaunchOptions {
    static let arguments = CommandLine.arguments

    static var isSelfTest: Bool { arguments.contains("--self-test") }

    static var snapshotDirectory: URL? {
        guard let index = arguments.firstIndex(of: "--snapshots") else { return nil }
        let next = arguments.index(after: index)
        let path: String
        if next < arguments.endIndex, !arguments[next].hasPrefix("-") {
            path = (arguments[next] as NSString).expandingTildeInPath
        } else {
            path = FileManager.default.currentDirectoryPath + "/snapshots"
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var isSnapshotRun: Bool { snapshotDirectory != nil }

    static var environment: AppEnvironment { (isSelfTest || isSnapshotRun) ? .snapshot : .live }
}
