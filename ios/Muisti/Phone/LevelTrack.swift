import CoreMotion
import Foundation
import os

/// How far up or down the user has moved, from the phone's barometer. This is what lets Muisti
/// relate things to each other in height: the exit sign was read at one level, the user took
/// the lift and is now 14 m above it. GPS says nothing indoors and iOS knows the floor only in
/// a few mapped buildings; air pressure changes with every storey.
///
/// Air pressure also changes with the weather (a few metres an hour), so the raw height is not
/// kept. `level` follows only real movement: a change slower than `driftRate` is taken as
/// weather, and the level moves once the height has really left it by `step` metres. Levels are
/// comparable inside one unbroken run of readings (`since`); a gap of more than ten minutes
/// starts a new run, and records from before it are not compared.
final class LevelTrack: @unchecked Sendable {
    static let shared = LevelTrack()

    private struct State {
        var level = 0.0          // metres, movement only
        var weather = 0.0        // the part of the raw height taken as weather
        var lastRaw: Double?
        var lastAt = Date.distantPast
        var since = Date.distantPast
        var history: [(at: Date, level: Double)] = []
        var savedAt = Date.distantPast
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()
    private var started = false

    /// Weather moves the reading slower than this (m/s); stairs are thirty times faster.
    static let driftRate = 0.01
    /// The height must leave the level by this much before the level follows.
    static let step = 1.0
    /// Readings further apart than this are two separate runs.
    static let gap: TimeInterval = 600
    private static let keep: TimeInterval = 3 * 3600

    private init() {
        let d = UserDefaults.standard
        let at = Date(timeIntervalSince1970: d.double(forKey: "level.at"))
        // Picked up where the last run stopped, when that was minutes ago (the app restarted).
        if Date().timeIntervalSince(at) < Self.gap, d.object(forKey: "level.raw") != nil {
            let level = d.double(forKey: "level.level"), raw = d.double(forKey: "level.raw")
            let since = Date(timeIntervalSince1970: d.double(forKey: "level.since"))
            state.withLock { s in
                s.level = level
                s.lastRaw = raw
                s.weather = raw - level
                s.lastAt = at
                s.since = since
                s.history = [(at, level)]
            }
        }
    }

    func start() {
        guard !started, CMAltimeter.isRelativeAltitudeAvailable() else { return }
        started = true
        queue.maxConcurrentOperationCount = 1
        altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            // Height in the standard atmosphere from the pressure itself (kPa): unlike the
            // relative altitude it means the same after the app restarts.
            let raw = 44_330 * (1 - pow(data.pressure.doubleValue / 101.325, 0.1903))
            self.feed(raw: raw, at: Date())
        }
    }

    /// One barometer reading (also what a test or the remote driver feeds in).
    func feed(raw: Double, at: Date) {
        state.withLock { s in
            defer { s.lastRaw = raw; s.lastAt = at }
            guard let last = s.lastRaw, at.timeIntervalSince(s.lastAt) <= Self.gap, at >= s.lastAt else {
                // A new run: nothing before it can be compared with what follows.
                s.weather = raw - s.level
                s.since = at
                s.history = [(at, s.level)]
                return
            }
            _ = last
            let dt = at.timeIntervalSince(s.lastAt)
            let off = raw - s.weather - s.level
            if abs(off) >= Self.step {
                s.level += off
            } else {
                s.weather += max(-Self.driftRate * dt, min(Self.driftRate * dt, off))
            }
            if s.history.last.map({ at.timeIntervalSince($0.at) >= 2 || abs($0.level - s.level) >= Self.step }) ?? true {
                s.history.append((at, s.level))
                if let first = s.history.first, at.timeIntervalSince(first.at) > Self.keep { s.history.removeFirst(s.history.count / 4) }
            }
            if at.timeIntervalSince(s.savedAt) >= 30 {
                s.savedAt = at
                let d = UserDefaults.standard
                d.set(at.timeIntervalSince1970, forKey: "level.at")
                d.set(raw, forKey: "level.raw")
                d.set(s.level, forKey: "level.level")
                d.set(s.since.timeIntervalSince1970, forKey: "level.since")
            }
        }
    }

