import CMsgCore
import Foundation
import SQLite3

/// How messages are chunked for embedding and how the layers are blended.
/// Changing a weight only changes the next search; changing how text is
/// chunked means embedding again (`MessageStore.settings` does that).
struct SearchSettings: Equatable {
    /// Blend weights for the message, exchange and sitting layers.
    var messageWeight: Float = 0.4
    var exchangeWeight: Float = 0.4
    var sittingWeight: Float = 0.2
    /// How many messages either side of a message make up its exchange.
    var exchangeReach = 2
    /// Messages further apart than this (seconds) are not the same exchange.
    var exchangeGap = 20.0 * 60
    /// A pause longer than this (seconds) ends a sitting.
    var sittingGap = 30.0 * 60
    /// Longest sitting, in messages; a marathon conversation is split.
    var sittingLimit = 40

    /// How hard short texts are pulled down, per layer: a text of this many
    /// bytes scores half its cosine. Stops "What news" from beating a real
    /// conversation about the news.
    var messageBrevity: Float = 4
    var exchangeBrevity: Float = 24
    var sittingBrevity: Float = 24

    var weights: [Float] { [messageWeight, exchangeWeight, sittingWeight] }
    var brevity: [Float] { [messageBrevity, exchangeBrevity, sittingBrevity] }
    /// True if `other` chunks text differently, so the layers must be rebuilt.
    func chunksDiffer(from other: SearchSettings) -> Bool {
        exchangeReach != other.exchangeReach || exchangeGap != other.exchangeGap
            || sittingGap != other.sittingGap || sittingLimit != other.sittingLimit
    }
}

/// One search result: the matched message and the exchange around it.
struct Hit: Identifiable {
    struct Line: Identifiable {
        let id: Int
        let sender: String
        let text: String
        let isMatch: Bool
        let attachments: [Attachment]
        /// Tapbacks and stickers put on this message, as glyphs: "❤️", "👍 2".
        let reactions: [String]
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
    /// True once there is nothing further to page in.
    var exhausted = true
    /// Strong matches per timeline bucket (see `TimeAxis`); empty if the query
    /// has nothing to place in time.
    var timeline: [Float] = []
}

/// The time axis of the timeline strip: the span of the whole history cut into
/// equal buckets, with how many messages fall in each and where years begin.
struct TimeAxis {
    static let bucketCount = 120
    /// Seconds since 2001 at the two ends.
    var start = 0.0
    var end = 1.0
    /// Messages per bucket.
    var volume: [Float] = []
    /// Each calendar year's extent as fractions of the axis (0...1).
    var years: [(year: Int, start: Double, end: Double)] = []
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
/// Every message is embedded at three granularities, and a search blends its
/// similarity in all three (see `SearchSettings`):
///
/// - the **message** alone, for a specific phrase;
/// - its **exchange**, the few messages either side of it, because people text
///   in fragments and the meaning usually lives in the back-and-forth;
/// - its **sitting**, the whole stretch of conversation it belongs to, for
///   "that time we talked about moving".
///
/// Embedding all of it takes a fraction of a second, so there is no
/// incremental indexing: when a message arrives, everything is embedded again.
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
    /// Message index -> the reactions it has received.
    private var reactions: [Int: [Reaction]] = [:]
    /// Emoji code point -> the messages containing it, in index order.
    private var emojiMessages: [UInt32: [Int32]] = [:]
    /// Message index -> its attachments, for the messages that have any.
    private var attachments: [Int: [Attachment]] = [:]
    var settings = SearchSettings() {
        didSet { if settings.chunksDiffer(from: oldValue) { embedAll() } }
    }
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
    private(set) var axis = TimeAxis()
    /// Message index -> its bucket on the time axis.
    private var bucketOf: [UInt32] = []
    /// A match counts on the timeline if it scores at least this share of the best score.
    private static let timelineCutoff: Float = 0.65

