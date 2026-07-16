import Foundation

/// Lays the clips' trim windows end-to-end into one 24h timeline and assigns
/// each of the N output frames a point on it — so the day flows clip 1 → clip N,
/// with each clip getting frames in proportion to its trim duration.
enum FrameTimeline {
    /// Per-clip sample lists, aligned to `clips` by index.
    static func distribute(clips: [ResolvedClip], frameCount: Int) -> [[FrameSample]] {
        let durations = clips.map(\.duration)
        let total = durations.reduce(0, +)
        guard total > 0, frameCount > 0 else { return clips.map { _ in [] } }

        // Cumulative start offset of each clip on the combined timeline (n is tiny).
        let offsets = durations.indices.map { durations[..<$0].reduce(0, +) }

        let assignments = (0..<frameCount).map { k -> (clip: Int, sample: FrameSample) in
            let global = (Double(k) + 0.5) / Double(frameCount) * total
            let clip = clips.indices.last(where: { offsets[$0] <= global }) ?? 0
            let localInTrim = min(global - offsets[clip], durations[clip] - 0.001)
            let time = clips[clip].start + max(0, localInTrim)
            return (clip, FrameSample(index: k, time: time))
        }

        let grouped = Dictionary(grouping: assignments, by: \.clip).mapValues { $0.map(\.sample) }
        return clips.indices.map { grouped[$0] ?? [] }
    }
}
