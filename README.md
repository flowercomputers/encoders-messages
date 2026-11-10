# Message Search

Semantic search over your Apple Messages history, as a small native macOS app.
Type an idea, get the messages closest in meaning, click one (or press Return)
to jump to it in Messages.

It is an experiment in using [encoders](https://github.com/flowercomputers/encoders)
for an ordinary computer task. Embedding is fast enough that the app keeps
**no index on disk**: every launch reads `chat.db`, embeds every message, and is
ready before the window finishes appearing. Nothing leaves your Mac.

## Install

Download the DMG from the [latest release](../../releases/latest), drag
Message Search to Applications, and open it. Apple silicon, macOS 14 or later.

The build is signed but **not notarized**, so the first time macOS will refuse
to open it: go to System Settings → Privacy & Security and choose Open Anyway.

## Build and run

Needs Xcode (Swift 5.9+) and Rust 1.88+.

```bash
./build.sh
```

```bash
open "build/Message Search.app"
```

The first launch asks for **Full Disk Access** (System Settings → Privacy &
Security), which is what macOS requires to read `~/Library/Messages/chat.db`.
It also asks for Contacts, only to show names instead of phone numbers; saying
no is fine.

The first `cargo` build downloads the embedding model from Hugging Face and
compiles it into the binary.

## How it works

| Piece | Where | What it does |
| --- | --- | --- |
| Reader | `Sources/MessageSearch/MessageStore.swift` | Opens `chat.db` read-only, pulls message text into one contiguous UTF-8 buffer. Decodes `attributedBody` (where modern macOS keeps the text) by scanning the typedstream bytes directly, with `NSUnarchiver` as a fallback. |
| Core | `core/src/lib.rs` | Rust static library. Embeds with `encoders` (`bekko-static-v1-slim-100k`, 256 dimensions), stores each vector as 256 int8 + one float, and answers a query with a parallel brute-force cosine scan. |
| UI | `Sources/MessageSearch/ContentView.swift`, `AppModel.swift` | SwiftUI. Every keystroke runs a full search. Arrow keys move, Return or a click opens the message. New messages are picked up every 2 seconds. |

Opening a message uses `sms://open?message-guid=<guid>`, the URL scheme
Spotlight uses for Messages results. It is undocumented, so Apple could change it.

## What gets matched

- **Exchanges, not single messages.** Each message is embedded together with up
  to two messages before and after it in the same chat (within 20 minutes),
  with the message itself counted twice. Results show that exchange.
- **Short texts are pulled down**, so "What news" does not beat a real
  conversation that mentions news.
- **A contact's name in the query is a filter**, not a word to match: "maya
  finds something funny" searches "finds something funny" among messages Maya
  sent. Names that are everyday words ("will", "may", ...) are left alone.
- **Attachments and links are filters too**, read from chat.db's attachment
  table (photo, video, audio, PDF, file) and from `http(s)://` in the text:
  "maya sends >5 images", "sam sends a pdf", "alex sends a website".
  Counts (">5", "5+", "at least 5", "several") add up across one person's
  uninterrupted run of messages. With no other words left, matches are listed
  newest first; otherwise ("sam pdf about taxes") they are ranked by meaning.
  Attachment-only messages are embedded as "[2 photos]" or "[PDF: lease.pdf]",
  so file names are searchable. Results show the files themselves: Quick Look
  thumbnails for photos and videos (`AttachmentViews.swift`), a named chip for
  other files, and an icon when the file is not on this Mac. The parser is `Sources/MessageSearch/QueryFilter.swift`.
- Overlapping results from one exchange are collapsed to the best one.

The model is a static embedding: it matches on what an exchange is *about*, not
on what is *happening* in it. "funny" finds "LOL"; "news about something" finds
talk that mentions news, not someone announcing a new job.

## Numbers

On a synthetic database of 454,546 messages (10 performance cores, Apple silicon):

- read from SQLite: ~240 ms
- embed every message's exchange: ~125 ms
- search, per keystroke: ~1.3 ms median, 1.9 ms p95
- memory for vectors: 260 bytes per message (~118 MB here)

Reproduce without touching real messages:

```bash
swiftc -O scripts/make_test_db.swift -o /tmp/make_test_db -lsqlite3 && /tmp/make_test_db /tmp/test.db 500000
```

```bash
.build/release/MessageSearch --db /tmp/test.db --bench "my pet is overweight" "housing costs going up"
```

`--db <path>` and `--query <text>` also work with the windowed app.

`scripts/make_dmg.sh` builds the app and packs `build/MessageSearch-<version>.dmg`.

## Knobs

The model, width and quantization are one line in `core/Cargo.toml`. Since
nothing is persisted, change it and rebuild; there is no index to migrate.
