import Foundation
import Dispatch

/// Order-preserving parallel map for pure per-item work (parsing names). Results are in input order, so callers
/// stay deterministic. Small inputs run inline.
enum ParallelMap {
    static func map<T>(count: Int, minimumChunk: Int = 1024, _ body: (Int) -> T) -> [T] {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard count >= minimumChunk * 2, cores > 1 else {
            var out: [T] = []
            out.reserveCapacity(count)
            var i = 0
            while i < count {
                out.append(body(i))
                i += 1
            }
            return out
        }
        let chunks = min(cores * 4, max(1, count / minimumChunk))
        var slots = [T?](repeating: nil, count: count)
        slots.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let start = chunk * count / chunks
                let end = (chunk + 1) * count / chunks
                var i = start
                while i < end {
                    (base + i).pointee = body(i)
                    i += 1
                }
            }
        }
        return slots.map { $0! }
    }
}
