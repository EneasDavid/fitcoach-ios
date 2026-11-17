import Domain
import PresentationKit
import SwiftUI
import UIKit

/// Turns a post into pixels and hands it to WhatsApp, Instagram Stories or the system share sheet.
///
/// Honest limits: WhatsApp takes text through its URL scheme; Instagram Stories takes an image through the pasteboard and
/// needs the app's Meta App ID; Gymrats publishes no sharing API, so it receives the card through the system share sheet
/// like any other app. Both URL schemes must be listed in `LSApplicationQueriesSchemes` (see project.yml).
@MainActor
struct ShareActions {
    let config: AppConfig

    /// 1080 × 1920 PNG of the poster card.
    func image(for post: ActivityPost) -> UIImage? {
        let renderer = ImageRenderer(content: PostCardView(post: post, style: .share).environment(\.colorScheme, .dark))
        renderer.scale = 3
        return renderer.uiImage
    }

    func isAvailable(_ destination: ShareDestination) -> Bool {
        switch destination {
        case .whatsapp: return UIApplication.shared.canOpenURL(URL(string: "whatsapp://")!)
        case .instagramStories: return config.facebookAppID != nil && UIApplication.shared.canOpenURL(URL(string: "instagram-stories://")!)
        case .gymrats, .more: return true
        }
    }

    func share(_ post: ActivityPost, to destination: ShareDestination) {
        let text = ShareTextComposer.text(for: post)
        switch destination {
        case .whatsapp:
            var components = URLComponents(string: "whatsapp://send")!
            components.queryItems = [URLQueryItem(name: "text", value: text)]
            if let url = components.url { UIApplication.shared.open(url) }
        case .instagramStories:
            guard let appID = config.facebookAppID, let png = image(for: post)?.pngData(),
                  let url = URL(string: "instagram-stories://share?source_application=\(appID)") else { return systemSheet(post, text) }
            UIPasteboard.general.setItems([["com.instagram.sharedSticker.backgroundImage": png]],
                                          options: [.expirationDate: Date().addingTimeInterval(300)])
            UIApplication.shared.open(url)
        case .gymrats, .more:
            systemSheet(post, text)
        }
    }

    private func systemSheet(_ post: ActivityPost, _ text: String) {
        var items: [Any] = [text]
        if let image = image(for: post) { items.insert(image, at: 0) }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        controller.popoverPresentationController?.sourceView = top?.view
        top?.present(controller, animated: true)
    }
}
