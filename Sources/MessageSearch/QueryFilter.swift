import Foundation

/// What a message can carry besides text.
enum MediaKind: Int, CaseIterable {
    case image, video, audio, pdf, file, link, sticker

    /// Classifies an attachment row from chat.db. `mime` is often missing, so
    /// the uniform type identifier and the file extension are fallbacks.
    static func classify(mime: String, uti: String, name: String) -> MediaKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if mime == "application/pdf" || uti == "com.adobe.pdf" || ext == "pdf" { return .pdf }
        if mime.hasPrefix("image/") || uti.contains("image") || ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff"].contains(ext)
            || ["public.jpeg", "public.png", "public.heic", "com.compuserve.gif"].contains(uti) { return .image }
        if mime.hasPrefix("video/") || uti.contains("movie") || uti.contains("video") || ["mov", "mp4", "m4v"].contains(ext) { return .video }
        if mime.hasPrefix("audio/") || uti.contains("audio") || ["caf", "m4a", "mp3", "amr", "wav"].contains(ext) { return .audio }
        return .file
    }
}

/// "with 6 or more photos": the part of a query that is about attachments or
/// links rather than about meaning.
struct MediaFilter: Hashable {
    var kinds: Set<MediaKind>
    var noun: String
    /// How many, counted across one person's uninterrupted run of messages.
    var minimum = 1

    var description: String {
        if minimum <= 1 { return "with \(noun == "audio message" || noun == "attachment" ? "an" : "a") \(noun)" }
        return "with \(minimum) or more \(noun)s"
    }
}

/// "with a heart emoji": which emoji a message must contain. The embedding
/// model cannot see emoji at all, so this is matched against the characters
/// themselves, by Unicode name ("heart" finds ❤ 💙 😍 ...).
struct EmojiFilter: Hashable {
    /// A word describing the emoji, or "" for any emoji.
    var descriptor = ""
    /// Emoji typed into the query itself.
    var literal: [UInt32] = []

    var description: String {
        if !literal.isEmpty {
            return "with " + literal.compactMap { Unicode.Scalar($0).map { String(Character($0)) } }.joined(separator: " or ")
        }
        return descriptor.isEmpty ? "with an emoji" : "with a \(descriptor) emoji"
    }

    /// Whether a code point is treated as an emoji: the symbol and pictograph
    /// blocks, minus skin-tone modifiers.
    static func isEmoji(_ value: UInt32) -> Bool {
        (0x2190...0x2BFF).contains(value) || ((0x1F000...0x1FAFF).contains(value) && !(0x1F3FB...0x1F3FF).contains(value))
    }

    /// Everyday words for emoji whose Unicode names say something else
    /// (😂 is "face with tears of joy").
    private static let aliases: [String: [String]] = [
        "love": ["heart"], "laughing": ["joy", "laughing"], "laugh": ["joy", "laughing"], "lol": ["joy", "laughing"],
        "cry": ["crying"], "sad": ["crying", "disappointed", "pensive"], "happy": ["smiling", "grinning"],
        "smile": ["smiling"], "smiley": ["smiling", "grinning"], "angry": ["angry", "pouting"],
        "like": ["thumbs"], "poop": ["poo"], "kiss": ["kiss", "kissing"], "party": ["party", "partying"],
        "pray": ["folded"], "prayer": ["folded"],
    ]

    /// Whether the emoji with this Unicode name matches the filter.
    func matches(value: UInt32, name: String) -> Bool {
        if literal.contains(value) { return true }
        if !literal.isEmpty { return false }
        if descriptor.isEmpty { return true }
        var wanted: Set<String> = [descriptor, descriptor + "s"]
        if descriptor.hasSuffix("s") { wanted.insert(String(descriptor.dropLast())) }
        wanted.formUnion(Self.aliases[descriptor] ?? [])
        return name.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).contains { wanted.contains(String($0)) }
    }
}

/// A tapback or sticker someone put on a message.
enum ReactionKind: Int {
    // The first six are in the order chat.db numbers them (2000...2005).
    case love, like, dislike, laugh, emphasize, question, emoji, sticker

    var glyph: String {
        switch self {
        case .love: "❤️"
        case .like: "👍"
        case .dislike: "👎"
        case .laugh: "😂"
        case .emphasize: "‼️"
        case .question: "❓"
        case .emoji: ""
        case .sticker: "sticker"
        }
    }
}

struct Reaction {
    let kind: ReactionKind
    /// The emoji, for an emoji tapback.
    let emoji: String
    let isFromMe: Bool
    let handle: Int32

    var glyph: String { kind == .emoji ? emoji : kind.glyph }
}

