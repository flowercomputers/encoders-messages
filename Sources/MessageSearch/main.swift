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
            hits = store.search(query).hits
            times.append(CFAbsoluteTimeGetCurrent() - started)
        }
        times.sort()
        print(String(format: "\n\"%@\": median %.2f ms, p95 %.2f ms", query, times[100] * 1000, times[190] * 1000))
        for hit in hits.prefix(5) {
            print(String(format: "  %.3f  %@", hit.score, hit.chat))
            for line in hit.lines {
                let files = line.attachments.isEmpty ? "" : " " + line.attachments.map { "<\($0.name)>" }.joined(separator: " ")
                print("        \(line.isMatch ? ">" : " ") \(line.sender): \(line.text.prefix(90))\(files)")
            }
        }
    }
}
