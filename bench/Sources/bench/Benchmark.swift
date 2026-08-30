import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import CStrafe

/// Which switch mechanism a run measures.
enum BenchMode: String, Sendable {
    case native  // synthetic Ctrl+Arrow -> animated Mission Control switch
    case strafe  // strafe_post_switch_gesture -> instant dock-swipe
}

/// Outcome of a single trial.
struct TrialResult: Sendable {
    let index: Int
    let direction: SwitchDirection
    /// Time-to-interactivity: first destination click delivery − T0, in ms.
    /// `nil` on timeout (recorded as a failure, excluded from stats).
    let interactivityMs: Double?
    /// activeSpaceDidChange − T0, in ms (reference only). `nil` if not observed.
    let spaceChangeMs: Double?
    /// How many probe clicks we posted before the first hit (or timeout).
    let clicksPosted: Int
    /// How many probe clicks the destination window actually received.
    let destinationHits: Int
    /// Clicks that landed on the SOURCE window post-arm (excluded, reported).
    let sourceHits: Int

    var timedOut: Bool { interactivityMs == nil }
}

/// Main-actor box for the last activeSpaceDidChange timestamp.
@MainActor
final class SpaceChangeStamp {
    var value: CFTimeInterval?
}

/// Runs the trial loop for one mode and emits the table + CSV + summary.
@MainActor
final class Benchmark {
    private let mode: BenchMode
    private let trials: Int
    private let controller: DemoWindowController
    private let recorder: HitRecorder

    /// Probe cadence (SPEC: post a probe click every 4 ms).
    private let probeIntervalMs: Double = 4
    /// Settle time between trials (SPEC: 1.5 s so state returns home).
    private let settleBetweenTrials: TimeInterval = 1.5
    /// Per-trial probe timeout (SPEC: 3 s).
    private let probeTimeout: TimeInterval = 3.0

    private let clickSource = CGEventSource(stateID: .hidSystemState)

    init(mode: BenchMode, trials: Int, controller: DemoWindowController, recorder: HitRecorder) {
        self.mode = mode
        self.trials = trials
        self.controller = controller
        self.recorder = recorder
    }

