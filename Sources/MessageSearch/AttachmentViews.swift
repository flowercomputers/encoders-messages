import QuickLookThumbnailing
import SwiftUI

/// The attachments of one message: thumbnails for photos and videos, labelled
/// chips for everything else.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    let dimmed: Bool
    let onAccent: Bool

    private static let limit = 8

    var body: some View {
        let visual = attachments.filter { $0.kind == .image || $0.kind == .video || $0.kind == .sticker }
        let other = attachments.filter { $0.kind != .image && $0.kind != .video && $0.kind != .sticker }
        VStack(alignment: .leading, spacing: 4) {
            if !visual.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(visual.prefix(Self.limit).enumerated()), id: \.offset) { _, attachment in
                        Thumbnail(attachment: attachment, onAccent: onAccent)
                    }
                    if visual.count > Self.limit {
                        Text("+\(visual.count - Self.limit)")
                            .font(.caption)
                            .foregroundStyle(onAccent ? Color.white.opacity(0.8) : Color.secondary)
                    }
                }
            }
            ForEach(Array(other.enumerated()), id: \.offset) { _, attachment in
                FileChip(attachment: attachment, onAccent: onAccent)
            }
        }
        .opacity(dimmed ? 0.7 : 1)
    }
}

/// A photo or video frame, or an icon when the file is not on this Mac.
private struct Thumbnail: View {
    let attachment: Attachment
    let onAccent: Bool
    @State private var image: NSImage?

    private static let side: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(onAccent ? Color.white.opacity(0.2) : Color.primary.opacity(0.07))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: attachment.kind.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(onAccent ? Color.white.opacity(0.8) : Color.secondary)
            }
            if attachment.kind == .video, image != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(attachment.name)
        .task(id: attachment.path) {
            image = await ThumbnailCache.shared.thumbnail(for: attachment.path, side: Self.side)
        }
    }
}

/// A PDF, document or audio message: icon and file name.
private struct FileChip: View {
    let attachment: Attachment
    let onAccent: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.kind.symbol)
            Text(attachment.kind == .audio ? "Audio message" : attachment.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
        .foregroundStyle(onAccent ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(onAccent ? Color.white.opacity(0.2) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

extension MediaKind {
    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .file: "doc"
        case .link: "link"
        case .sticker: "face.smiling"
        }
    }
}

/// Thumbnails made by Quick Look (so HEIC, Live Photos and video all work),
/// kept in memory so scrolling and retyping never regenerate them.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let missing = NSCache<NSString, NSNumber>()

    init() {
        cache.countLimit = 2000
    }

    func thumbnail(for path: String, side: CGFloat) async -> NSImage? {
        let key = path as NSString
        if let image = cache.object(forKey: key) { return image }
        if path.isEmpty || missing.object(forKey: key) != nil { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage else {
            missing.setObject(1, forKey: key)  // not downloaded, deleted, or unreadable
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
