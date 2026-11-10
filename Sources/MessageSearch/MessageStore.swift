import CMsgCore
import Foundation
import SQLite3

/// One search result: the matched message and the exchange around it.
struct Hit: Identifiable {
    struct Line: Identifiable {
        let id: Int
        let sender: String
        let text: String
        let isMatch: Bool
        let attachments: [Attachment]
    }

    let id: Int          // position in the index
    let rowID: Int64     // message.ROWID in chat.db
    let text: String
    let sender: String
    let chat: String
    let isGroup: Bool
    let isFromMe: Bool
    let date: Date
    let score: Float
    /// The matched message with up to two messages either side, oldest first.
    let lines: [Line]
}

/// A file sent with a message. `path` is where Messages keeps it on disk; the
/// file may be missing if it was offloaded to iCloud.
struct Attachment: Hashable {
    let kind: MediaKind
    let name: String
    let path: String
}

struct SearchResults {
    var hits: [Hit] = []
    /// Describes the people / attachment filter found in the query, or "".
    var filter = ""
}

struct LoadStats {
    var messages = 0
    var readSeconds = 0.0
    var embedSeconds = 0.0
}

enum StoreError: Error {
    /// chat.db could not be read; almost always missing Full Disk Access.
    case cannotRead(String)
}

/// Reads Messages' chat.db (read-only) into flat columns and feeds the text to
/// the Rust core for embedding. Not thread-safe: use it from one queue.
///
/// Message text is kept as one contiguous UTF-8 buffer plus offsets, so loading
/// never creates a Swift String per message; Strings are made only for the few
/// rows that end up on screen.
///
/// What gets embedded for a message is not the message alone but its
/// *exchange*: up to two messages before and after it in the same chat (within
/// `exchangeGap`), with the message itself counted twice. People text in
/// fragments, so the meaning usually lives in the exchange.
final class MessageStore: @unchecked Sendable {
    static let defaultPath = NSHomeDirectory() + "/Library/Messages/chat.db"

    let path: String
    private var db: OpaquePointer?

    private var rowIDs = ContiguousArray<Int64>()
    private var dates = ContiguousArray<Int64>()
    private var handleIDs = ContiguousArray<Int32>()
    private var chatIDs = ContiguousArray<Int32>()
    private var fromMe = ContiguousArray<Bool>()
    private var text = ContiguousArray<UInt8>()
    private var offsets = ContiguousArray<Int>([0])
    /// Previous / next message in the same chat, or -1.
    private var previous = ContiguousArray<Int32>()
    private var next = ContiguousArray<Int32>()
    private var lastInChat: [Int32: Int32] = [:]
    /// Per kind (indexed by `MediaKind.rawValue`), how many each message carries.
    private var media = [ContiguousArray<UInt8>](repeating: [], count: MediaKind.allCases.count)
    /// Message index -> its attachments, for the messages that have any.
    private var attachments: [Int: [Attachment]] = [:]
    private var embedded = 0
    private var maxRowID: Int64 = 0

    private struct Chat {
        var identifier: String
        var displayName: String
        var isGroup: Bool
        var participants: [Int32] = []
    }
    private var handles: [Int32: String] = [:]
    private var chats: [Int32: Chat] = [:]
    /// Normalized phone/email -> contact name. See `ContactBook`.
    var contacts: [String: String] = [:] {
        didSet { peopleByName = nil }
    }
    /// Lowercased name word -> handles of people with that name. Built lazily.
    private var peopleByName: [String: Set<Int32>]?
    private var cachedMask: (handles: Set<Int32>, sender: QueryParser.Sender, media: MediaFilter?, count: Int, mask: [UInt8])?
    /// One person's messages closer together than this (seconds) are one run,
    /// which is what "more than 5 photos" counts across.
    private static let runGap = 5.0 * 60

    /// Messages further apart than this (seconds) are not the same exchange.
    private static let exchangeGap = 20.0 * 60

    private(set) var stats = LoadStats()

