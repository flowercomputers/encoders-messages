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
| Core | `core/src/lib.rs` | Rust static library. Embeds with `encoders` (`bekko-static-v1-slim-100k`, 256 dimensions) into three layers of int8 vectors, and answers a query with a parallel brute-force scan that blends the layers. |
| UI | `Sources/MessageSearch/ContentView.swift`, `AppModel.swift` | SwiftUI. Every keystroke runs a full search. Arrow keys move, Return or a click opens the message. New messages are picked up every 2 seconds. |

Opening a message uses `sms://open?message-guid=<guid>`, the URL scheme
Spotlight uses for Messages results. It is undocumented, so Apple could change it.

## What gets matched

- **Three granularities, blended.** Every message is embedded three ways: on
  its own, as part of its *exchange* (two messages either side), and as part
  of its *sitting* (the whole stretch of conversation, until a 30-minute
  pause). A search scores all three and blends them, so a specific phrase, a
  back-and-forth, and "that conversation about moving" can all be found.
  Results show the exchange. The weights and chunking live in `SearchSettings`.
- **No incremental indexing.** When a message arrives, everything is embedded
  again. It takes a fraction of a second, and no result is ever stale.
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
- **Emoji are a filter as well.** The embedding model cannot see emoji, so
  the app indexes which emoji each message contains and matches them by Unicode
  name: "someone sends heart emoji" finds ❤ 💙 😍 and so on, "fire emoji" finds
  🔥, and typing an emoji into the query finds messages containing it.
- **Reactions and stickers too.** Tapbacks carry no text for encoders to
  embed, so they narrow the messages it then ranks: "liked messages about
  cars" is "about cars" among messages that got a 👍. Also "messages with a
  heart reaction", "fire reaction" (emoji tapbacks, by name), "❤️ reaction",
  "sticker reaction", and "maya sends a sticker". Queries can say who
  reacted: "messages i loved", "messages maya laughed at", "liked by me about
  cars", "heart reaction from maya". Results show the reactions each message
  received.
- **A timeline of the matches.** Under the search field, the whole history is
  drawn as a strip of time: grey for how much was said, colour for where the
  strong matches fall. It is recomputed on every keystroke by scoring every
  message (`ms_histogram`), one more full pass of a couple of milliseconds.
  Click a year to narrow the results to it.
- Overlapping results from one exchange are collapsed to the best one.
- **Results are unbounded.** The list loads 60 at a time as you scroll. The
  core takes a (score, index) cursor and returns the next best matches after
  it, so each page is one more scan (~1 ms) and nothing is computed or kept for
  results you never scroll to.

The model is a static embedding: it matches on what an exchange is *about*, not
on what is *happening* in it. "funny" finds "LOL"; "news about something" finds
talk that mentions news, not someone announcing a new job.

## Numbers

On a synthetic database of 454,546 messages (10 performance cores, Apple silicon):

- read from SQLite: ~240 ms
- embed everything, at all three granularities: ~250 ms
- search plus timeline, per keystroke: ~4.5 ms median
- memory for vectors: about 600 bytes per message (~270 MB here)

Reproduce without touching real messages:

```bash
swiftc -O scripts/make_test_db.swift -o /tmp/make_test_db -lsqlite3 && /tmp/make_test_db /tmp/test.db 500000
```

```bash
.build/release/MessageSearch --db /tmp/test.db --bench "my pet is overweight" "housing costs going up"
```

`--db <path>` and `--query <text>` also work with the windowed app.

`scripts/release.sh` builds a notarized `build/MessageSearch-<version>.dmg`,
signing and notarizing through the Apple account Xcode is signed in to.

## Knobs

The model, width and quantization are one line in `core/Cargo.toml`. Since
nothing is persisted, change it and rebuild; there is no index to migrate.
