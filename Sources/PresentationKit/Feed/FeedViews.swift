import Domain
import PhotosUI
import SwiftUI

/// One card. `.list` is the compact version in the feed; `.share` is the fixed 9:16 poster that gets rendered to an image.
public struct PostCardView: View {
    public enum Style { case list, share }

    private let post: ActivityPost
    private let style: Style
    private let footer: AnyView?

    /// - Parameter footer: actions shown at the bottom of a list card (photo, share). Never part of the shared poster.
    public init(post: ActivityPost, style: Style = .list, footer: AnyView? = nil) {
        self.post = post
        self.style = style
        self.footer = footer
    }

    private var isShare: Bool { style == .share }

    private var photoImage: Image? { post.photo.flatMap(Avatar.image(from:)) }

    public var body: some View {
        VStack(alignment: .leading, spacing: isShare ? 22 : 12) {
            if isShare { Spacer(minLength: 0) }
            if !isShare, let photoImage {
                photoImage.resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 200).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        // The photo is mirrored to the student's trainer; say so right where it is, so nobody is surprised.
                        Label(String(localized: "Your trainer can see this photo"), systemImage: "person.2.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                    .accessibilityLabel(String(localized: "Photo"))
                    .accessibilityIdentifier("post-photo-\(post.id)")
            }

            // The title already says what this is ("New PR · Bench", "Workout C"): the kind is just a small icon beside it, not a second label.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: post.kind.systemImage)
                    .font(isShare ? .title3 : .subheadline.weight(.semibold))
                    .foregroundStyle(isShare ? Color.white.opacity(0.85) : Theme.accent)
                Text(verbatim: post.title)
                    .font(isShare ? .system(size: 38, weight: .bold, design: .rounded) : .title3.bold())
                    .foregroundStyle(isShare ? Color.white : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let subtitle = post.subtitle {
                Text(verbatim: subtitle)
                    .font(isShare ? .system(size: 26, weight: .semibold, design: .rounded) : .headline)
                    .foregroundStyle(isShare ? Color.white.opacity(0.95) : Color.primary)
            }

            if !post.stats.isEmpty {
                HStack(alignment: .top, spacing: isShare ? 28 : 20) {
                    ForEach(Array(post.stats.prefix(4).enumerated()), id: \.offset) { _, stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: stat.value).font(isShare ? .title2.bold() : .headline)
                            Text(verbatim: stat.label).font(.caption).opacity(0.75)
                        }
                    }
                }
                .foregroundStyle(isShare ? Color.white : Color.primary)
            }

            if !post.tracks.isEmpty {
                VStack(alignment: .leading, spacing: isShare ? 10 : 6) {
                    ForEach(Array(post.tracks.prefix(isShare ? 3 : 2).enumerated()), id: \.offset) { _, track in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "music.note").font(.footnote)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: track.plays > 1 ? "\(track.title)  ×\(track.plays)" : track.title)
                                    .font(isShare ? .headline : .subheadline.weight(.semibold))
                                Text(verbatim: [track.artist, track.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).opacity(0.75)
                            }
                        }
                    }
                }
                .foregroundStyle(isShare ? Color.white : Color.primary)
            }

            if isShare {
                Spacer(minLength: 0)
                Text(verbatim: "FitCoach").font(.headline.weight(.bold)).foregroundStyle(Color.white.opacity(0.8))
            } else if let footer {
                footer.frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 2)
            }
        }
        .padding(isShare ? 36 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: isShare ? 360 : nil, height: isShare ? 640 : nil, alignment: .leading)
        .background {
            if isShare, let photoImage {
                // The student's own photo behind the poster, darkened so the text stays readable.
                ZStack {
                    photoImage.resizable().scaledToFill()
                    LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                }
                .clipped()
            } else if isShare {
                LinearGradient(colors: [Theme.accent, Color(red: 0.05, green: 0.2, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.card)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("post-card-\(post.id)")
    }
}

/// A quiet round icon button (accent on a faint tint) for secondary actions on a card.
struct SoftCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 40, height: 40)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.22 : 0.12), in: Circle())
    }
}