/// "that got a love reaction": which reactions a message must have received.
/// Reactions carry no text, so encoders has nothing to embed; they narrow the
/// messages that it then ranks ("liked messages about cars").
struct ReactionFilter: Hashable {
    /// Tapback kinds that match; with no kinds and no emoji, any reaction does.
    var kinds: Set<ReactionKind> = []
    /// Matches emoji tapbacks by name or by the emoji itself.
    var emoji: EmojiFilter?
    var label = ""
    /// Who reacted: specific people, or (with none named) me / anyone but me.
    var byHandles = Set<Int32>()
    var by = QueryParser.Sender.anyone

    var description: String { label.isEmpty ? "that got a reaction" : "that got a \(label) reaction" }

    func matches(_ reaction: Reaction) -> Bool {
        if !byHandles.isEmpty {
            guard !reaction.isFromMe, byHandles.contains(reaction.handle) else { return false }
        } else if by == .me {
            guard reaction.isFromMe else { return false }
        } else if by == .others {
            guard !reaction.isFromMe else { return false }
        }
        if kinds.isEmpty && emoji == nil { return true }
        if kinds.contains(reaction.kind) { return true }
        guard reaction.kind == .emoji, let emoji, let scalar = reaction.emoji.unicodeScalars.first else { return false }
        return emoji.matches(value: scalar.value, name: scalar.properties.name ?? "")
    }

    /// Words that name a classic tapback.
    static let words: [String: ReactionKind] = [
        "love": .love, "loved": .love, "heart": .love, "hearted": .love,
        "like": .like, "liked": .like, "thumbsup": .like,
        "dislike": .dislike, "disliked": .dislike, "thumbsdown": .dislike,
        "laugh": .laugh, "laughed": .laugh, "haha": .laugh, "funny": .laugh, "lol": .laugh,
        "emphasize": .emphasize, "emphasized": .emphasize, "exclamation": .emphasize,
        "question": .question, "questioned": .question,
        "sticker": .sticker,
    ]
    /// The emoji that stand for classic tapbacks, so ❤️ finds "Loved" too.
    static let glyphs: [UInt32: ReactionKind] = [
        0x2764: .love, 0x1F44D: .like, 0x1F44E: .dislike, 0x1F602: .laugh, 0x203C: .emphasize, 0x2753: .question,
    ]
    /// "liked messages", "messages I loved": past-tense words that mean a
    /// reaction when they come straight before "messages", or after a subject
    /// in a query that mentions messages. Otherwise they are ordinary words
    /// ("she loved the movie").
    static let adjectives: Set<String> = ["liked", "loved", "disliked", "laughed", "emphasized", "questioned", "hearted"]
}

/// Pulls the structured parts out of a query, leaving the rest for semantic
/// search:
///
///     "maya sends >5 images"        -> from Maya, 6+ photos, ""
///     "sam sends a pdf about taxes" -> from Sam, a PDF, "about taxes"
///     "alex sends a website"     -> from Alex, a link, ""
///     "someone sends me a pdf"        -> from anyone but me, a PDF, ""
///     "someone sends heart emoji"     -> from anyone but me, a heart emoji, ""
///     "liked messages about cars"     -> got a like, "about cars"
///     "messages with a fire reaction" -> got a 🔥 tapback, ""
///     "messages i loved"              -> got a love from me, ""
///     "messages maya laughed at"      -> got a laugh from Maya, ""
///     "heart reaction from maya"      -> got a love from Maya, ""
enum QueryParser {
    enum Sender {
        case anyone, others, me
    }

    struct Parsed {
        var handles = Set<Int32>()
        /// Who sent it, when no specific person is named.
        var sender = Sender.anyone
        var media: MediaFilter?
        var emoji: EmojiFilter?
        var reaction: ReactionFilter?
        var remainder = ""
        var isStructured: Bool { !handles.isEmpty || media != nil || emoji != nil || reaction != nil }
    }

    /// Words for "whoever", never a contact's name (even if a contact is
    /// literally called Someone). They only act as a filter next to an
    /// attachment filter; otherwise they stay ordinary query words.
    private static let whoever: [String: Sender] = [
        "someone": .others, "somebody": .others, "anyone": .others, "anybody": .others,
        "everyone": .others, "everybody": .others, "people": .others, "they": .others,
        "i": .me, "myself": .me,
    ]

    private static let nouns: [String: MediaFilter] = {
        var table: [String: MediaFilter] = [:]
        func add(_ words: [String], _ kinds: Set<MediaKind>, _ noun: String) {
            for word in words {
                table[word] = MediaFilter(kinds: kinds, noun: noun)
                table[word + "s"] = MediaFilter(kinds: kinds, noun: noun)
            }
        }
        add(["image", "photo", "picture", "pic", "screenshot", "selfie", "gif"], [.image], "photo")
        add(["video", "clip"], [.video], "video")
        add(["audio", "recording", "voice"], [.audio], "audio message")
        add(["pdf"], [.pdf], "PDF")
        add(["file", "document", "doc"], [.pdf, .file], "file")
        add(["attachment"], [.image, .video, .audio, .pdf, .file, .sticker], "attachment")
        add(["sticker"], [.sticker], "sticker")
        add(["link", "website", "url", "site", "webpage"], [.link], "link")
        return table
    }()

