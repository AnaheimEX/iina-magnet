//
//  CachedAsyncImage.swift
//  IinaMagnet
//
//  A drop-in async image that caches decoded posters in an NSCache, so scrolling
//  the poster wall (which churns offscreen/onscreen cells) doesn't re-download +
//  re-decode the same remote covers. SwiftUI's AsyncImage keeps no cross-view
//  cache, so every cell re-fetches; this keeps a shared in-memory one.

import SwiftUI
import AppKit

@MainActor
final class PosterImageCache {
    static let shared = PosterImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    init(countLimit: Int = 400) { cache.countLimit = countLimit }

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// Loads `url` (cache-first) and fills its frame; shows `placeholder` until the
/// image is ready or if loading fails.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url else { return }
        if let cached = PosterImageCache.shared.image(for: url) { image = cached; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let loaded = NSImage(data: data) else { return }
        PosterImageCache.shared.insert(loaded, for: url)
        // `.task(id: url)` cancels this task when the cell is recycled for another
        // url; drop a result that finished downloading just before that, so we
        // don't paint the previous poster onto the reused card.
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
