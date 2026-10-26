import Foundation
import MeowModels
import Observation

/// How an event went.
enum LogbookLevel: String, Decodable, Sendable {
    case info, warning, error
}

/// One logbook entry, as `meow_logbook_read` serves it.
struct LogbookEntry: Decodable, Equatable, Identifiable, Sendable {
    /// Identity and order: newest first.
    let id: UInt64
    /// First occurrence.
    let time: Date
    /// Latest occurrence, once a repeat was folded in.
    let last: Date?
    /// Occurrences folded into this entry.
    let count: UInt32
    let kind: String
    let level: LogbookLevel
    /// What the event is about: a group, provider or listener name.
    let subject: String?
    /// One English sentence; for a folded entry, the latest occurrence's.
    let message: String
    let fields: [String: LogbookField]?
}

/// A recorded field's value, as text.
struct LogbookField: Decodable, Equatable, Sendable {
    let text: String

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            text = string
        } else if let number = try? value.decode(Int64.self) {
            text = String(number)
        } else if let number = try? value.decode(Double.self) {
            text = String(number)
        } else if let flag = try? value.decode(Bool.self) {
            text = String(flag)
        } else if let list = try? value.decode([LogbookField].self) {
            text = list.map(\.text).joined(separator: ", ")
        } else {
            text = "…"
        }
    }
}

/// A page of the logbook, newest first.
struct LogbookPage: Sendable {
    var entries: [LogbookEntry] = []
    /// The latest write: pass it as `since` to ask whether anything followed.
    var rev: UInt64 = 0
    /// Older entries exist past this page.
    var more = false
}

struct LogbookReadError: Error, Sendable {
    let message: String
}

/// Reads the engine's logbook from the App Group (`meow_logbook_read`) in
/// this process, so the page also opens while the VPN is down.
enum LogbookReader {
    /// `kind` is a kind or its area (`config` matches `config.reload`); nil
    /// for every kind.
    static func read(
        before: UInt64 = 0,
        since: UInt64 = 0,
        limit: Int = 0,
        kind: String? = nil,
        in dir: URL = AppGroup.meowConfigDir,
    ) async throws -> LogbookPage {
        let home = dir.path(percentEncoded: false)
        let json = await Task.detached(priority: .utility) {
            answer(home: home, before: before, since: since, limit: limit, kind: kind ?? "")
        }.value
        return try decode(json)
    }

    static func decode(_ json: String) throws -> LogbookPage {
        struct Answer: Decodable {
            var entries: [LogbookEntry]?
            var rev: UInt64?
            var more: Bool?
            var error: String?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseTime(text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "not an RFC 3339 time: \(text)",
                ))
            }
            return date
        }
        let answer: Answer
        do {
            answer = try decoder.decode(Answer.self, from: Data(json.utf8))
        } catch {
            throw LogbookReadError(message: error.localizedDescription)
        }
        if let error = answer.error {
            throw LogbookReadError(message: error)
        }
        return LogbookPage(entries: answer.entries ?? [], rev: answer.rev ?? 0, more: answer.more ?? false)
    }

    /// RFC 3339, with milliseconds unless they are zero.
    private static func parseTime(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    private static func answer(home: String, before: UInt64, since: UInt64, limit: Int, kind: String) -> String {
        let raw: UnsafeMutablePointer<CChar>? = home.withCString { home in
            kind.withCString { kind in
                meow_logbook_read(
                    home,
                    Int64(clamping: before),
                    Int64(clamping: since),
                    Int32(clamping: limit),
                    nil,
                    kind,
                )
            }
        }
        guard let raw else { return "{}" }
        defer { meow_string_free(raw) }
        return String(cString: raw)
    }
}

/// What the page shows: the newest entries of one event, or every entry
/// that matches a search.
struct LogbookFilter: Equatable, Sendable {
    /// The search, trimmed; empty for the newest entries.
    var search = ""
    /// One kind or its area; nil for every event.
    var kind: String?
}

