import Foundation
@testable import meow_ios
import os
import Testing

private struct Read: Equatable, Sendable {
    var before: UInt64
    var since: UInt64
    var limit: Int
    var kind: String?
}

/// The engine's logbook with `logbook::read`'s semantics, and every
/// read of it in order.
private final class Book: Sendable {
    private struct Written {
        var entry: LogbookEntry
        var rev: UInt64
    }

    private struct State {
        /// Oldest first, with the rev of each write.
        var written: [Written] = []
        var rev: UInt64 = 0
        var reads: [Read] = []
        /// What every read fails with, while set.
        var failure: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var reads: [Read] {
        state.withLock { $0.reads }
    }

    var failure: String? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    func clearReads() {
        state.withLock { $0.reads.removeAll() }
    }

    func write(_ message: String, kind: String = "config.reload", subject: String? = nil) {
        state.withLock { book in
            book.rev += 1
            let entry = LogbookEntry(
                id: UInt64(book.written.count + 1),
                time: Date(timeIntervalSince1970: 1_760_860_800),
                last: nil,
                count: 1,
                kind: kind,
                level: .info,
                subject: subject,
                message: message,
                fields: nil,
            )
            book.written.append(Written(entry: entry, rev: book.rev))
        }
    }

    func read(before: UInt64, since: UInt64, limit: Int, kind: String?) throws -> LogbookPage {
        try state.withLock { book in
            book.reads.append(Read(before: before, since: since, limit: limit, kind: kind))
            if let failure = book.failure {
                throw LogbookReadError(message: failure)
            }
            let matching = book.written.reversed()
                .filter { before == 0 || $0.entry.id < before }
                .filter { since == 0 || $0.rev > since }
                .filter { written in kind.map { LogbookModel.isOf(written.entry.kind, $0) } ?? true }
                .map(\.entry)
            let size = limit == 0 ? 100 : limit
            return LogbookPage(entries: Array(matching.prefix(size)), rev: book.rev, more: matching.count > size)
        }
    }
}

/// The Paw Print page's reads over a faked logbook: the newest page and
/// its polls, paging back, the event filter and the search. Ported from
/// meow-android's `LogbookViewModelTest`.
@MainActor
@Suite("LogbookModel", .tags(.model))
struct LogbookModelTests {
    private let book = Book()

    private func makeModel() -> LogbookModel {
        let book = book
        return LogbookModel(
            read: { before, since, limit, kind in
                try book.read(before: before, since: since, limit: limit, kind: kind)
            },
            kindName: { $0 == "dialer-proxy.switch" ? "前置代理切换" : nil },
        )
    }

    /// The first read, as the page makes it on open.
    private func opened() async -> LogbookModel {
        let model = makeModel()
        await model.poll(model.filter)
        return model
    }

    private func read(_ before: UInt64, _ since: UInt64, _ limit: Int, _ kind: String? = nil) -> Read {
        Read(before: before, since: since, limit: limit, kind: kind)
    }