    init(path: String = MessageStore.defaultPath) {
        self.path = path
    }

    deinit {
        sqlite3_close(db)
    }

    var count: Int { rowIDs.count }

    // MARK: Loading

    /// Loads every message newer than what is already indexed. Returns how many
    /// were added. The first call loads everything.
    @discardableResult
    func loadNew(progress: ((Int) -> Void)? = nil) throws -> Int {
        let db = try open()
        let started = CFAbsoluteTimeGetCurrent()
        let embedBefore = stats.embedSeconds
        let before = count

        // A cheap check first, so polling an idle database costs nothing.
        let latest = try query(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message") { sqlite3_column_int64($0, 0) }.first ?? 0
        if latest <= maxRowID { return 0 }
        defer { maxRowID = max(maxRowID, latest) }
        try loadDirectory(db)
        let attachmentsByRow = loadAttachments(db)

        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, m.handle_id, j.chat_id
            FROM message m LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
            WHERE m.ROWID > ?1 AND IFNULL(m.associated_message_type, 0) = 0
              AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
            ORDER BY m.ROWID
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, maxRowID)

        var lastRowID: Int64 = -1
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(db) }

            let rowID = sqlite3_column_int64(stmt, 0)
            maxRowID = max(maxRowID, rowID)
            if rowID == lastRowID { continue }  // same message joined to a second chat
            lastRowID = rowID

            let bodyStart = text.count
            var hasText = false
            if let p = sqlite3_column_text(stmt, 1) {
                hasText = appendText(p, Int(sqlite3_column_bytes(stmt, 1)))
            }
            if !hasText, let blob = sqlite3_column_blob(stmt, 2) {
                let n = Int(sqlite3_column_bytes(stmt, 2))
                let p = blob.assumingMemoryBound(to: UInt8.self)
                if let (start, length) = TypedStream.stringRange(p, n) {
                    hasText = appendText(p + start, length)
                } else if let string = TypedStream.slowString(Data(bytes: blob, count: n)) {
                    var utf8 = Array(string.utf8)
                    hasText = utf8.withUnsafeMutableBufferPointer { appendText($0.baseAddress!, $0.count) }
                }
            }
            let attached = attachmentsByRow[rowID]
            guard hasText || attached != nil else { continue }

            // What the message carries besides words. Attachments also get a
            // caption like "[2 photos]" or "[PDF: lease.pdf]" appended to the
            // text, so they show up in results and file names are searchable.
            var carried = [UInt8](repeating: 0, count: media.count)
            if hasText, containsLink(from: bodyStart) { carried[MediaKind.link.rawValue] = 1 }
            if let attached {
                for file in attached { carried[file.kind.rawValue] &+= carried[file.kind.rawValue] < 255 ? 1 : 0 }
                if hasText { text.append(0x0A) }
                text.append(contentsOf: Self.caption(attached).utf8)
                attachments[count] = attached
            }
            offsets.append(text.count)
            for kind in media.indices { media[kind].append(carried[kind]) }

            rowIDs.append(rowID)
            dates.append(sqlite3_column_int64(stmt, 3))
            fromMe.append(sqlite3_column_int(stmt, 4) != 0)
            handleIDs.append(sqlite3_column_int(stmt, 5))
            let chat = sqlite3_column_int(stmt, 6)
            chatIDs.append(chat)

            let index = Int32(count - 1)
            let earlier = chat != 0 ? lastInChat[chat] ?? -1 : -1
            previous.append(earlier)
            next.append(-1)
            if earlier >= 0 { next[Int(earlier)] = index }
            if chat != 0 { lastInChat[chat] = index }