/// Utility > Paw Print: the engine's logbook, newest first — what happened
/// to it, kept across restarts: runs and how they ended, config and
/// provider failures, dialer-proxy switches. Read from the database the
/// engine keeps in the App Group, so it also opens while the VPN is down;
/// polled while shown, re-reading only once something was written.
///
/// One event can be picked, which the engine filters by. It has no text
/// search, so a search reads the whole logbook (a few MiB at most) once and
/// matches locally: every word must appear in the entry's message, subject,
/// details or event name.
@MainActor
@Observable
final class LogbookModel {
    static let pollInterval: Duration = .seconds(2)
    static let pageSize = 100
    /// The engine's largest page.
    static let maxPage = 1000
    /// Typing restarts the search; waiting for a pause reads the logbook
    /// once, not once per key.
    static let debounce: Duration = .milliseconds(300)

    /// The search as typed.
    var query = ""
    /// The event picked in the filter menu; nil for every event.
    var kind: String?

    /// Newest first.
    private(set) var entries: [LogbookEntry] = []
    /// Older entries exist past `entries`; never while searching, which
    /// shows every match.
    private(set) var more = false
    /// The filter `entries` answer.
    private(set) var shown = LogbookFilter()
    /// Why the logbook could not be read; shown only while there is nothing
    /// else to show.
    private(set) var error: String?
    /// False until the first read, so the empty hint does not flash on open.
    private(set) var loaded = false
    /// Changes with every change to `entries`, so a page back that a
    /// re-read overtook is asked for again.
    private(set) var generation = 0

    /// The whole logbook, newest first, with each entry's text to search;
    /// kept while searching.
    private struct Everything: Sendable {
        let entries: [LogbookEntry]
        let texts: [String]
        let rev: UInt64
    }

    /// The logbook's latest write when `entries` was read.
    @ObservationIgnored private var rev: UInt64 = 0
    @ObservationIgnored private var everything: Everything?
    @ObservationIgnored private let read: @Sendable (
        _ before: UInt64,
        _ since: UInt64,
        _ limit: Int,
        _ kind: String?,
    ) async throws -> LogbookPage
    /// The event name shown for a kind, so a search can find it; nil for a
    /// kind without one.
    @ObservationIgnored private let kindName: @Sendable (String) -> String?

    init(
        read: @escaping @Sendable (_ before: UInt64, _ since: UInt64, _ limit: Int, _ kind: String?) async throws
            -> LogbookPage,
        kindName: @escaping @Sendable (String) -> String? = { _ in nil },
    ) {
        self.read = read
        self.kindName = kindName
    }

    convenience init() {
        self.init(
            read: { before, since, limit, kind in
                try await LogbookReader.read(before: before, since: since, limit: limit, kind: kind)
            },
            kindName: { LogbookKinds.label(of: $0) },
        )
    }