    @Test
    func `reads the newest page on open, then again only once something was written`() async {
        book.write("a")
        book.write("b")
        let model = await opened()

        #expect(model.loaded)
        #expect(model.entries.map(\.message) == ["b", "a"])
        #expect(book.reads == [read(0, 0, LogbookModel.pageSize)])

        book.clearReads()
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 2, 1)], "nothing new: one probe")

        book.clearReads()
        book.write("c")
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 2, 1), read(0, 0, LogbookModel.pageSize)])
        #expect(model.entries.map(\.message) == ["c", "b", "a"])
    }

    @Test
    func `an empty logbook is loaded, not failed`() async {
        let model = await opened()
        #expect(model.loaded)
        #expect(model.entries.isEmpty)
        #expect(model.error == nil)
    }

    @Test
    func `pages back, and a later poll keeps every page shown`() async {
        for i in 0 ..< 150 {
            book.write("e\(i)")
        }
        let model = await opened()
        #expect(model.entries.count == 100)
        #expect(model.more)

        await model.loadMore()
        #expect(book.reads.last == read(51, 0, LogbookModel.pageSize))
        #expect(model.entries.count == 150)
        #expect(!model.more)

        book.write("new")
        await model.poll(model.filter)
        #expect(book.reads.last == read(0, 0, 150))
        #expect(model.entries.first?.message == "new")
        #expect(model.entries.count == 150)
        #expect(model.more)
    }

    @Test
    func `an unreadable logbook says why, and the next poll recovers`() async {
        book.failure = "database is locked"
        let model = await opened()
        #expect(model.loaded)
        #expect(model.error == "database is locked")

        book.failure = nil
        book.write("back")
        await model.poll(model.filter)
        #expect(model.error == nil)
        #expect(model.entries.map(\.message) == ["back"])
    }

    @Test
    func `a search reads the whole logbook once and matches every word, the event name too`() async {
        for i in 0 ..< 1200 {
            book.write("filler \(i)")
        }
        book.write("now on HK 02", kind: "dialer-proxy.switch", subject: "Auto")
        book.write("now on JP 01", kind: "dialer-proxy.switch", subject: "Manual")
        book.write("reloaded")
        let model = await opened()
        book.clearReads()

        model.query = " 前置代理切换 auto "
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 0, LogbookModel.maxPage), read(204, 0, LogbookModel.maxPage)])
        #expect(model.entries.map(\.message) == ["now on HK 02"])
        #expect(model.shown.search == "前置代理切换 auto")
        #expect(!model.more, "every match is shown")

        book.clearReads()
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 1203, 1)], "nothing new: one probe")

        book.clearReads()
        book.write("now on HK 03", kind: "dialer-proxy.switch", subject: "Auto")
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 1203, 1), read(0, 0, LogbookModel.maxPage), read(205, 0, LogbookModel.maxPage)])
        #expect(model.entries.map(\.message) == ["now on HK 03", "now on HK 02"])
    }

    @Test
    func `typing reads the logbook once, after the pause`() async {
        book.write("reloaded")
        let model = await opened()
        book.clearReads()

        // The page restarts `run` on every key; each restart cancels the
        // one before it inside its pause.
        for typed in ["r", "re"] {
            model.query = typed
            let typing = Task { await model.run() }
            typing.cancel()
            await typing.value
        }
        #expect(book.reads.isEmpty)

        model.query = "rel"
        let paused = Task { await model.run() }
        #expect(await eventually { model.shown.search == "rel" })
        paused.cancel()
        await paused.value
        #expect(book.reads == [read(0, 0, LogbookModel.maxPage)])
        #expect(model.entries.map(\.message) == ["reloaded"])
    }

    @Test
    func `a search without a match says so, and clearing it shows the newest entries`() async {
        for i in 0 ..< 150 {
            book.write("e\(i)")
        }
        let model = await opened()

        model.query = "  nothing  "
        await model.poll(model.filter)
        #expect(model.loaded)
        #expect(model.entries.isEmpty)
        #expect(model.shown.search == "nothing")

        book.clearReads()
        model.query = ""
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 0, LogbookModel.pageSize)])
        #expect(model.shown.search.isEmpty)
        #expect(model.entries.count == 100)
        #expect(model.more)
    }

    @Test
    func `picking an event reads only that event at once, and pages back within it`() async {
        for i in 0 ..< 150 {
            book.write("s\(i)", kind: "dialer-proxy.switch", subject: "Auto")
        }
        book.write("reloaded")
        let model = await opened()
        book.clearReads()

        model.kind = "dialer-proxy.switch"
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 0, LogbookModel.pageSize, "dialer-proxy.switch")])
        #expect(model.entries.count == 100)
        #expect(model.entries.allSatisfy { $0.kind == "dialer-proxy.switch" })
        #expect(model.more)

        await model.loadMore()
        #expect(book.reads.last == read(51, 0, LogbookModel.pageSize, "dialer-proxy.switch"))
        #expect(model.entries.count == 150)
        #expect(!model.more)

        // The probe watches the whole logbook; the re-read stays on the event.
        book.clearReads()
        book.write("again")
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 151, 1), read(0, 0, 150, "dialer-proxy.switch")])
        #expect(model.entries.count == 150)

        model.kind = nil
        await model.poll(model.filter)
        #expect(book.reads.last == read(0, 0, LogbookModel.pageSize))
        #expect(model.entries.first?.message == "again")
    }

    @Test
    func `an event and a search narrow each other, from one read of the logbook`() async {
        book.write("now on HK 02", kind: "dialer-proxy.switch", subject: "Auto")
        book.write("Auto is down", kind: "dialer-proxy.check", subject: "Auto")
        book.write("reloaded")
        let model = await opened()

        model.query = "auto"
        await model.poll(model.filter)
        #expect(model.entries.map(\.message) == ["Auto is down", "now on HK 02"])

        book.clearReads()
        model.kind = "dialer-proxy.switch"
        await model.poll(model.filter)
        #expect(book.reads == [read(0, 3, 1)], "the copy read for the search is reused")
        #expect(model.entries.map(\.message) == ["now on HK 02"])
        #expect(model.shown.search == "auto")
    }

    @Test
    func `a page back that a re-read overtook is dropped, to be asked again`() async {
        for i in 0 ..< 150 {
            book.write("e\(i)")
        }
        // A page back waits for the gate, so the re-read overtakes it.
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let book = book
        let model = LogbookModel(read: { before, since, limit, kind in
            let page = try book.read(before: before, since: since, limit: limit, kind: kind)
            if before != 0 {
                for await _ in gate {}
            }
            return page
        })
        await model.poll(model.filter)
        let paging = Task { await model.loadMore() }
        #expect(await eventually { book.reads.last == read(51, 0, LogbookModel.pageSize) })

        book.write("new")
        await model.poll(model.filter)
        let generation = model.generation
        open.finish()
        await paging.value
        #expect(model.entries.map(\.id) == Array((UInt64(52) ... 151).reversed()))
        #expect(model.generation == generation, "the page back is dropped")

        // Asked again past the new oldest entry: none twice, none left out.
        await model.loadMore()
        #expect(book.reads.last == read(52, 0, LogbookModel.pageSize))
        #expect(model.entries.map(\.id) == Array((UInt64(1) ... 151).reversed()))
        #expect(!model.more)
    }
}
