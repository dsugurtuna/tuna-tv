import Foundation
import UIKit
import ImageIO
import SwiftUI
import TunaCore

/// Loads every remote artwork in the app.
///
/// - Memory: `NSCache` of decoded, downsampled images keyed by URL + target-size bucket.
/// - Disk: raw bytes in Library/Caches/TunaTV2/images (hashed file names), kept forever for provider panel
///   images ("p-" files) and trimmed oldest-first for CDN images ("c-" files) when they exceed ~900 MB.
/// - Decoding: `CGImageSourceCreateThumbnailAtIndex` off the main thread, sized to cover the target.
/// - In-flight loads are de-duplicated; when every caller is cancelled (card scrolled away) a load that has not
///   reached the network yet is dropped, so the provider never sees requests for images nobody looks at.
/// - HTTP: one URLSession with the configured User-Agent. Every request goes through `HostLimiter.run(host:)`;
///   provider panel hosts additionally pass a one-at-a-time / ≥1 s gate of their own, get a persistent "missing"
///   marker for 4xx answers and pause for minutes after 401/403/429/5xx (never hammering a panel that pushes back).
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    /// Colour facts sampled once per decoded image (channel tiles, ambient tints).
    struct Traits: Sendable, Hashable {
        /// Saturation-weighted average colour (sRGB 0…1).
        var red: Double
        var green: Double
        var blue: Double
        /// Mean luminance of the visible pixels (0 dark … 1 light).
        var luminance: Double
        /// True when a noticeable share of pixels is transparent (typical for logos).
        var hasTransparency: Bool

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    }

    /// Library/Caches/TunaTV2/images
    let cacheDirectory: URL

    // Guarded by `lock`.
    private let lock = NSLock()
    private var limiter: HostLimiter?
    /// "host" / "host:port" -> the exact provider host string the app registered (used as the limiter key).
    private var providerIndex: [String: String] = [:]
    private var isConfigured = false
    private var userAgent: String
    private var session: URLSession
    private var inflight: [String: DSInflightLoad] = [:]
    private var negative: [String: Date] = [:]
    private var pausedHosts: [String: Date] = [:]
    private var failureStreaks: [String: Int] = [:]
    private var directoryReady = false
    private var trimScheduled = false

    private let memory = NSCache<NSString, DSImageBox>()
    private let traitsCache = NSCache<NSString, DSTraitsBox>()
    private let gate = DSProviderImageGate()

    private static let providerMissTTL: TimeInterval = 3 * 86_400
    private static let cdnCacheLimit: Int64 = 900 * 1024 * 1024
    private static let cdnCacheTarget: Int64 = 650 * 1024 * 1024
    private static let wellKnownImageHosts: [String] = [
        "tmdb.org", "themoviedb.org", "tvmaze.com", "githubusercontent.com", "github.io", "wikimedia.org",
        "wikipedia.org", "imgur.com", "fanart.tv", "media-amazon.com", "omdbapi.com",
    ]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        cacheDirectory = caches
            .appendingPathComponent("TunaTV2", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        let agent = UserAgentPreset.default.value
        userAgent = agent
        session = ImagePipeline.makeSession(userAgent: agent)
        memory.totalCostLimit = 320 * 1024 * 1024
        memory.countLimit = 800
        traitsCache.countLimit = 5000
    }

    // MARK: - Public API

    /// Call at launch and whenever providers change. `providerHosts` are the IPTV panel hosts ("panel.tv" or
    /// "panel.tv:8080"); the app must have set `HostLimiter.Rule.providerImages` for each of them on `limiter`.
    func configure(limiter: HostLimiter, providerHosts: Set<String>, userAgent: String) {
        var index: [String: String] = [:]
        for raw in providerHosts {
            guard let entry = ImagePipeline.normalizedHostEntry(raw) else { continue }
            index[entry] = entry
            let bare = ImagePipeline.stripPort(entry)
            if index[bare] == nil { index[bare] = entry }
        }
        let trimmedAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = trimmedAgent.isEmpty ? UserAgentPreset.default.value : trimmedAgent
        var retired: URLSession?
        lock.lock()
        self.limiter = limiter
        self.providerIndex = index
        self.isConfigured = true
        if agent != self.userAgent {
            retired = session
            session = ImagePipeline.makeSession(userAgent: agent)
            self.userAgent = agent
        }
        lock.unlock()
        retired?.finishTasksAndInvalidate()
    }

    /// Decoded image covering `targetPixelSize` (pixels, i.e. points × backing scale), or nil when the image is
    /// missing, undecodable, paused for safety or the caller was cancelled.
    func image(for url: URL, targetPixelSize: CGSize) async -> UIImage? {
        guard ImagePipeline.isLoadable(url) else { return nil }
        let bucket = DSPixelBucket(targetPixelSize)
        let key = ImagePipeline.memoryKey(url: url, bucket: bucket)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }
        if isNegative(url) { return nil }
        let ticket = joinOrStart(key: key, url: url, bucket: bucket)
        let token = ticket.token
        let box = await withTaskCancellationHandler {
            await ticket.task.value
        } onCancel: {
            self.leave(key: key, token: token)
        }
        return box?.image
    }

    /// Synchronous memory-cache lookup (no I/O). Lets views show cached art on their very first frame.
    func cachedImage(for url: URL, targetPixelSize: CGSize) -> UIImage? {
        let key = ImagePipeline.memoryKey(url: url, bucket: DSPixelBucket(targetPixelSize))
        return memory.object(forKey: key as NSString)?.image
    }

    /// Colour traits of an already decoded image (memory only).
    func traits(for url: URL) -> Traits? {
        traitsCache.object(forKey: url.absoluteString as NSString)?.traits
    }

    /// Removes every cached image (memory and disk). Safety pauses are kept.
    func clearDiskCache() {
        memory.removeAllObjects()
        traitsCache.removeAllObjects()
        lock.lock()
        negative.removeAll()
        directoryReady = false
        lock.unlock()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Bytes used on disk by the image cache.
    var diskUsageBytes: Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                       includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - In-flight de-duplication

    private func joinOrStart(key: String, url: URL, bucket: DSPixelBucket) -> DSLoadTicket {
        lock.lock()
        defer { lock.unlock() }
        if var entry = inflight[key] {
            entry.waiters += 1
            inflight[key] = entry
            return DSLoadTicket(task: entry.task, token: entry.token)
        }
        let token = UUID()
        let task = Task.detached(priority: .userInitiated) { () -> DSImageBox? in
            let box = await self.load(url: url, bucket: bucket, key: key)
            self.finish(key: key, token: token)
            return box
        }
        inflight[key] = DSInflightLoad(task: task, token: token, waiters: 1)
        return DSLoadTicket(task: task, token: token)
    }

    /// A caller went away. When nobody waits any more, the load is cancelled (it stops before the network).
    private func leave(key: String, token: UUID) {
        lock.lock()
        guard var entry = inflight[key], entry.token == token else {
            lock.unlock()
            return
        }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            inflight[key] = nil
            lock.unlock()
            entry.task.cancel()
        } else {
            inflight[key] = entry
            lock.unlock()
        }
    }

    private func finish(key: String, token: UUID) {
        lock.lock()
        if inflight[key]?.token == token { inflight[key] = nil }
        lock.unlock()
    }

    // MARK: - Loading

    private func load(url: URL, bucket: DSPixelBucket, key: String) async -> DSImageBox? {
        guard let data = await fetchData(url) else { return nil }
        if Task.isCancelled { return nil }
        guard let decoded = ImagePipeline.decode(data, bucket: bucket) else { return nil }
        memory.setObject(decoded.box, forKey: key as NSString, cost: decoded.box.cost)
        if let traits = decoded.traits {
            traitsCache.setObject(DSTraitsBox(traits), forKey: url.absoluteString as NSString)
        }
        return decoded.box
    }

    private func fetchData(_ url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url, options: .mappedIfSafe) }
        if let cached = readDisk(url) { return cached }
        let route = route(for: url)
        guard route.isProvider else {
            if Task.isCancelled { return nil }
            return await download(url, route: route)
        }
        if hasFreshMissMarker(url) || isPaused(route.limiterKey) || Task.isCancelled { return nil }
        await gate.acquire(route.limiterKey)
        let data = await download(url, route: route)
        await gate.release(route.limiterKey)
        return data
    }

    private func download(_ url: URL, route: DSRoute) async -> Data? {
        let operation: @Sendable () async throws -> DSFetchResult = {
            try Task.checkCancellation()
            // Another load may have stored it while we waited for a slot: never ask the server twice.
            if let cached = self.readDisk(url) {
                return DSFetchResult(data: cached, status: 200, fromDisk: true, skipped: false)
            }
            if route.isProvider && self.isPaused(route.limiterKey) {
                return DSFetchResult(data: nil, status: 0, fromDisk: false, skipped: true)
            }
            return try await self.request(url)
        }
        let result: DSFetchResult
        do {
            if let limiter = route.limiter {
                result = try await limiter.run(host: route.limiterKey, operation)
            } else {
                result = try await operation()
            }
        } catch {
            if !Task.isCancelled && !ImagePipeline.isCancellation(error) {
                noteFailure(url: url, route: route, status: nil, undecodable: false)
            }
            return nil
        }
        if result.fromDisk { return result.data }
        if result.skipped { return nil }
        guard let data = result.data, (200..<300).contains(result.status) else {
            noteFailure(url: url, route: route, status: result.status, undecodable: false)
            return nil
        }
        guard ImagePipeline.looksLikeImage(data) else {
            noteFailure(url: url, route: route, status: result.status, undecodable: true)
            return nil
        }
        writeDisk(data, for: url, provider: route.isProvider)
        noteSuccess(route)
        return data
    }

    private func request(_ url: URL) async throws -> DSFetchResult {
        let (activeSession, agent) = currentSession()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await activeSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return DSFetchResult(data: data, status: status, fromDisk: false, skipped: false)
    }

    private func currentSession() -> (URLSession, String) {
        lock.lock()
        defer { lock.unlock() }
        return (session, userAgent)
    }

    // MARK: - Routing & safety

    private func route(for url: URL) -> DSRoute {
        let host = (url.host ?? "").lowercased()
        let hostPort = url.port.map { "\(host):\($0)" } ?? host
        lock.lock()
        defer { lock.unlock() }
        if let entry = providerIndex[hostPort] ?? providerIndex[host] {
            return DSRoute(limiterKey: entry, isProvider: true, limiter: limiter)
        }
        if isConfigured {
            return DSRoute(limiterKey: host, isProvider: false, limiter: limiter)
        }
        // Not configured yet: treat unknown hosts like an IPTV panel (one at a time, ≥ 1 s apart).
        if ImagePipeline.isWellKnownImageHost(host) {
            return DSRoute(limiterKey: host, isProvider: false, limiter: nil)
        }
        return DSRoute(limiterKey: hostPort, isProvider: true, limiter: nil)
    }

    private func isNegative(_ url: URL) -> Bool {
        let key = url.absoluteString
        lock.lock()
        defer { lock.unlock() }
        guard let until = negative[key] else { return false }
        if until > Date() { return true }
        negative[key] = nil
        return false
    }

    private func isPaused(_ hostKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = pausedHosts[hostKey] else { return false }
        if until > Date() { return true }
        pausedHosts[hostKey] = nil
        return false
    }

    private func noteSuccess(_ route: DSRoute) {
        guard route.isProvider else { return }
        lock.lock()
        failureStreaks[route.limiterKey] = nil
        lock.unlock()
    }

    private func noteFailure(url: URL, route: DSRoute, status: Int?, undecodable: Bool) {
        let now = Date()
        let key = url.absoluteString
        let definitiveMiss = undecodable || (status.map { ImagePipeline.isDefinitiveMiss($0) } ?? false)
        var writeMarker = false
        lock.lock()
        if definitiveMiss {
            negative[key] = now.addingTimeInterval(route.isProvider ? ImagePipeline.providerMissTTL : 1800)
            writeMarker = route.isProvider
        } else if route.isProvider {
            let streak = (failureStreaks[route.limiterKey] ?? 0) + 1
            failureStreaks[route.limiterKey] = streak
            if let status, ImagePipeline.isProtectiveStatus(status) {
                let pause: TimeInterval = (status == 401 || status == 403) ? 1800 : 600
                pausedHosts[route.limiterKey] = now.addingTimeInterval(pause)
            } else if streak >= 2 {
                pausedHosts[route.limiterKey] = now.addingTimeInterval(300)
            }
            negative[key] = now.addingTimeInterval(600)
        } else {
            negative[key] = now.addingTimeInterval(status == nil ? 90 : 600)
        }
        lock.unlock()
        if writeMarker { writeMissMarker(url) }
    }

    private static func isDefinitiveMiss(_ status: Int) -> Bool {
        (400..<500).contains(status) && ![401, 403, 407, 408, 429, 458].contains(status)
    }

    private static func isProtectiveStatus(_ status: Int) -> Bool {
        [401, 403, 429, 458, 509].contains(status) || (500..<600).contains(status)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let tunaError = error as? TunaError, tunaError == .cancelled { return true }
        return false
    }

    private static func isWellKnownImageHost(_ host: String) -> Bool {
        wellKnownImageHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func normalizedHostEntry(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.contains("://"), let url = URL(string: value), let host = url.host?.lowercased(), !host.isEmpty {
            value = url.port.map { "\(host):\($0)" } ?? host
        }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        return value.isEmpty ? nil : value
    }

    private static func stripPort(_ entry: String) -> String {
        guard !entry.hasSuffix("]"), let colon = entry.lastIndex(of: ":") else { return entry }
        let port = entry[entry.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy({ $0.isNumber }) else { return entry }
        return String(entry[..<colon])
    }

    private static func isLoadable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private static func memoryKey(url: URL, bucket: DSPixelBucket) -> String {
        "\(url.absoluteString)#\(bucket.width)x\(bucket.height)"
    }

    private static func makeSession(userAgent: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpShouldUsePipelining = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: configuration)
    }

    // MARK: - Disk cache

    private static func fileName(for url: URL) -> String { DSHash.hex128(url.absoluteString) }

    private func readDisk(_ url: URL) -> Data? {
        let name = ImagePipeline.fileName(for: url)
        for prefix in ["p-", "c-"] {
            let file = cacheDirectory.appendingPathComponent(prefix + name)
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty { return data }
        }
        return nil
    }

    private func writeDisk(_ data: Data, for url: URL, provider: Bool) {
        let file = cacheDirectory.appendingPathComponent((provider ? "p-" : "c-") + ImagePipeline.fileName(for: url))
        guard ensureDirectory() else { return }
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            // The directory may have been cleared under us: recreate once and retry.
            lock.lock()
            directoryReady = false
            lock.unlock()
            if ensureDirectory() { try? data.write(to: file, options: .atomic) }
        }
        if !provider { scheduleTrim() }
    }

    private func ensureDirectory() -> Bool {
        lock.lock()
        let ready = directoryReady
        lock.unlock()
        if ready { return true }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            lock.lock()
            directoryReady = true
            lock.unlock()
            return true
        } catch {
            return false
        }
    }

    private func missMarkerURL(_ url: URL) -> URL {
        cacheDirectory.appendingPathComponent("m-" + ImagePipeline.fileName(for: url))
    }

    private func hasFreshMissMarker(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: missMarkerURL(url).path),
              let date = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) < ImagePipeline.providerMissTTL
    }

    private func writeMissMarker(_ url: URL) {
        guard ensureDirectory() else { return }
        try? Data().write(to: missMarkerURL(url), options: .atomic)
    }

    private func scheduleTrim() {
        lock.lock()
        let shouldSchedule = !trimScheduled
        trimScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) {
            self.trimCDNCache()
        }
    }

    /// Provider panel images ("p-") are never evicted; CDN images ("c-") are trimmed oldest-first.
    private func trimCDNCache() {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                       includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return }
        var entries: [DSDiskEntry] = []
        var total: Int64 = 0
        for file in files where file.lastPathComponent.hasPrefix("c-") {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            entries.append(DSDiskEntry(url: file, size: size, date: values?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > ImagePipeline.cdnCacheLimit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            if total <= ImagePipeline.cdnCacheTarget { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: - Decoding

    private static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           CGImageSourceGetType(source) != nil {
            return true
        }
        return UIImage(data: data) != nil
    }

    private static func decode(_ data: Data, bucket: DSPixelBucket) -> DSDecoded? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0 {
            let maxPixel = thumbnailMaxPixel(source: source, bucket: bucket)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let image = UIImage(cgImage: cgImage, scale: 2, orientation: .up)
                let box = DSImageBox(image: image, cost: max(1, cgImage.bytesPerRow * cgImage.height))
                return DSDecoded(box: box, traits: sampleTraits(cgImage))
            }
        }
        // Formats ImageIO does not handle but UIImage does.
        if let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
            let cost = Int(image.size.width * image.size.height * 4)
            return DSDecoded(box: DSImageBox(image: image, cost: max(1, cost)), traits: nil)
        }
        return nil
    }

    /// Longest-side pixel size that makes the decoded image cover the bucket (aspect fill), never upscaling.
    private static func thumbnailMaxPixel(source: CGImageSource, bucket: DSPixelBucket) -> Int {
        let fallback = max(bucket.width, bucket.height)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return fallback }
        var sourceWidth = width
        var sourceHeight = height
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&sourceWidth, &sourceHeight)
        }
        let scale = max(Double(bucket.width) / sourceWidth, Double(bucket.height) / sourceHeight)
        let longest = max(sourceWidth, sourceHeight)
        let needed = (longest * scale).rounded(.up)
        return Int(min(max(needed, 1), longest))
    }

    /// 12×12 sample: saturation-weighted average colour, mean luminance and transparency share.
    private static func sampleTraits(_ image: CGImage) -> Traits? {
        let side = 12
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weightSum = 0.0
        var lumaSum = 0.0
        var alphaSum = 0.0
        var transparent = 0
        let count = side * side
        for index in 0..<count {
            let offset = index * 4
            let alpha = Double(pixels[offset + 3]) / 255
            if alpha < 0.08 {
                transparent += 1
                continue
            }
            let r = min(1, Double(pixels[offset]) / 255 / alpha)
            let g = min(1, Double(pixels[offset + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[offset + 2]) / 255 / alpha)
            let saturation = max(r, g, b) - min(r, g, b)
            let weight = alpha * (0.12 + saturation * 2.4)
            red += r * weight
            green += g * weight
            blue += b * weight
            weightSum += weight
            lumaSum += (0.2126 * r + 0.7152 * g + 0.0722 * b) * alpha
            alphaSum += alpha
        }
        guard weightSum > 0, alphaSum > 0 else { return nil }
        return Traits(red: min(1, red / weightSum),
                      green: min(1, green / weightSum),
                      blue: min(1, blue / weightSum),
                      luminance: lumaSum / alphaSum,
                      hasTransparency: Double(transparent) / Double(count) > 0.12)
    }
}