    /// The filter the search and the menu ask for.
    var filter: LogbookFilter {
        LogbookFilter(search: query.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
    }

    /// Shows `filter`, then polls until cancelled; the page restarts it
    /// whenever the search or the event changes. Typing waits for a pause;
    /// picking an event does not.
    func run() async {
        let filter = filter
        if !filter.search.isEmpty, filter.search != shown.search {
            try? await Task.sleep(for: Self.debounce)
        }
        while !Task.isCancelled {
            await poll(filter)
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func poll(_ filter: LogbookFilter) async {
        do {
            if filter.search.isEmpty {
                try await pollNewest(filter.kind)
            } else {
                try await pollSearch(filter)
            }
        } catch is CancellationError {
            // Restarted for another filter, which reads for itself.
        } catch {
            guard !Task.isCancelled else { return }
            failed(error, filter)
        }
    }

    /// The page past the oldest entry shown.
    func loadMore() async {
        let filter = shown
        guard more, filter.search.isEmpty, let oldest = entries.last,
              let page = try? await read(oldest.id, 0, Self.pageSize, filter.kind), !Task.isCancelled
        else { return }
        // A re-read while this one ran replaced the list; the page asks
        // again for the new one (`generation`).
        guard shown == filter, entries.last?.id == oldest.id else { return }
        entries += page.entries
        more = page.more
        generation += 1
    }

    /// The newest entries of `kind`, and any pages back shown.
    private func pollNewest(_ kind: String?) async throws {
        everything = nil
        let answers = loaded && shown == LogbookFilter(kind: kind)
        if answers, error == nil, try await unchanged(since: rev) {
            return
        }
        try Task.checkCancellation()
        // As many entries as are shown, so a page back stays on screen.
        let limit = min(max(answers ? entries.count : 0, Self.pageSize), Self.maxPage)
        let page = try await read(0, 0, limit, kind)
        try Task.checkCancellation()
        show(page.entries, more: page.more, rev: page.rev, for: LogbookFilter(kind: kind))
    }

    /// Every entry of `filter.kind` that matches `filter.search`.
    private func pollSearch(_ filter: LogbookFilter) async throws {
        let book: Everything
        if let cached = everything, try await unchanged(since: cached.rev) {
            if loaded, shown == filter, error == nil {
                return
            }
            book = cached
        } else {
            book = try await readEverything()
            try Task.checkCancellation()
            everything = book
        }
        let terms = filter.search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let kind = filter.kind
        let matches = await Task.detached(priority: .userInitiated) {
            Self.matches(in: book, terms: terms, kind: kind)
        }.value
        try Task.checkCancellation()
        show(matches, more: false, rev: book.rev, for: filter)
    }

    /// Whether nothing was written after `rev`: a one-entry read answers
    /// with the latest write.
    private func unchanged(since rev: UInt64) async throws -> Bool {
        try await read(0, rev, 1, nil).rev == rev
    }

    private func readEverything() async throws -> Everything {
        var entries: [LogbookEntry] = []
        // The first page's: a write between pages is read again by the next
        // poll.
        var rev: UInt64 = 0
        var before: UInt64 = 0
        while true {
            let page = try await read(before, 0, Self.maxPage, nil)
            try Task.checkCancellation()
            if before == 0 {
                rev = page.rev
            }
            entries += page.entries
            guard page.more, let oldest = page.entries.last else { break }
            before = oldest.id
        }
        let all = entries
        let kindName = kindName
        let texts = await Task.detached(priority: .userInitiated) {
            all.map { Self.searchText($0, kindName: kindName) }
        }.value
        return Everything(entries: all, texts: texts, rev: rev)
    }

    /// What a search looks in, one line per part so a word cannot span two.
    nonisolated static func searchText(_ entry: LogbookEntry, kindName: (String) -> String?) -> String {
        var lines = [entry.message, entry.subject ?? "", entry.kind]
        if let name = kindName(entry.kind) {
            lines.append(name)
        }
        for (key, value) in entry.fields ?? [:] {
            lines.append("\(key) \(value.text)")
        }
        return lines.joined(separator: "\n").lowercased()
    }

    private nonisolated static func matches(in book: Everything, terms: [String], kind: String?) -> [LogbookEntry] {
        var matches: [LogbookEntry] = []
        for (entry, text) in zip(book.entries, book.texts) {
            if let kind, !isOf(entry.kind, kind) {
                continue
            }
            if terms.allSatisfy({ text.contains($0) }) {
                matches.append(entry)
            }
        }
        return matches
    }

    /// The engine's kind filter: a kind, or its area (`config` matches
    /// `config.reload`).
    nonisolated static func isOf(_ entryKind: String, _ kind: String) -> Bool {
        entryKind == kind || entryKind.hasPrefix(kind + ".")
    }

    private func show(_ page: [LogbookEntry], more: Bool, rev: UInt64, for filter: LogbookFilter) {
        entries = page
        self.more = more
        self.rev = rev
        shown = filter
        error = nil
        loaded = true
        generation += 1
    }

    private func failed(_ failure: any Error, _ filter: LogbookFilter) {
        // What another filter found does not answer this one.
        if shown != filter {
            show([], more: false, rev: 0, for: filter)
        }
        error = (failure as? LogbookReadError)?.message ?? failure.localizedDescription
        loaded = true
    }
}