    #if DEBUG
    private var simulated: Task<Void, Never>?
    /// Remote driver / tests: moves the user `by` metres over `seconds`, then holds the height
    /// (a simulator has no barometer).
    func simulate(by: Double, seconds: Double) async {
        simulated?.cancel()
        let from = state.withLock { $0.lastRaw } ?? 0
        if state.withLock({ $0.lastRaw }) == nil { feed(raw: from, at: Date()) }
        let steps = max(1, Int(seconds * 4))
        for i in 1...steps {
            try? await Task.sleep(for: .milliseconds(250))
            feed(raw: from + by * Double(i) / Double(steps), at: Date())
        }
        simulated = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.feed(raw: from + by, at: Date())
            }
        }
    }
    #endif

    /// The level at a moment of the current run (stored with each memory); nil outside it.
    func level(at: Date) -> Double? {
        state.withLock { s in
            guard at >= s.since, at.timeIntervalSince(s.lastAt) < 60, !s.history.isEmpty else { return nil }
            return (s.history.last { $0.at <= at } ?? s.history[0]).level
        }
    }

    /// How much higher (+) or lower (−) the user is now than at `then` with level `level`;
    /// nil when the two are not from the same run.
    func above(level: Double?, seenAt then: Date, now: Date = Date()) -> Double? {
        guard let level else { return nil }
        return state.withLock { s in
            guard then >= s.since, now.timeIntervalSince(s.lastAt) < 60 else { return nil }
            return s.level - level
        }
    }

    /// The user's own vertical movement lately, as text for the model: each climb or descent
    /// of the last hour with its time, oldest first.
    func nowText(now: Date = Date()) -> String? {
        let (history, since, fresh) = state.withLock { ($0.history, $0.since, now.timeIntervalSince($0.lastAt) < 60) }
        guard fresh, history.count > 1 else { return fresh ? "height (phone barometer): no level change since tracking began" : nil }
        let recent = history.filter { now.timeIntervalSince($0.at) <= 3600 }
        guard let first = recent.first else { return nil }
        // Runs of movement in one direction, separated by 20 s without a change.
        var moves: [(from: Date, to: Date, by: Double)] = []
        var start = first, previous = first, lastChange = first.at
        func close() {
            let by = previous.level - start.level
            if abs(by) >= 2 { moves.append((start.at, lastChange, by)) }
        }
        for sample in recent.dropFirst() {
            if sample.level != previous.level {
                let sameWay = (sample.level - previous.level) * (previous.level - start.level) >= 0
                if !sameWay || sample.at.timeIntervalSince(lastChange) > 20 {
                    close()
                    start = previous
                }
                lastChange = sample.at
            }
            previous = sample
        }
        close()
        let tracked = max(1, Int(now.timeIntervalSince(max(since, first.at)) / 60))
        guard !moves.isEmpty else { return "height (phone barometer): the user has stayed on one level for the last \(tracked) min" }
        let lines = moves.suffix(6).map { move -> String in
            let ago = max(0, Int(now.timeIntervalSince(move.to) / 60))
            let seconds = max(1, Int(move.to.timeIntervalSince(move.from)))
            return "went \(move.by > 0 ? "up" : "down") about \(Int(abs(move.by).rounded())) m in \(seconds) s, \(ago) min ago"
        }
        let total = (recent.last?.level ?? 0) - first.level
        return "height (phone barometer; a storey is roughly 3 to 4 m): " + lines.joined(separator: "; ")
            + ". Now about \(Int(abs(total).rounded())) m \(total >= 0 ? "above" : "below") where the user was \(tracked) min ago"
    }
}
