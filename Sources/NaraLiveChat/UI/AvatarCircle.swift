import ImageIO
import SwiftUI
import UIKit

/// The sender's avatar: the photo once its URL yields one, else the initial on the primary color.
/// The frame is fixed, so the row does not move when the photo arrives or fails to.
struct AvatarCircle: View {
    let avatar: ThreadAvatar
    let size: CGFloat
    let font: Font
    let palette: SdkThemeRules.Palette

    @Environment(\.displayScale) private var displayScale
    /// The photo last loaded, with the URL it came from — a stale photo is never shown under a new URL.
    @State private var loaded: Loaded? = nil

    private struct Loaded {
        let url: String
        let image: UIImage
    }

    private var image: UIImage? {
        guard let loaded, loaded.url == avatar.photoUrl else { return nil }
        return loaded.image
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(rgb: palette.primary))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                Text(avatar.initial)
                    .font(font)
                    .foregroundColor(Color(rgb: palette.onPrimary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatar.source)
        .task(id: avatar.photoUrl) {
            guard let url = avatar.photoUrl, loaded?.url != url else { return }
            guard let fetched = await AvatarImages.image(at: url, edge: size, scale: displayScale) else { return }
            loaded = Loaded(url: url, image: fetched)
        }
    }
}

/// Photos decoded at the size they are shown at, kept by URL and size.
enum AvatarImages {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    /// The server keeps avatars at 500 KB; a photo past this is dropped, its bytes never reach the decoder.
    private static let maxBytes = 4 * 1024 * 1024

    static func image(at url: String, edge: CGFloat, scale: CGFloat) async -> UIImage? {
        let side = max(1, Int((edge * scale).rounded(.up)))
        let key = "\(side)|\(url)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard
            let request = URL(string: url).map({ URLRequest(url: $0, timeoutInterval: 20) }),
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            data.count <= maxBytes
        else { return nil }
        guard let image = await Task.detached(priority: .userInitiated, operation: { Self.decode(data, maxPixel: side) }).value else { return nil }
        cache.setObject(image, forKey: key, cost: cost(image))
        return image
    }

    /// Scales while decoding, so a 4000px photo never exists at full size.
    private static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honors the EXIF orientation, which a plain decode leaves to the caller.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func cost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