/// "Add photo" / "Change photo" on a card, plus a way to take it off again.
struct PostPhotoButton: View {
    let post: ActivityPost
    let onChange: (Data?) -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        Group {
            if post.photo == nil {
                PhotosPicker(selection: $item, matching: .images) { Label(String(localized: "Add photo"), systemImage: "photo.badge.plus").labelStyle(.iconOnly) }
                    .accessibilityLabel(String(localized: "Add photo"))
                    .accessibilityHint(String(localized: "Your trainer can see photos you add."))
                    .accessibilityIdentifier("add-photo-\(post.id)")
            } else {
                Menu {
                    PhotosPicker(selection: $item, matching: .images) { Label(String(localized: "Change photo"), systemImage: "photo") }
                    Button(String(localized: "Remove photo"), role: .destructive) { onChange(nil) }
                } label: { Label(String(localized: "Photo"), systemImage: "photo").labelStyle(.iconOnly) }
                    .accessibilityLabel(String(localized: "Photo"))
                    .accessibilityIdentifier("photo-menu-\(post.id)")
            }
        }
        .buttonStyle(SoftCircleButtonStyle())
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self) { onChange(data) }
                item = nil
            }
        }
    }
}

/// The feed tab. Sharing is delegated (`onShare`): the app target owns WhatsApp / Instagram / the system share sheet.
public struct FeedView: View {
    private let model: FeedViewModel
    private let profileButton: AnyView?
    private let onShare: (ActivityPost) -> Void

    /// - Parameter profileButton: the avatar shown at the top-left of every main screen (opens settings).
    public init(model: FeedViewModel, profileButton: AnyView? = nil, onShare: @escaping (ActivityPost) -> Void) {
        self.model = model
        self.profileButton = profileButton
        self.onShare = onShare
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(model.posts) { post in
                        PostCardView(post: post, footer: AnyView(
                            HStack(spacing: 10) {
                                PostPhotoButton(post: post) { data in Task { await model.setPhoto(data, on: post) } }
                                Button { onShare(post) } label: { Label(String(localized: "Share"), systemImage: "square.and.arrow.up").labelStyle(.iconOnly) }
                                    .buttonStyle(SoftCircleButtonStyle())
                                    .accessibilityLabel(String(localized: "Share"))
                                    .accessibilityIdentifier("share-post-\(post.id)")
                            }))
                    }
                    if model.isEmpty {
                        ContentUnavailableView(String(localized: "Nothing here yet"), systemImage: "sparkles",
                                               description: Text(String(localized: "Finish a workout and your first card shows up here.")))
                            .padding(.top, 60)
                    }
                }
                .padding(16)
                .adaptiveContentWidth()
            }
            .background(Theme.background)
            .navigationTitle(String(localized: "Feed"))
            .toolbar { ProfileToolbarSlot(profileButton ?? AnyView(EmptyView())) }
            .task { await model.run() }
        }
    }
}

/// "Share to…": one row per destination. Which ones work is the app's call (`isAvailable`).
public struct ShareDestinationSheet: View {
    private let post: ActivityPost
    private let isAvailable: (ShareDestination) -> Bool
    private let onSelect: (ShareDestination) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(post: ActivityPost, isAvailable: @escaping (ShareDestination) -> Bool, onSelect: @escaping (ShareDestination) -> Void) {
        self.post = post
        self.isAvailable = isAvailable
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ShareDestination.allCases, id: \.self) { destination in
                        Button {
                            onSelect(destination)
                            dismiss()
                        } label: {
                            HStack {
                                Text(verbatim: destination.displayName)
                                Spacer()
                                if !isAvailable(destination) {
                                    Text(String(localized: "Not available")).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!isAvailable(destination))
                        .accessibilityIdentifier("share-\(destination.rawValue)")
                    }
                } footer: {
                    Text(String(localized: "Gymrats has no public sharing API: it receives the card through the system share sheet."))
                }
            }
            .navigationTitle(String(localized: "Share"))
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

private extension View {
    @ViewBuilder func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