    /// Words that only glue a structured query together ("maya *sends a* pdf").
    private static let glue: Set<String> = [
        "send", "sends", "sent", "sending", "share", "shares", "shared", "sharing", "post", "posts", "posted",
        "a", "an", "the", "some", "of", "with", "me", "us", "from", "memo", "memos",
        "message", "messages", "text", "texts", "that", "got", "at", "by", "to",
    ]
    private static let messageNouns: Set<String> = ["message", "messages", "text", "texts"]
    private static let reactionNouns: Set<String> = ["reaction", "reactions", "tapback", "tapbacks", "reacted"]
    private static let vague: [String: Int] = ["several": 3, "many": 3, "multiple": 2, "lots": 3, "bunch": 3, "few": 2, "couple": 2]

    /// `people` maps a lowercased word to the handles of people with that name.
    static func parse(_ query: String, people: (String) -> Set<Int32>?) -> Parsed {
        var parsed = Parsed()
        let words = query.split(separator: " ").map(String.init)
        var consumed = [Bool](repeating: false, count: words.count)
        let keys = words.map { word -> String in
            var key = word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "+")))
            for suffix in ["'s", "’s"] where key.hasSuffix(suffix) { key.removeLast(2) }
            return key
        }

        var whoeverAt: [(Int, Sender)] = []
        // People named so far, by word position. They mean "sent by" unless a
        // reaction claims them as the person who reacted.
        var senderPeople: [Int: Set<Int32>] = [:]
        var reactionNounAt: Int?
        let mentionsMessages = keys.contains(where: messageNouns.contains)

        /// The person or "whoever" word at position `j`, if there is one.
        func subject(at j: Int) -> (handles: Set<Int32>, sender: Sender)? {
            guard keys.indices.contains(j) else { return nil }
            if let sender = whoever[keys[j]] { return ([], sender) }
            if keys[j] == "me" { return ([], .me) }
            if let handles = senderPeople[j] ?? people(keys[j]) { return (handles, .anyone) }
            return nil
        }
        /// Makes the subject at `j` the one who reacted, not the sender.
        func claimReactor(at j: Int, for filter: inout ReactionFilter) -> Bool {
            guard let found = subject(at: j) else { return false }
            filter.byHandles = found.handles
            filter.by = found.sender
            consumed[j] = true
            senderPeople[j] = nil
            whoeverAt.removeAll { $0.0 == j }
            return true
        }

        for (i, key) in keys.enumerated() {
            let typedEmoji = words[i].unicodeScalars.map(\.value).filter(EmojiFilter.isEmoji)
            if !typedEmoji.isEmpty {
                // An emoji typed into the query: find messages containing it.
                parsed.emoji = parsed.emoji ?? EmojiFilter()
                parsed.emoji?.literal += typedEmoji
                consumed[i] = true
            } else if ["emoji", "emojis", "emoticon", "emoticons"].contains(key) {
                // "heart emoji": the word before says which.
                parsed.emoji = parsed.emoji ?? EmojiFilter()
                consumed[i] = true
                if i >= 1, !consumed[i - 1], whoever[keys[i - 1]] == nil, !glue.contains(keys[i - 1]), !keys[i - 1].isEmpty {
                    parsed.emoji?.descriptor = keys[i - 1]
                    consumed[i - 1] = true
                }
            } else if reactionNouns.contains(key) {
                // "heart reaction", "thumbs up reaction", "❤️ reaction", or just "reaction".
                var filter = ReactionFilter()
                consumed[i] = true
                if key == "reacted" {
                    // "messages maya reacted to"
                    _ = claimReactor(at: i - 1, for: &filter)
                    parsed.reaction = filter
                    continue
                }
                reactionNounAt = i
                var j = i - 1
                var direction = ""
                if j >= 1, ["up", "down"].contains(keys[j]), keys[j - 1] == "thumbs" {
                    direction = keys[j]
                    consumed[j] = true
                    j -= 1
                }
                if j >= 0, keys[j] == "sticker" || keys[j] == "stickers" {
                    // "sticker reaction": a sticker put on a message, not one sent as a message.
                    if parsed.media?.kinds == [.sticker] { parsed.media = nil }
                    consumed[j] = true
                    filter.kinds = [.sticker]
                    filter.label = "sticker"
                } else if j == i - 1, let typed = parsed.emoji, !typed.literal.isEmpty, j >= 0, consumed[j] {
                    // The emoji just before was meant as the reaction, not as text.
                    filter.emoji = typed
                    filter.kinds = Set(typed.literal.compactMap { ReactionFilter.glyphs[$0] })
                    filter.label = typed.literal.compactMap { Unicode.Scalar($0).map { String(Character($0)) } }.joined()
                    parsed.emoji = nil
                } else if j >= 0, !consumed[j], whoever[keys[j]] == nil, !glue.contains(keys[j]), !keys[j].isEmpty {
                    let word = keys[j] == "thumbs" ? "thumbs" + direction : keys[j]
                    consumed[j] = true
                    filter.label = keys[j] == "thumbs" ? "thumbs \(direction)" : word
                    if let kind = ReactionFilter.words[word] { filter.kinds = [kind] }
                    if word != "sticker" { filter.emoji = EmojiFilter(descriptor: word == "love" || word == "loved" ? "heart" : word) }
                }
                parsed.reaction = filter
            } else if ReactionFilter.adjectives.contains(key), let kind = ReactionFilter.words[key],
                      (i + 1 < keys.count && messageNouns.contains(keys[i + 1])) || (mentionsMessages && subject(at: i - 1) != nil)
                        || (i + 1 < keys.count && keys[i + 1] == "by" && subject(at: i + 2) != nil) {
                // "liked messages about cars", "messages i loved", "maya liked messages", "liked by me"
                var filter = ReactionFilter(kinds: [kind], label: ["love", "like", "dislike", "laugh", "emphasis", "question"][kind.rawValue])
                _ = claimReactor(at: i - 1, for: &filter)
                parsed.reaction = filter
                consumed[i] = true
            } else if let sender = whoever[key] {
                whoeverAt.append((i, sender))
            } else if let handles = people(key) {
                senderPeople[i] = handles
                consumed[i] = true
            } else if parsed.media == nil, var media = nouns[key] {
                consumed[i] = true
                // A count just before the noun: ">5", "5+", "more than 5", "at least 5", "several".
                var j = i - 1
                while j >= 0, ["of", "a"].contains(keys[j]) { j -= 1 }
                if j >= 0, let vague = vague[keys[j]] {
                    media.minimum = vague
                    for k in max(0, j - 1)...(i - 1) where k == j || ["of", "a"].contains(keys[k]) { consumed[k] = true }
                } else if i >= 1, let (number, strict) = count(words[i - 1]) {
                    consumed[i - 1] = true
                    var more = strict
                    if i >= 2, [">", ">=", "≥"].contains(words[i - 2]) {
                        more = more || words[i - 2] == ">"
                        consumed[i - 2] = true
                    } else if i >= 3, keys[i - 3] == "more", keys[i - 2] == "than" {
                        more = true
                        consumed[i - 3] = true
                        consumed[i - 2] = true
                    } else if i >= 2, keys[i - 2] == "over" {
                        more = true
                        consumed[i - 2] = true
                    } else if i >= 3, keys[i - 3] == "at", keys[i - 2] == "least" {
                        consumed[i - 3] = true
                        consumed[i - 2] = true
                    }
                    media.minimum = max(1, number + (more ? 1 : 0))
                }
                parsed.media = media
            }
        }

        // "liked by maya", "heart reaction from maya": who reacted, named afterwards.
        if var filter = parsed.reaction, filter.byHandles.isEmpty, filter.by == .anyone {
            if let by = keys.firstIndex(of: "by"), claimReactor(at: by + 1, for: &filter) {
                consumed[by] = true
            } else if let noun = reactionNounAt, noun + 1 < keys.count, keys[noun + 1] == "from" {
                _ = claimReactor(at: noun + 2, for: &filter)
            }
            parsed.reaction = filter
        }
        parsed.handles = senderPeople.values.reduce(into: []) { $0.formUnion($1) }

        guard parsed.isStructured else {
            parsed.remainder = query
            return parsed
        }
        if parsed.media != nil || parsed.emoji != nil, let (_, sender) = whoeverAt.first {
            parsed.sender = sender
            for (i, _) in whoeverAt { consumed[i] = true }
        }
        parsed.remainder = zip(words, zip(keys, consumed))
            .filter { !$0.1.1 && !glue.contains($0.1.0) }
            .map(\.0)
            .joined(separator: " ")
        return parsed
    }

    /// "5" -> (5, false); ">5" -> (5, true); ">=5" and "5+" -> (5, false).
    private static func count(_ word: String) -> (Int, Bool)? {
        var digits = Substring(word)
        var strict = false
        if digits.hasPrefix(">=") || digits.hasPrefix("≥") {
            digits = digits.dropFirst(digits.hasPrefix(">=") ? 2 : 1)
        } else if digits.hasPrefix(">") {
            digits = digits.dropFirst()
            strict = true
        }
        if digits.hasSuffix("+") { digits = digits.dropLast() }
        guard let number = Int(digits), number < 1000 else { return nil }
        return (number, strict)
    }
}
