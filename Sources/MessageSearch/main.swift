import CMsgCore
import SwiftUI

// Message Search [--db <path>] [--query <text>] [--bench <query>...]
//
//   --db     read this database instead of ~/Library/Messages/chat.db
//   --query  start with this search already typed
//   --bench  no window: load, time each query, print the top results, exit

let arguments = Array(CommandLine.arguments.dropFirst())
var databasePath = MessageStore.defaultPath
if let i = arguments.firstIndex(of: "--db"), i + 1 < arguments.count {
    databasePath = arguments[i + 1]
}

var initialQuery = ""
if let i = arguments.firstIndex(of: "--query"), i + 1 < arguments.count {
    initialQuery = arguments[i + 1]
}

if let i = arguments.firstIndex(of: "--bench") {
    runBenchmark(path: databasePath, queries: Array(arguments[(i + 1)...]).filter { $0 != "--db" && $0 != databasePath })
    exit(0)
}

struct MessageSearchApp: App {
    @StateObject private var model = AppModel(path: databasePath, query: initialQuery)

    var body: some Scene {
        Window("Message Search", id: "main") {
            ContentView(model: model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 720, height: 600)
        .windowStyle(.hiddenTitleBar)
    }
}

MessageSearchApp.main()

func runBenchmark(path: String, queries: [String]) {
    let store = MessageStore(path: path)
    do {
        try store.loadNew()
    } catch {
        print("Could not read \(path): \(error)")
        exit(1)
    }
    let stats = store.stats
    print(String(format: "%d messages, %d dimensions: read %.0f ms, embedded %.0f ms",
                 stats.messages, ms_dimensions(), stats.readSeconds * 1000, stats.embedSeconds * 1000))

    for query in queries {
        var times: [Double] = []
        var hits: [Hit] = []
        for _ in 0..<200 {
            let started = CFAbsoluteTimeGetCurrent()
            hits = store.search(query, token: 1).hits
            times.append(CFAbsoluteTimeGetCurrent() - started)
        }
        times.sort()
        print(String(format: "\n\"%@\": median %.2f ms, p95 %.2f ms", query, times[100] * 1000, times[190] * 1000))
        // Page on from the first page, as scrolling would.
        var seen = Set(hits.map(\.id))
        var total = hits.count
        var ordered = true
        var last = hits.last?.score ?? 0
        let started = CFAbsoluteTimeGetCurrent()
        var pages = 0
        while pages < 50, let page = store.nextPage(token: 1), !page.hits.isEmpty {
            pages += 1
            for hit in page.hits {
                ordered = ordered && hit.score <= last && seen.insert(hit.id).inserted
                last = hit.score
            }
            total += page.hits.count
            if page.exhausted { break }
        }
        print(String(format: "  %d more pages: %d results, %.2f ms per page, %@", pages, total,
                     pages > 0 ? (CFAbsoluteTimeGetCurrent() - started) * 1000 / Double(pages) : 0,
                     ordered ? "in order, no repeats" : "OUT OF ORDER OR REPEATED"))
        for hit in hits.prefix(5) {
            print(String(format: "  %.3f  %@", hit.score, hit.chat))
            for line in hit.lines {
                let files = line.attachments.isEmpty ? "" : " " + line.attachments.map { "<\($0.name)>" }.joined(separator: " ")
                print("        \(line.isMatch ? ">" : " ") \(line.sender): \(line.text.prefix(90))\(files)")
            }
        }
    }
}