    /// Where the current search has got to; see `nextPage`.
    private struct Paging {
        var token: Int
        var count: Int
        var query: [UInt8]
        var weights: [Float]
        var brevity: [Float]
        var mask: [UInt8]?
        /// Messages already shown as part of some result's exchange.
        var shown = Set<Int>()
        /// Semantic search: the last candidate consumed, as a ranking cursor.
        var afterScore = Float.infinity
        var afterIndex: UInt32 = 0
        /// Filter-only search: the next message to look at, walking backwards.
        var nextRecent: Int
        var exhausted = false
    }
    private var paging: Paging?

    private var cachedMask: (handles: Set<Int32>, sender: QueryParser.Sender, media: MediaFilter?, emoji: EmojiFilter?, reaction: ReactionFilter?, count: Int, mask: [UInt8])?
    /// One person's messages closer together than this (seconds) are one run,
    /// which is what "more than 5 photos" counts across.
    private static let runGap = 5.0 * 60

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
            if hasText {
                if containsLink(from: bodyStart) { carried[MediaKind.link.rawValue] = 1 }
                indexEmoji(from: bodyStart, message: Int32(count))
            }
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
        if before == 0 {
            stats.readSeconds = CFAbsoluteTimeGetCurrent() - started
        }
        loadReactions(db)
        cachedMask = nil
        // No incremental indexing: with anything new, embed everything again.
        if count > before {
            embedAll()
            buildTimeAxis()
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
        // `is_sticker` is missing from older databases, so try with it first.
        func rows(sticker: String) -> [(Int64, String, String, String, String, Bool)]? {
            let sql = """
                SELECT j.message_id, IFNULL(a.mime_type, ''), IFNULL(a.uti, ''), IFNULL(a.transfer_name, ''), IFNULL(a.filename, ''), \(sticker)
                FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE j.message_id > \(maxRowID)
                ORDER BY j.message_id, a.ROWID
                """
            return try? query(db, sql) {
                (sqlite3_column_int64($0, 0), Self.string($0, 1), Self.string($0, 2), Self.string($0, 3), Self.string($0, 4),
                 sqlite3_column_int($0, 5) != 0)
            }
        }
        let rows = rows(sticker: "IFNULL(a.is_sticker, 0)") ?? rows(sticker: "0") ?? []
        var result: [Int64: [Attachment]] = [:]
        for (message, mime, uti, transferName, path, isSticker) in rows {
            let name = ((transferName.isEmpty ? path : transferName) as NSString).lastPathComponent
            // Link previews store their thumbnails as attachments; those are not something a person sent.
            if name.hasSuffix(".pluginPayloadAttachment") { continue }
            result[message, default: []].append(Attachment(
                kind: isSticker ? .sticker : MediaKind.classify(mime: mime, uti: uti, name: name),
                name: name, path: (path as NSString).expandingTildeInPath))
        }
        return result
    }

    /// Reads every tapback and sticker placed on a message. In chat.db a
    /// reaction is itself a row in `message`: `associated_message_type` says
    /// what it is (2000-2005 the classic six, 2006 an emoji, 2007 and 1000
    /// stickers, 3000+ the removal of one) and `associated_message_guid`
    /// points at the message it is on. Reloaded in full whenever anything is
    /// new; does nothing if the database lacks these columns.
    private func loadReactions(_ db: OpaquePointer) {
        func rows(emoji: String) -> [(Int64, Int32, Bool, Int32, String)]? {
            let sql = """
                SELECT m.ROWID, r.associated_message_type, r.is_from_me, r.handle_id, \(emoji)
                FROM message r JOIN message m ON m.guid = CASE
                    WHEN r.associated_message_guid LIKE 'p:%' THEN substr(r.associated_message_guid, instr(r.associated_message_guid, '/') + 1)
                    WHEN r.associated_message_guid LIKE 'bp:%' THEN substr(r.associated_message_guid, 4)
                    ELSE r.associated_message_guid END
                WHERE r.associated_message_type BETWEEN 1000 AND 3999
                ORDER BY r.ROWID
                """
            return try? query(db, sql) {
                (sqlite3_column_int64($0, 0), sqlite3_column_int($0, 1), sqlite3_column_int($0, 2) != 0,
                 sqlite3_column_int($0, 3), Self.string($0, 4))
            }
        }
        // The emoji column arrived with emoji tapbacks; older databases lack it.
        guard let rows = rows(emoji: "IFNULL(r.associated_message_emoji, '')") ?? rows(emoji: "''") else { return }

        reactions = [:]
        for (rowID, type, isFromMe, handle, emoji) in rows {
            guard let index = index(ofRowID: rowID) else { continue }
            let removing = type >= 3000
            let code = Int(type) - (removing ? 3000 : type >= 2000 ? 2000 : 1000)
            guard let kind = type < 2000 ? ReactionKind.sticker : ReactionKind(rawValue: code) else { continue }
            // One person has one tapback per message; a new one replaces it.
            if kind != .sticker || removing {
                reactions[index]?.removeAll {
                    $0.isFromMe == isFromMe && $0.handle == handle && (removing ? $0.kind == kind : $0.kind != .sticker)
                }
            }
            if !removing {
                reactions[index, default: []].append(Reaction(kind: kind, emoji: emoji, isFromMe: isFromMe, handle: handle))
            }
        }
        reactions = reactions.filter { !$0.value.isEmpty }
    }

