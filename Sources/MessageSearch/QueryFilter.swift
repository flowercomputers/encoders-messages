import Foundation

/// What a message can carry besides text.
enum MediaKind: Int, CaseIterable {
    case image, video, audio, pdf, file, link

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

/// Pulls the structured parts out of a query, leaving the rest for semantic
/// search:
///
///     "maya sends >5 images"        -> from Maya, 6+ photos, ""
///     "sam sends a pdf about taxes" -> from Sam, a PDF, "about taxes"
///     "alex sends a website"     -> from Alex, a link, ""
///     "someone sends me a pdf"        -> from anyone but me, a PDF, ""
enum QueryParser {
    enum Sender {
        case anyone, others, me
    }

    struct Parsed {
        var handles = Set<Int32>()
        /// Who sent it, when no specific person is named.
        var sender = Sender.anyone
        var media: MediaFilter?
        var remainder = ""
        var isStructured: Bool { !handles.isEmpty || media != nil }
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
        add(["attachment"], [.image, .video, .audio, .pdf, .file], "attachment")
        add(["link", "website", "url", "site", "webpage"], [.link], "link")
        return table
    }()

    /// Words that only glue a structured query together ("maya *sends a* pdf").
    private static let glue: Set<String> = [
        "send", "sends", "sent", "sending", "share", "shares", "shared", "sharing", "post", "posts", "posted",
        "a", "an", "the", "some", "of", "with", "me", "us", "from", "memo", "memos",
    ]
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
        for (i, key) in keys.enumerated() {
            if let sender = whoever[key] {
                whoeverAt.append((i, sender))
            } else if let handles = people(key) {
                parsed.handles.formUnion(handles)
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

        guard parsed.isStructured else {
            parsed.remainder = query
            return parsed
        }
        if parsed.media != nil, let (_, sender) = whoeverAt.first {
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
