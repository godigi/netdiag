import Foundation

/// Fetches `netdiag --show=<id>` and remembers the last few.
///
/// One fetch is a bash start plus a scan of a multi-megabyte JSONL file —
/// around 300 ms — which is why the view shows a spinner rather than
/// pretending a push is free, and why there is a cache at all. The bound is
/// 20 because a detail is the *complete* stored record: 20 covers flicking
/// through a day's checks and coming back, without the app quietly
/// accumulating the whole history in memory as the user browses.
///
/// `HistoryStore` is untouched by any of this. The run list is answered
/// entirely from `--history`, which is already in memory; only opening one
/// check costs a process.
@MainActor
@Observable
final class RunDetailStore {

    /// The id currently being fetched, for the spinner. Not a bool: two
    /// pushes in quick succession must show the spinner against the row
    /// being opened, not against whichever one asked first.
    private(set) var loadingID: String?
    private(set) var lastError: String?

    private var cache: [String: RunDetail] = [:]
    /// Least-recently-used first.
    private var order: [String] = []
    private var inFlight: [String: Task<RunDetail, Error>] = [:]
    private let capacity = 20

    func cached(_ id: String) -> RunDetail? { cache[id] }

    func detail(for id: String) async throws -> RunDetail {
        if let hit = cache[id] {
            touch(id)
            return hit
        }
        // A view re-rendering mid-fetch, or a back-then-forward, must not
        // spawn a second bash for a record already on its way.
        let task = inFlight[id] ?? Task { try await NetdiagRunner.show(id: id) }
        inFlight[id] = task
        loadingID = id
        defer {
            inFlight[id] = nil
            if loadingID == id { loadingID = nil }
        }
        do {
            let detail = try await task.value
            lastError = nil
            store(detail, for: id)
            return detail
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func store(_ detail: RunDetail, for id: String) {
        cache[id] = detail
        touch(id)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
    }

    private func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}
