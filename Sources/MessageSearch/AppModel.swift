import AppKit
import Foundation

/// UI state. All store work happens on one serial queue; searches are a few
/// milliseconds, so every keystroke simply runs one.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case needsAccess(String)
        case ready
    }

    @Published var query = "" {
        didSet { if query != oldValue { search() } }
    }
    @Published private(set) var hits: [Hit] = []
    /// The people / attachment filter found in the query, or "".
    @Published private(set) var filter = ""
    /// The history laid out in time, and where the current matches fall on it.
    @Published private(set) var axis = TimeAxis()
    @Published private(set) var timeline: [Float] = []
    /// A year picked on the timeline; results are limited to it.
    @Published var selectedYear: Int? {
        didSet { if selectedYear != oldValue { search() } }
    }
    /// False once every result has been loaded.
    @Published private(set) var canLoadMore = false
    private var loadingMore = false
    @Published var selection = 0
    @Published private(set) var phase = Phase.loading
    @Published private(set) var indexed = 0
    @Published private(set) var stats = LoadStats()
    @Published private(set) var searchSeconds = 0.0

    private let store: MessageStore
    private let engine = DispatchQueue(label: "message-search.engine", qos: .userInteractive)
    private var generation = 0
    private var loading = false
    private var timer: Timer?

    init(path: String = MessageStore.defaultPath, query: String = "") {
        store = MessageStore(path: path)
        self.query = query
    }

    func start() {
        load()
        // Picks up new messages, and retries while waiting for Full Disk Access.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
        // Contact names only make sense for (and are only requested with) the real database.
        guard store.path == MessageStore.defaultPath else { return }
        ContactBook.load { [weak self] names in
            guard let self, !names.isEmpty else { return }
            self.engine.async {
                self.store.contacts = names
                DispatchQueue.main.async { self.search() }
            }
        }
    }

    private func load() {
        guard !loading else { return }
        loading = true
        let store = store
        engine.async {
            let result = Result {
                try store.loadNew { count in
                    DispatchQueue.main.async { self.indexed = count }
                }
            }
            let stats = store.stats
            let axis = store.axis
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let added):
                    self.stats = stats
                    if added > 0 || self.axis.volume.isEmpty { self.axis = axis }
                    self.indexed = stats.messages
                    let wasReady = self.phase == .ready
                    self.phase = .ready
                    if added > 0 || !wasReady { self.search() }
                case .failure(let error):
                    if self.phase != .ready {
                        if case StoreError.cannotRead(let message) = error {
                            self.phase = .needsAccess(message)
                        } else {
                            self.phase = .needsAccess("\(error)")
                        }
                    }
                }
            }
        }
    }

    private func search() {
        generation += 1
        let generation = generation
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            hits = []
            timeline = []
            canLoadMore = false
            filter = ""
            selection = 0
            return
        }
        let store = store
        let year = selectedYear
        engine.async {
            let started = CFAbsoluteTimeGetCurrent()
            let results = store.search(query, token: generation, year: year)
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            DispatchQueue.main.async {
                guard generation == self.generation else { return }  // a newer keystroke won
                self.hits = results.hits
                self.timeline = results.timeline
                self.canLoadMore = !results.exhausted
                self.loadingMore = false
                self.filter = results.filter
                self.selection = 0
                self.searchSeconds = elapsed
            }
        }
    }

    func moveSelection(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + delta, 0), hits.count - 1)
        loadMoreIfNeeded(near: selection)
    }

    /// Results are unbounded. Called as rows come on screen: when the user is
    /// within a screenful of the end, fetch the next page.
    func loadMoreIfNeeded(near index: Int) {
        guard canLoadMore, !loadingMore, index >= hits.count - 20 else { return }
        loadingMore = true
        let generation = generation
        let store = store
        engine.async {
            let page = store.nextPage(token: generation)
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.loadingMore = false
                guard let page else { return }
                self.hits.append(contentsOf: page.hits)
                self.canLoadMore = !page.exhausted
            }
        }
    }

    func openSelection() {
        guard hits.indices.contains(selection) else { return }
        open(hits[selection])
    }

    /// Opens Messages scrolled to the message. `sms://open?message-guid=` is
    /// the (undocumented) URL scheme Spotlight uses for its Messages results.
    func open(_ hit: Hit) {
        let store = store
        engine.async {
            guard let guid = store.guid(forRowID: hit.rowID) else { return }
            var components = URLComponents()
            components.scheme = "sms"
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "message-guid", value: guid)]
            guard let url = components.url else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