            if count % 50_000 == 0 { progress?(count) }
        }
        embedPending()

        let total = CFAbsoluteTimeGetCurrent() - started
        if before == 0 {
            stats.readSeconds = total - (stats.embedSeconds - embedBefore)
        }
        stats.messages = count
        return count - before
    }

    private func open() throws -> OpaquePointer {
        if let db { return db }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw StoreError.cannotRead(message)
        }
        // Opening is lazy; touching the schema is what actually needs permission.
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT 1 FROM message LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw StoreError.cannotRead(message)
        }
        sqlite3_finalize(stmt)
        sqlite3_busy_timeout(handle, 2000)
        db = handle
        return handle
    }

    /// Handles (phone numbers / emails) and chats. Small, so reloaded whenever
    /// there are new messages.
    private func loadDirectory(_ db: OpaquePointer) throws {
        peopleByName = nil
        handles = Dictionary(
            try query(db, "SELECT ROWID, id FROM handle") { (sqlite3_column_int($0, 0), Self.string($0, 1)) },
            uniquingKeysWith: { a, _ in a })
        chats = Dictionary(
            try query(db, "SELECT ROWID, chat_identifier, display_name, style FROM chat") {
                (sqlite3_column_int($0, 0),
                 Chat(identifier: Self.string($0, 1), displayName: Self.string($0, 2), isGroup: sqlite3_column_int($0, 3) == 43))
            },
            uniquingKeysWith: { a, _ in a })
        for (chat, handle) in try query(db, "SELECT chat_id, handle_id FROM chat_handle_join", { (sqlite3_column_int($0, 0), sqlite3_column_int($0, 1)) }) {
            chats[chat]?.participants.append(handle)
        }
    }

    /// message ROWID -> its attachments, for messages not loaded yet. Empty if
    /// the database has no attachment tables.
    private func loadAttachments(_ db: OpaquePointer) -> [Int64: [Attachment]] {
        let sql = """
            SELECT j.message_id, IFNULL(a.mime_type, ''), IFNULL(a.uti, ''), IFNULL(a.transfer_name, ''), IFNULL(a.filename, '')
            FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id
            WHERE j.message_id > \(maxRowID)
            ORDER BY j.message_id, a.ROWID
            """
        let rows = (try? query(db, sql) {
            (sqlite3_column_int64($0, 0), Self.string($0, 1), Self.string($0, 2), Self.string($0, 3), Self.string($0, 4))
        }) ?? []
        var result: [Int64: [Attachment]] = [:]
        for (message, mime, uti, transferName, path) in rows {
            let name = ((transferName.isEmpty ? path : transferName) as NSString).lastPathComponent
            // Link previews store their thumbnails as attachments; those are not something a person sent.
            if name.hasSuffix(".pluginPayloadAttachment") { continue }
            result[message, default: []].append(Attachment(
                kind: MediaKind.classify(mime: mime, uti: uti, name: name),
                name: name, path: (path as NSString).expandingTildeInPath))
        }
        return result
    }

    /// "[2 photos] [PDF: lease.pdf]": what an attachment contributes to the
    /// embedded text. On screen the files themselves are shown instead.
    private static func caption(_ attached: [Attachment]) -> String {
        var parts: [String] = []
        for (kind, noun) in [(MediaKind.image, "photo"), (.video, "video"), (.audio, "audio message")] {
            let n = attached.filter { $0.kind == kind }.count
            if n > 0 { parts.append(n == 1 ? "[\(noun)]" : "[\(n) \(noun)s]") }
        }
        for file in attached where file.kind == .pdf || file.kind == .file {
            parts.append("[\(file.kind == .pdf ? "PDF" : "file"): \(file.name)]")
        }
        return parts.joined(separator: " ")
    }

    private func containsLink(from start: Int) -> Bool {
        text.withUnsafeBufferPointer { bytes in
            let p = bytes.baseAddress! + start
            let n = bytes.count - start
            return memmem(p, n, "https://", 8) != nil || memmem(p, n, "http://", 7) != nil
        }
    }

    /// Appends one message's text (without closing the entry) unless it is
    /// empty, whitespace, or only attachment placeholders (U+FFFC).
    private func appendText(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var i = 0
        var meaningful = false
        while i < n {
            let b = p[i]
            if b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 {
                i += 1
            } else if b == 0xEF, i + 2 < n, p[i + 1] == 0xBF, p[i + 2] == 0xBC {
                i += 3
            } else {
                meaningful = true
                break
            }
        }
        guard meaningful else { return false }
        text.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        return true
    }

    /// Embeds the exchange around every message not yet in the index. Runs
    /// after a load so each message can see what came after it.
    private func embedPending() {
        guard count > embedded else { return }
        let started = CFAbsoluteTimeGetCurrent()
        var buffer = ContiguousArray<UInt8>()
        var ends = ContiguousArray<Int>([0])
        func flush() {
            buffer.withUnsafeBufferPointer { bytes in
                ends.withUnsafeBufferPointer { ms_add(bytes.baseAddress, $0.baseAddress, $0.count - 1) }
            }
            buffer.removeAll(keepingCapacity: true)
            ends.removeAll(keepingCapacity: true)
            ends.append(0)
        }
        for i in embedded..<count {
            for j in exchange(around: i) {
                // The message itself counts twice; neighbours are capped so a
                // long one cannot drown it out.
                let limit = j == i ? 1200 : 400
                let piece = text[offsets[j]..<min(offsets[j + 1], offsets[j] + limit)]
                for _ in 0..<(j == i ? 2 : 1) {
                    buffer.append(contentsOf: piece)
                    buffer.append(0x0A)
                }
            }
            ends.append(buffer.count)
            if ends.count > 50_000 { flush() }
        }
        flush()
        embedded = count
        stats.embedSeconds += CFAbsoluteTimeGetCurrent() - started
    }

    /// Message `i` with up to two neighbours either side from the same chat
    /// and the same sitting, oldest first.
    private func exchange(around i: Int) -> [Int] {
        let time = seconds(i)
        var result: [Int] = []
        var j = Int(previous[i])
        while j >= 0, result.count < 2, abs(time - seconds(j)) <= Self.exchangeGap {
            result.append(j)
            j = Int(previous[j])
        }
        result.reverse()
        result.append(i)
        let before = result.count
        j = Int(next[i])
        while j >= 0, result.count - before < 2, abs(seconds(j) - time) <= Self.exchangeGap {
            result.append(j)
            j = Int(next[j])
        }
        return result
    }

    /// Apple stores nanoseconds since 2001 (seconds on very old rows).
    private func seconds(_ i: Int) -> Double {
        let raw = Double(dates[i])
        return raw > 1e11 ? raw / 1e9 : raw
    }

    // MARK: Searching

    func search(_ query: String, limit: Int = 60) -> SearchResults {
        var results = SearchResults()
        let parsed = QueryParser.parse(query) { word in
            Self.ambiguousNames.contains(word) ? nil : self.people(named: word)
        }
        var mask: [UInt8]?
        if parsed.isStructured {
            mask = self.mask(handles: parsed.handles, sender: parsed.sender, media: parsed.media)
            let names = Set(parsed.handles.map(name(forHandle:))).sorted()
            let from = !names.isEmpty ? "from " + names.formatted(.list(type: .or))
                : parsed.sender == .others ? "from other people" : parsed.sender == .me ? "from you" : ""
            results.filter = (["Only messages"]
                + (from.isEmpty ? [] : [from])
                + (parsed.media.map { [$0.description] } ?? [])).joined(separator: " ")
        }

        var shown = Set<Int>()
        func add(_ i: Int, score: Float) {
            if shown.contains(i) { return }
            let exchange = exchange(around: i)
            shown.formUnion(exchange)
            results.hits.append(hit(i, exchange: exchange, score: score))
        }

        // Nothing left to match by meaning ("maya sends >5 images"): list
        // what passes the filter, newest first.
        if let mask, parsed.remainder.isEmpty {
            var i = count - 1
            while i >= 0, results.hits.count < limit {
                if mask[i] != 0 { add(i, score: 0) }
                i -= 1
            }
            return results
        }

        // Neighbouring messages share most of their exchange, so they arrive in
        // clumps; fetch extra and keep the best one per exchange.
        let wanted = limit * 5
        var indices = [UInt32](repeating: 0, count: wanted)
        var scores = [Float](repeating: 0, count: wanted)
        var utf8 = Array(parsed.remainder.utf8)
        let found = utf8.withUnsafeMutableBufferPointer { q in
            if let mask {
                return mask.withUnsafeBufferPointer { ms_search(q.baseAddress, q.count, wanted, $0.baseAddress, &indices, &scores) }
            }
            return ms_search(q.baseAddress, q.count, wanted, nil, &indices, &scores)
        }
        for n in 0..<found where results.hits.count < limit {
            add(Int(indices[n]), score: scores[n])
        }
        return results
    }

    /// The message's words, without attachment placeholders or caption.
    private func body(_ i: Int) -> String {
        var body = String(decoding: text[offsets[i]..<offsets[i + 1]], as: UTF8.self)
        if let attached = attachments[i] {
            let caption = Self.caption(attached)
            if body.hasSuffix(caption) { body.removeLast(caption.count) }
        }
        return body
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hit(_ i: Int, exchange: [Int], score: Float) -> Hit {
        let chat = chats[chatIDs[i]]
        let isGroup = chat?.isGroup ?? false
        let me = fromMe[i]

        let title: String
        if let chat, !chat.displayName.isEmpty {
            title = chat.displayName
        } else if let chat, isGroup {
            title = chat.participants.map { firstName(name(forHandle: $0)) }.joined(separator: ", ")
        } else if let chat {
            title = name(forID: chat.identifier)
        } else {
            title = name(forHandle: handleIDs[i])
        }

        let lines = exchange.map { j in
            Hit.Line(id: j, sender: fromMe[j] ? "You" : firstName(name(forHandle: handleIDs[j])), text: body(j), isMatch: j == i, attachments: attachments[j] ?? [])
        }
        return Hit(
            id: i, rowID: rowIDs[i], text: body(i),
            sender: me ? "You" : name(forHandle: handleIDs[i]),
            chat: title, isGroup: isGroup, isFromMe: me,
            date: Date(timeIntervalSinceReferenceDate: seconds(i)), score: score, lines: lines)
    }

    // MARK: People in the query

    /// Names that are also everyday words; too risky to treat as a person.
    private static let ambiguousNames: Set<String> = [
        "will", "may", "mark", "bill", "art", "joy", "hope", "grace", "rose", "summer", "april", "june",
        "august", "sunny", "faith", "dawn", "amber", "jade", "olive", "penny", "rich", "chance", "love",
        "angel", "star", "sky", "rain", "ray", "van", "pat", "sue", "don", "bob", "drew", "miles", "dean",
        "mom", "dad", "home", "work", "the", "and", "you", "me",
    ]

    /// Handles of the people whose first or last name is `word` (lowercased),
    /// among those who have sent a message.
    private func people(named word: String) -> Set<Int32>? {
        if peopleByName == nil {
            var index: [String: Set<Int32>] = [:]
            for (handle, id) in handles {
                let name = name(forID: id)
                // An unresolved phone number or email is not a name.
                guard name != id || !(id.contains("@") || id.contains(where: \.isNumber)) else { continue }
                for word in name.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count >= 3 {
                    index[String(word), default: []].insert(handle)
                }
            }
            peopleByName = index
        }
        return peopleByName?[word]
    }

    /// One byte per message: 1 where it passes the filter. With a minimum
    /// above one, attachments are counted across the sender's run of messages
    /// and only the run's first carrying message is marked.
    private func mask(handles: Set<Int32>, sender: QueryParser.Sender, media filter: MediaFilter?) -> [UInt8] {
        if let cached = cachedMask, cached.handles == handles, cached.sender == sender, cached.media == filter, cached.count == count {
            return cached.mask
        }
        var mask = [UInt8](repeating: 0, count: count)
        let kinds = filter?.kinds.map(\.rawValue) ?? []
        func fromSender(_ i: Int) -> Bool {
            if !handles.isEmpty { return !fromMe[i] && handles.contains(handleIDs[i]) }
            switch sender {
            case .anyone: return true
            case .others: return !fromMe[i]
            case .me: return fromMe[i]
            }
        }
        func amount(_ i: Int) -> Int { kinds.reduce(0) { $0 + Int(media[$1][i]) } }
        func sameRun(_ a: Int, _ b: Int) -> Bool {
            fromMe[a] == fromMe[b] && handleIDs[a] == handleIDs[b] && abs(seconds(b) - seconds(a)) <= Self.runGap
        }

        for i in 0..<count where fromSender(i) {
            guard let filter else {
                mask[i] = 1
                continue
            }
            if filter.minimum <= 1 {
                if amount(i) > 0 { mask[i] = 1 }
                continue
            }
            let before = Int(previous[i])
            if before >= 0, sameRun(before, i) { continue }  // not the start of a run
            var total = 0
            var first = -1
            var j = i
            while true {
                let n = amount(j)
                if n > 0, first < 0 { first = j }
                total += n
                let after = Int(next[j])
                guard after >= 0, sameRun(j, after) else { break }
                j = after
            }
            if total >= filter.minimum, first >= 0 { mask[first] = 1 }
        }
        cachedMask = (handles, sender, filter, count, mask)
        return mask
    }

    private func name(forHandle id: Int32) -> String {
        handles[id].map(name(forID:)) ?? "Unknown"
    }

    private func name(forID id: String) -> String {
        contacts[ContactBook.normalize(id)] ?? id
    }

    private func firstName(_ name: String) -> String {
        name.contains("@") ? name : String(name.split(separator: " ").first ?? Substring(name))
    }

    /// The message's GUID, which is what Messages' URL scheme addresses.
    func guid(forRowID rowID: Int64) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT guid FROM message WHERE ROWID = ?1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowID)
        return sqlite3_step(stmt) == SQLITE_ROW ? Self.string(stmt, 0) : nil
    }

    // MARK: SQLite helpers

    private func query<T>(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError(db) }
        defer { sqlite3_finalize(stmt) }
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw lastError(db) }
            rows.append(row(stmt))
        }
    }

    private func lastError(_ db: OpaquePointer) -> StoreError {
        .cannotRead(String(cString: sqlite3_errmsg(db)))
    }

    private static func string(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
}

