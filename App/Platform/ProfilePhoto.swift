import UIKit

/// Turns whatever the photo picker returns into a small, square-ish JPEG (≤ 512 px, ~100 KB) — an avatar doesn't need more, and
/// the photo is stored on the device only (encrypted at rest), so smaller is also less personal data lying around.
enum ProfilePhoto {
    static func process(_ data: Data, maxSide: CGFloat = 512, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: quality)
    }

    /// A generated picture for demo data (a gym-selfie stand-in): no asset to ship, and nothing personal in it.
    static func demoPhoto() -> Data? {
        let size = CGSize(width: 900, height: 700)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.05, green: 0.55, blue: 0.45, alpha: 1).cgColor, UIColor(red: 0.08, green: 0.2, blue: 0.35, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.withAlphaComponent(0.9).setFill()
            for (x, w) in [(250.0, 60.0), (330.0, 30.0), (540.0, 30.0), (570.0, 60.0)] { UIBezierPath(roundedRect: CGRect(x: x, y: 250, width: w, height: 200), cornerRadius: 12).fill() }
            UIBezierPath(roundedRect: CGRect(x: 360, y: 340, width: 180, height: 20), cornerRadius: 10).fill()
        }
        return image.jpegData(compressionQuality: 0.7)
    }
}