    /// `rowIDs` is ascending, so a message's position is a binary search away.
    private func index(ofRowID rowID: Int64) -> Int? {
        var low = 0
        var high = rowIDs.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if rowIDs[mid] == rowID { return mid }
            if rowIDs[mid] < rowID { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// "❤️", "👍 2": one entry per distinct reaction on a message.
    private func reactionGlyphs(_ i: Int) -> [String] {
        guard let all = reactions[i] else { return [] }
        var counts: [(String, Int)] = []
        for glyph in all.map(\.glyph) where !glyph.isEmpty {
            if let at = counts.firstIndex(where: { $0.0 == glyph }) { counts[at].1 += 1 } else { counts.append((glyph, 1)) }
        }
        return counts.map { $0.1 > 1 ? "\($0.0) \($0.1)" : $0.0 }
    }

    /// "[2 photos] [PDF: lease.pdf]": what an attachment contributes to the
    /// embedded text. On screen the files themselves are shown instead.
    private static func caption(_ attached: [Attachment]) -> String {
        var parts: [String] = []
        for (kind, noun) in [(MediaKind.image, "photo"), (.video, "video"), (.audio, "audio message"), (.sticker, "sticker")] {
            let n = attached.filter { $0.kind == kind }.count
            if n > 0 { parts.append(n == 1 ? "[\(noun)]" : "[\(n) \(noun)s]") }
        }
        for file in attached where file.kind == .pdf || file.kind == .file {
            parts.append("[\(file.kind == .pdf ? "PDF" : "file"): \(file.name)]")
        }
        return parts.joined(separator: " ")
    }

    /// Records which emoji appear in the text from `start` to the end of the
    /// buffer. Only multi-byte UTF-8 is decoded, so plain text costs one
    /// comparison per byte.
    private func indexEmoji(from start: Int, message: Int32) {
        var i = start
        let end = text.count
        while i < end {
            let b = UInt32(text[i])
            var value: UInt32 = 0
            if b >= 0xF0, i + 3 < end {
                value = (b & 0x07) << 18 | (UInt32(text[i + 1]) & 0x3F) << 12 | (UInt32(text[i + 2]) & 0x3F) << 6 | (UInt32(text[i + 3]) & 0x3F)
                i += 4
            } else if b >= 0xE2, b < 0xF0, i + 2 < end {
                value = (b & 0x0F) << 12 | (UInt32(text[i + 1]) & 0x3F) << 6 | (UInt32(text[i + 2]) & 0x3F)
                i += 3
            } else {
                i += 1
                continue
            }
            if EmojiFilter.isEmoji(value), emojiMessages[value]?.last != message {
                emojiMessages[value, default: []].append(message)
            }
        }
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

    /// Lays every message out on the time axis.
    private func buildTimeAxis() {
        var axis = TimeAxis()
        var start = Double.infinity
        var end = -Double.infinity
        for i in 0..<count {
            let t = seconds(i)
            if t > 0 {
                start = min(start, t)
                end = max(end, t)
            }
        }
        guard start < end else { return }
        axis.start = start
        axis.end = end

        let buckets = TimeAxis.bucketCount
        let scale = Double(buckets) / (end - start)
        bucketOf = [UInt32](repeating: 0, count: count)
        axis.volume = [Float](repeating: 0, count: buckets)
        for i in 0..<count {
            let bucket = min(buckets - 1, max(0, Int((seconds(i) - start) * scale)))
            bucketOf[i] = UInt32(bucket)
            axis.volume[bucket] += 1
        }

        let calendar = Calendar.current
        let firstYear = calendar.component(.year, from: Date(timeIntervalSinceReferenceDate: start))
        let lastYear = calendar.component(.year, from: Date(timeIntervalSinceReferenceDate: end))
        func fraction(ofYear year: Int) -> Double {
            let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
            return min(1, max(0, (date.timeIntervalSinceReferenceDate - start) / (end - start)))
        }
        if lastYear - firstYear < 200 {
            axis.years = (firstYear...lastYear).map { ($0, fraction(ofYear: $0), fraction(ofYear: $0 + 1)) }
        }
        self.axis = axis
    }

    /// Embeds every message at all three granularities, replacing whatever was
    /// indexed before.
    private func embedAll() {
        let started = CFAbsoluteTimeGetCurrent()
        for layer in 0..<Int(MS_LAYERS) { ms_clear_layer(layer) }
        guard count > 0 else { return }

        // Layer 0, messages: the text buffer is already in the right shape.
        text.withUnsafeBufferPointer { bytes in
            offsets.withUnsafeBufferPointer { ms_add(0, bytes.baseAddress, $0.baseAddress, count) }
        }

        // Layer 1, exchanges. Each message is capped so a long one cannot
        // drown out its neighbours.
        func append(_ j: Int, to buffer: inout ContiguousArray<UInt8>) {
            buffer.append(contentsOf: text[offsets[j]..<min(offsets[j + 1], offsets[j] + 400)])
            buffer.append(0x0A)
        }
        embed(layer: 1, count: count) { i, buffer in
            for j in exchange(around: i) { append(j, to: &buffer) }
        }

        // Layer 2, sittings: one vector shared by every message in the sitting.
        var sittingOf = [UInt32](repeating: 0, count: count)
        var sittings: [[Int32]] = []
        for i in 0..<count {
            let before = Int(previous[i])
            if before >= 0, seconds(i) - seconds(before) <= settings.sittingGap,
               sittings[Int(sittingOf[before])].count < settings.sittingLimit {
                sittingOf[i] = sittingOf[before]
                sittings[Int(sittingOf[i])].append(Int32(i))
            } else {
                sittingOf[i] = UInt32(sittings.count)
                sittings.append([Int32(i)])
            }
        }
        embed(layer: 2, count: sittings.count) { sitting, buffer in
            for j in sittings[sitting] { append(Int(j), to: &buffer) }
        }
        ms_set_map(2, sittingOf, count)

        stats.embedSeconds = CFAbsoluteTimeGetCurrent() - started
    }

    /// Builds `n` texts with `write` and embeds them into `layer`, in batches
    /// so the scratch buffer stays small.
    private func embed(layer: Int, count n: Int, _ write: (Int, inout ContiguousArray<UInt8>) -> Void) {
        var buffer = ContiguousArray<UInt8>()
        var ends = ContiguousArray<Int>([0])
        func flush() {
            buffer.withUnsafeBufferPointer { bytes in
                ends.withUnsafeBufferPointer { ms_add(layer, bytes.baseAddress, $0.baseAddress, $0.count - 1) }
            }
            buffer.removeAll(keepingCapacity: true)
            ends.removeAll(keepingCapacity: true)
            ends.append(0)
        }
        for i in 0..<n {
            write(i, &buffer)
            ends.append(buffer.count)
            if ends.count > 50_000 { flush() }
        }
        flush()
    }

    /// Message `i` with its neighbours either side from the same chat, oldest
    /// first: what is embedded as its exchange and shown as its result.
    private func exchange(around i: Int) -> [Int] {
        let time = seconds(i)
        var result: [Int] = []
        var j = Int(previous[i])
        while j >= 0, result.count < settings.exchangeReach, abs(time - seconds(j)) <= settings.exchangeGap {
            result.append(j)
            j = Int(previous[j])
        }
        result.reverse()
        result.append(i)
        let before = result.count
        j = Int(next[i])
        while j >= 0, result.count - before < settings.exchangeReach, abs(seconds(j) - time) <= settings.exchangeGap {
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

    /// Starts a search and returns its first page. `token` identifies the
    /// search to `nextPage`, so a page requested for an older query is ignored.
    /// Starts a search and returns its first page. `token` identifies the
    /// search to `nextPage`, so a page requested for an older query is ignored.
    /// `year` limits results to one calendar year (the timeline still covers
    /// every year, so the others stay visible to pick from).
    func search(_ query: String, token: Int = 0, year: Int? = nil) -> SearchResults {
        var results = SearchResults()
        let parsed = QueryParser.parse(query) { word in
            Self.ambiguousNames.contains(word) ? nil : self.people(named: word)
        }
        var mask: [UInt8]?
        var described: [String] = []
        if parsed.isStructured {
            mask = self.mask(handles: parsed.handles, sender: parsed.sender, media: parsed.media, emoji: parsed.emoji, reaction: parsed.reaction)
            let names = Set(parsed.handles.map(name(forHandle:))).sorted()
            let from = !names.isEmpty ? "from " + names.formatted(.list(type: .or))
                : parsed.sender == .others ? "from other people" : parsed.sender == .me ? "from you" : ""
            described = (from.isEmpty ? [] : [from])
                + (parsed.media.map { [$0.description] } ?? [])
                + (parsed.emoji.map { [$0.description] } ?? [])
                + (parsed.reaction.map { reaction in
                    let reactors = Set(reaction.byHandles.map(name(forHandle:))).sorted()
                    let by = !reactors.isEmpty ? " from " + reactors.formatted(.list(type: .or))
                        : reaction.by == .me ? " from you" : reaction.by == .others ? " from someone else" : ""
                    return [reaction.description + by]
                } ?? [])
        }
        let remainder = Array(parsed.remainder.utf8)
        results.timeline = timeline(query: remainder, mask: mask)

        if let year {
            // Narrow to the year after the timeline is drawn from everything.
            let calendar = Calendar.current
            let from = calendar.date(from: DateComponents(year: year, month: 1, day: 1))?.timeIntervalSinceReferenceDate ?? 0
            let to = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))?.timeIntervalSinceReferenceDate ?? 0
            var narrowed = mask ?? [UInt8](repeating: 1, count: count)
            for i in 0..<count where narrowed[i] != 0 {
                let t = seconds(i)
                if t < from || t >= to { narrowed[i] = 0 }
            }
            mask = narrowed
            described.append("in \(year)")
        }
        if !described.isEmpty { results.filter = (["Only messages"] + described).joined(separator: " ") }

        paging = Paging(token: token, count: count, query: remainder, weights: settings.weights, brevity: settings.brevity, mask: mask, nextRecent: count - 1)
        if let page = nextPage(token: token) {
            results.hits = page.hits
            results.exhausted = page.exhausted
        }
        return results
    }

    /// How many strong matches fall in each bucket of the time axis. With
    /// words to match, every message is scored (one more full pass); with
    /// only a filter, it is a count of what passes.
    private func timeline(query: [UInt8], mask: [UInt8]?) -> [Float] {
        guard bucketOf.count == count, count > 0 else { return [] }
        var buckets = [Float](repeating: 0, count: TimeAxis.bucketCount)
        if query.isEmpty {
            guard let mask else { return [] }
            for i in 0..<count where mask[i] != 0 { buckets[Int(bucketOf[i])] += 1 }
            return buckets
        }
        let best = query.withUnsafeBufferPointer { q in
            if let mask {
                return mask.withUnsafeBufferPointer {
                    ms_histogram(q.baseAddress, q.count, settings.weights, settings.brevity, $0.baseAddress, bucketOf, buckets.count, Self.timelineCutoff, &buckets)
                }
            }
            return ms_histogram(q.baseAddress, q.count, settings.weights, settings.brevity, nil, bucketOf, buckets.count, Self.timelineCutoff, &buckets)
        }
        return best > 0 ? buckets : []
    }

    /// The next `limit` results of the search started with `token`, or nil if
    /// that search has been replaced. Results are unbounded: every page is one
    /// more scan that resumes from a cursor, so nothing is computed or kept for
    /// results nobody scrolls to.
    func nextPage(token: Int, limit: Int = 60) -> (hits: [Hit], exhausted: Bool)? {
        guard var state = paging, state.token == token else { return nil }
        defer { paging = state }
        // New messages arrived since this search began; a fresh search follows.
        guard state.count == count, !state.exhausted else { return ([], true) }

        var hits: [Hit] = []
        func add(_ i: Int, score: Float) {
            if state.shown.contains(i) { return }
            let exchange = exchange(around: i)
            state.shown.formUnion(exchange)
            hits.append(hit(i, exchange: exchange, score: score))
        }

        // Nothing left to match by meaning ("maya sends >5 images"): list
        // what passes the filter, newest first.
        if let mask = state.mask, state.query.isEmpty {
            while state.nextRecent >= 0, hits.count < limit {
                if mask[state.nextRecent] != 0 { add(state.nextRecent, score: 0) }
                state.nextRecent -= 1
            }
            state.exhausted = state.nextRecent < 0
            return (hits, state.exhausted)
        }

        // Neighbouring messages share most of their exchange, so candidates
        // arrive in clumps and most are folded into a result already shown.
        // Keep pulling batches until the page is full.
        let batch = 256
        var indices = [UInt32](repeating: 0, count: batch)
        var scores = [Float](repeating: 0, count: batch)
        var scans = 0
        while hits.count < limit, !state.exhausted, scans < 24 {
            scans += 1
            let found = state.query.withUnsafeBufferPointer { q in
                if let mask = state.mask {
                    return mask.withUnsafeBufferPointer {
                        ms_search(q.baseAddress, q.count, state.weights, state.brevity, batch, $0.baseAddress, state.afterScore, state.afterIndex, &indices, &scores)
                    }
                }
                return ms_search(q.baseAddress, q.count, state.weights, state.brevity, batch, nil, state.afterScore, state.afterIndex, &indices, &scores)
            }
            for n in 0..<found {
                state.afterScore = scores[n]
                state.afterIndex = indices[n]
                add(Int(indices[n]), score: scores[n])
                if hits.count == limit { break }
            }
            if found < batch { state.exhausted = hits.count < limit || found == 0 }
        }
        return (hits, state.exhausted)
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
            Hit.Line(id: j, sender: fromMe[j] ? "You" : firstName(name(forHandle: handleIDs[j])), text: body(j), isMatch: j == i, attachments: attachments[j] ?? [], reactions: reactionGlyphs(j))
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
    private func mask(handles: Set<Int32>, sender: QueryParser.Sender, media filter: MediaFilter?, emoji: EmojiFilter?, reaction: ReactionFilter?) -> [UInt8] {
        if let cached = cachedMask, cached.handles == handles, cached.sender == sender, cached.media == filter,
           cached.emoji == emoji, cached.reaction == reaction, cached.count == count {
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
        if let emoji {
            // Keep only messages containing a matching emoji.
            var carries = [Bool](repeating: false, count: count)
            for (value, messages) in emojiMessages {
                let name = Unicode.Scalar(value)?.properties.name ?? ""
                if emoji.matches(value: value, name: name) {
                    for message in messages { carries[Int(message)] = true }
                }
            }
            for i in 0..<count where !carries[i] { mask[i] = 0 }
        }
        if let reaction {
            // Keep only messages that received a matching reaction.
            for i in 0..<count where mask[i] != 0 {
                if !(reactions[i]?.contains(where: reaction.matches) ?? false) { mask[i] = 0 }
            }
        }
        cachedMask = (handles, sender, filter, emoji, reaction, count, mask)
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