/// Since macOS Ventura most messages have a NULL `text` column and keep their
/// body only in `attributedBody`: an NSAttributedString in the old NSArchiver
/// "typedstream" format.
enum TypedStream {
    private static let marker = Array("NSString".utf8)

    /// Finds the string's UTF-8 bytes without unarchiving anything: the text
    /// follows the NSString class record as `'+' <length> <bytes>`, where a
    /// length of 0x81 / 0x82 means "the real length is the next 2 / 4 bytes".
    static func stringRange(_ p: UnsafePointer<UInt8>, _ n: Int) -> (start: Int, length: Int)? {
        guard let found = memmem(p, n, marker, marker.count) else { return nil }
        var i = UnsafeRawPointer(p).distance(to: UnsafeRawPointer(found)) + marker.count
        let stop = min(n, i + 16)
        while i < stop, p[i] != 0x2B { i += 1 }
        i += 1
        guard i < n else { return nil }

        var length = Int(p[i])
        i += 1
        if length == 0x81 {
            guard i + 2 <= n else { return nil }
            length = Int(p[i]) | Int(p[i + 1]) << 8
            i += 2
        } else if length == 0x82 {
            guard i + 4 <= n else { return nil }
            length = Int(p[i]) | Int(p[i + 1]) << 8 | Int(p[i + 2]) << 16 | Int(p[i + 3]) << 24
            i += 4
        } else if length > 0x82 {
            return nil
        }
        guard length > 0, i + length <= n else { return nil }
        return (i, length)
    }

    /// The real decoder, for anything the fast path does not recognize.
    static func slowString(_ data: Data) -> String? {
        (NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString)?.string
    }
}
