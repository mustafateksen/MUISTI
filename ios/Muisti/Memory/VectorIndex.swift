import Accelerate
import Foundation

/// In-memory vector index: unit-normalised float32 rows in one contiguous row-major matrix.
/// Cosine top-k over every memory is a single vDSP matrix–vector product (a week of signs,
/// a few thousand × 2048, is ~1–2 ms on an A-series chip), so no ANN structure is needed.
/// SQLite stays the source of truth; the index is rebuilt from it at launch and on a model change.
struct VectorIndex: Sendable {
    private(set) var dimension = 0
    private var ids: [Int64] = []
    private var rowOf: [Int64: Int] = [:]
    private var matrix: [Float] = []

    var count: Int { ids.count }

    mutating func removeAll() {
        dimension = 0
        ids.removeAll()
        rowOf.removeAll()
        matrix.removeAll()
    }

    /// Adds or replaces `id`. Vectors of another dimension (another model) are ignored.
    mutating func upsert(_ id: Int64, _ vector: [Float]) {
        guard !vector.isEmpty else { return }
        if dimension == 0 { dimension = vector.count }
        guard vector.count == dimension, let unit = Self.unit(vector) else { return }
        if let row = rowOf[id] {
            matrix.replaceSubrange(row * dimension ..< (row + 1) * dimension, with: unit)
        } else {
            rowOf[id] = ids.count
            ids.append(id)
            matrix.append(contentsOf: unit)
        }
    }

    /// Swap-with-last removal, O(dimension).
    mutating func remove(_ id: Int64) {
        guard let row = rowOf.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if row != last {
            let moved = ids[last]
            ids[row] = moved
            rowOf[moved] = row
            let d = dimension
            matrix.withUnsafeMutableBufferPointer { m in
                for k in 0..<d { m[row * d + k] = m[last * d + k] }
            }
        }
        ids.removeLast()
        matrix.removeLast(dimension)
        if ids.isEmpty { dimension = 0 }
    }

    /// Top `k` by cosine, optionally restricted to `allowed` ids (time/place window).
    func search(_ query: [Float], k: Int, allowed: Set<Int64>? = nil) -> [(id: Int64, cosine: Float)] {
        guard dimension > 0, query.count == dimension, !ids.isEmpty, let q = Self.unit(query) else { return [] }
        let n = ids.count
        var scores = [Float](repeating: 0, count: n)
        matrix.withUnsafeBufferPointer { m in
            q.withUnsafeBufferPointer { qp in
                scores.withUnsafeMutableBufferPointer { s in
                    // (n × d) · (d × 1) → (n × 1)
                    vDSP_mmul(m.baseAddress!, 1, qp.baseAddress!, 1, s.baseAddress!, 1,
                              vDSP_Length(n), 1, vDSP_Length(dimension))
                }
            }
        }
        var hits: [(id: Int64, cosine: Float)] = []
        hits.reserveCapacity(allowed?.count ?? n)
        for i in 0..<n where allowed?.contains(ids[i]) ?? true {
            hits.append((ids[i], scores[i]))
        }
        hits.sort { $0.cosine > $1.cosine }
        return Array(hits.prefix(k))
    }

    private static func unit(_ v: [Float]) -> [Float]? {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        guard sumSquares > 0, sumSquares.isFinite else { return nil }
        return vDSP.divide(v, sumSquares.squareRoot())
    }
}