// MARK: - Helpers

/// Target size rounded up to a small set of steps so tiny layout changes reuse cached decodes.
struct DSPixelBucket: Hashable {
    let width: Int
    let height: Int

    init(_ size: CGSize) {
        width = DSPixelBucket.step(size.width)
        height = DSPixelBucket.step(size.height)
    }

    private static let steps: [Int] = [32, 64, 96, 128, 192, 256, 320, 384, 512, 640, 768, 1024, 1280, 1536, 2048, 2560, 3072, 4096]

    static func step(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 32 }
        let needed = Int(value.rounded(.up))
        return steps.first(where: { $0 >= needed }) ?? 4096
    }
}

private final class DSImageBox: @unchecked Sendable {
    let image: UIImage
    let cost: Int

    init(image: UIImage, cost: Int) {
        self.image = image
        self.cost = cost
    }
}

private final class DSTraitsBox {
    let traits: ImagePipeline.Traits

    init(_ traits: ImagePipeline.Traits) { self.traits = traits }
}

private struct DSDecoded {
    let box: DSImageBox
    let traits: ImagePipeline.Traits?
}

private struct DSInflightLoad {
    let task: Task<DSImageBox?, Never>
    let token: UUID
    var waiters: Int
}

private struct DSLoadTicket {
    let task: Task<DSImageBox?, Never>
    let token: UUID
}

private struct DSFetchResult: Sendable {
    var data: Data?
    var status: Int
    var fromDisk: Bool
    var skipped: Bool
}

private struct DSRoute: Sendable {
    var limiterKey: String
    var isProvider: Bool
    var limiter: HostLimiter?
}

private struct DSDiskEntry {
    let url: URL
    let size: Int64
    let date: Date
}

/// Belt and braces on top of HostLimiter for IPTV panel hosts: one image request at a time per host, starts at
/// least ~1 s apart, FIFO. Ownership is handed directly from one request to the next.
private actor DSProviderImageGate {
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var lastStart: [String: Date] = [:]
    private let spacing: TimeInterval = 1.05

    func acquire(_ key: String) async {
        if busy.contains(key) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiting[key, default: []].append(continuation)
            }
        } else {
            busy.insert(key)
        }
        if let last = lastStart[key] {
            let wait = spacing - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        lastStart[key] = Date()
    }

    func release(_ key: String) {
        if var queue = waiting[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            waiting[key] = nil
            busy.remove(key)
        }
    }
}
