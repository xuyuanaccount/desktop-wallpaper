import Foundation
import ImageIO
import UniformTypeIdentifiers

func loadWallpaperImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let type = CGImageSourceGetType(source) as String?,
          type == UTType.jpeg.identifier || type == UTType.png.identifier,
          CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }

    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    let orientation = properties?[kCGImagePropertyOrientation as String] as? Int ?? 1
    if orientation != 1 {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
