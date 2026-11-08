import BiparaCore
import Foundation

/// Session-local active time. Clock instants never enter a portable document.
public struct TranslationElapsed: Equatable, Sendable {
    private var jobID: UUID?
    private var accumulated: Duration = .zero
    private var started: ContinuousClock.Instant?
    public private(set) var hasActivity = false
    public var sinceOpen = false

    public init() {}

    mutating func observe(job: JobModel, now: ContinuousClock.Instant) {
        let id = job.snapshot?.jobID
        if id != jobID {
            jobID = id; accumulated = .zero; started = nil; hasActivity = false
        }
        if [.queued, .running].contains(job.state), id != nil {
            if started == nil { started = now; hasActivity = true }
        } else if let start = started {
            accumulated += start.duration(to: now); started = nil
        }
    }

    public func seconds(at now: ContinuousClock.Instant = .now) -> Int {
        max(0, Int((accumulated + (started?.duration(to: now) ?? .zero)).components.seconds))
    }

    public static func format(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm %02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh %02dm", seconds / 3600, seconds / 60 % 60)
    }
}