    /// Execute warmup + `trials` measured trials, print the table, write CSV,
    /// print the summary. Returns the summary so callers can reuse it.
    @discardableResult
    func run(machine: MachineInfo) -> Summary {
        // Observe activeSpaceDidChange for the reference timing. The stamp lives
        // in a main-actor box so the .main-queue observer can write it without
        // tripping strict-concurrency capture rules.
        let stamp = SpaceChangeStamp()
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stamp.value = CACurrentMediaTime() }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }

        // 1 warmup trial, discarded (SPEC).
        _ = runTrial(index: 0, direction: .right, spaceChangeStamp: { stamp.value },
                     resetStamp: { stamp.value = nil })

        var results: [TrialResult] = []
        results.reserveCapacity(trials)

        for i in 0..<trials {
            // Alternate direction so state returns home (SPEC): even trials go
            // right (from space 1 -> 2), odd trials go left (2 -> 1).
            let direction: SwitchDirection = (i % 2 == 0) ? .right : .left
            let result = runTrial(
                index: i + 1, direction: direction,
                spaceChangeStamp: { stamp.value },
                resetStamp: { stamp.value = nil }
            )
            results.append(result)
            // Settle so the next trial starts from a quiesced state.
            RunLoop.current.run(until: Date().addingTimeInterval(settleBetweenTrials))
        }

        printTable(results)
        writeCSV(results, machine: machine)
        let summary = Summary(mode: mode, results: results)
        summary.print(machine: machine)
        return summary
    }

    /// One trial. `direction` is the switch to trigger; the destination space is
    /// the opposite of where we currently are (right -> space 2, left -> space 1).
    private func runTrial(
        index: Int,
        direction: SwitchDirection,
        spaceChangeStamp: () -> CFTimeInterval?,
        resetStamp: () -> Void
    ) -> TrialResult {
        let destination: DemoSpace = direction == .right ? .two : .one
        recorder.arm(destination: destination)
        resetStamp()

        // T0 is captured immediately before triggering the switch.
        let t0 = CACurrentMediaTime()
        switch mode {
        case .native:
            EventPosting.postNativeSwitch(direction)
        case .strafe:
            // Exact app code path (CStrafe poster).
            StrafeSwitch.perform(direction)
        }

        // Immediately begin probing the destination screen center. We drive the
        // probe from the main run loop so click delivery (also main) can be
        // observed between posts.
        let point = controller.destinationClickPointCG
        var clicksPosted = 0
        let deadline = t0 + probeTimeout

        while recorder.firstHit == nil {
            let now = CACurrentMediaTime()
            if now >= deadline { break }
            EventPosting.postProbeClick(at: point, source: clickSource)
            clicksPosted += 1
            // Pump the run loop briefly so the click can be delivered to our
            // window and the local monitor can stamp it, then wait out the
            // 4 ms cadence.
            RunLoop.current.run(until: Date().addingTimeInterval(probeIntervalMs / 1000.0))
        }

        let firstHit = recorder.firstHit
        let interactivityMs = firstHit.map { ($0 - t0) * 1000.0 }
        let spaceChangeMs = spaceChangeStamp().map { ($0 - t0) * 1000.0 }

        let result = TrialResult(
            index: index,
            direction: direction,
            interactivityMs: interactivityMs,
            spaceChangeMs: spaceChangeMs,
            clicksPosted: clicksPosted,
            destinationHits: recorder.destinationHitCount,
            sourceHits: recorder.sourceHitCount
        )
        recorder.disarm()
        return result
    }

    // MARK: - Output

    private func printTable(_ results: [TrialResult]) {
        print("")
        print("trial  dir    interactive(ms)  spaceChange(ms)  clicksPosted  destHits  srcHits")
        for r in results {
            let inter = r.interactivityMs.map { String(format: "%.1f", $0) } ?? "TIMEOUT"
            let space = r.spaceChangeMs.map { String(format: "%.1f", $0) } ?? "-"
            let dir = r.direction == .right ? "right" : "left "
            print(String(
                format: "%4d   %@  %15@  %15@  %12d  %8d  %7d",
                r.index, dir, inter as NSString, space as NSString,
                r.clicksPosted, r.destinationHits, r.sourceHits
            ))
        }
    }

    private func writeCSV(_ results: [TrialResult], machine: MachineInfo) {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("results")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(mode.rawValue)-\(trials).csv")

        var lines: [String] = []
        // Machine-info header as CSV comments (redacted — see MachineInfo).
        lines.append("# mode,\(mode.rawValue)")
        for line in machine.block.split(separator: "\n") {
            lines.append("# \(line)")
        }
        lines.append("trial,direction,interactive_ms,space_change_ms,clicks_posted,dest_hits,src_hits,timed_out")
        for r in results {
            let inter = r.interactivityMs.map { String(format: "%.3f", $0) } ?? ""
            let space = r.spaceChangeMs.map { String(format: "%.3f", $0) } ?? ""
            let dir = r.direction == .right ? "right" : "left"
            lines.append("\(r.index),\(dir),\(inter),\(space),\(r.clicksPosted),\(r.destinationHits),\(r.sourceHits),\(r.timedOut)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        print("\nwrote \(url.path)")
    }
}

/// Median / p90 / min / max over the non-timed-out trials.
struct Summary: Sendable {
    let mode: BenchMode
    let median: Double?
    let p90: Double?
    let min: Double?
    let max: Double?
    let valid: Int
    let timeouts: Int

    init(mode: BenchMode, results: [TrialResult]) {
        self.mode = mode
        let values = results.compactMap { $0.interactivityMs }.sorted()
        self.valid = values.count
        self.timeouts = results.count - values.count
        if values.isEmpty {
            median = nil; p90 = nil; min = nil; max = nil
        } else {
            median = Summary.percentile(values, 0.50)
            p90 = Summary.percentile(values, 0.90)
            min = values.first
            max = values.last
        }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    func print(machine: MachineInfo) {
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "n/a" }
        Swift.print("")
        Swift.print("=== \(mode.rawValue) summary (\(valid) valid, \(timeouts) timeout) ===")
        Swift.print("median=\(fmt(median)) ms  p90=\(fmt(p90)) ms  min=\(fmt(min)) ms  max=\(fmt(max)) ms")
    }
}
