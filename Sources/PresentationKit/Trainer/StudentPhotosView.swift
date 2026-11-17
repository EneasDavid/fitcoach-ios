import Domain
import Observation
import SwiftUI

/// The pictures a student attached to their workout cards — all the trainer sees of the feed (cards, and the songs on them, stay private).
@MainActor
@Observable
public final class StudentPhotosViewModel {
    public private(set) var photos: [SharedPhoto] = []
    public private(set) var isLoaded = false
    public var selected: SharedPhoto?

    @ObservationIgnored private let studentID: UserID
    @ObservationIgnored private let repository: any SharedPhotoRepository

    public init(studentID: UserID, photos: any SharedPhotoRepository) {
        self.studentID = studentID
        self.repository = photos
    }

    public func run() async {
        for await all in repository.observePhotos(studentID: studentID) {
            photos = all.filter { !$0.meta.isDeleted && !$0.photo.isEmpty }.sorted { $0.takenAt > $1.takenAt }
            isLoaded = true
            if let current = selected, !photos.contains(where: { $0.id == current.id }) { selected = nil }
        }
    }

    public var isEmpty: Bool { isLoaded && photos.isEmpty }

    /// The photos that belong to one workout (the day view shows them next to its sets).
    public func photos(forLog id: LogID) -> [SharedPhoto] { photos.filter { $0.logID == id } }
}

public struct StudentPhotosView: View {
    private let model: StudentPhotosViewModel
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    public init(model: StudentPhotosViewModel) { self.model = model }

    public var body: some View {
        ScrollView {
            if model.isEmpty {
                ContentUnavailableView(String(localized: "No photos yet"), systemImage: "photo.on.rectangle.angled",
                                       description: Text(String(localized: "When your student adds a photo to a workout, it shows up here.")))
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(model.photos, id: \.id) { item in
                        Button { model.selected = item } label: { cell(item) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.caption)
                            .accessibilityIdentifier("student-photo-\(item.id)")
                    }
                }
                .padding(12)
                .adaptiveContentWidth()
            }
        }
        .background(Theme.background)
        .navigationTitle(String(localized: "Photos"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.run() }
        .sheet(item: Binding(get: { model.selected }, set: { model.selected = $0 })) { item in PhotoDetail(photo: item) }
    }

    private func cell(_ item: SharedPhoto) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = Avatar.image(from: item.photo) { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.2) }
            }
            .overlay(alignment: .bottomLeading) {
                Text(item.takenAt, format: .dateTime.day().month(.abbreviated))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PhotoDetail: View {
    let photo: SharedPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let image = Avatar.image(from: photo.photo) {
                        image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    Text(verbatim: photo.caption).font(.headline)
                    Text(photo.takenAt, format: .dateTime.weekday(.wide).day().month(.wide).year()).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle(String(localized: "Photo"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
        }
        .tint(Theme.accent)
    }
}
