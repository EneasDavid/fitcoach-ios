import AVKit
import Domain
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public extension View {
    /// A single "Done" above the keyboard for the whole screen (numeric keypads have no return key).
    /// Attach it once per screen: attaching it to every field would show one button per field.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) {
                    #if canImport(UIKit)
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    #endif
                }
                .accessibilityIdentifier("keyboard-done")
            }
        }
    }
}

// MARK: - Number entry: type it (numeric keypad only) or nudge it with − / +

/// One labelled number with big −/+ buttons and a field that opens **only the numeric keypad**.
/// Tapping the field clears it so the student just types the new value (the old one stays visible as the
/// placeholder); leaving it empty keeps the old value. A locked field is shown dimmed with a padlock.
struct NumberStepper: View {
    let title: String
    let unit: String
    let value: Double
    let step: Double
    var isLocked = false
    var allowsDecimals = true
    let idPrefix: String
    let onSet: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(verbatim: title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                if isLocked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                Button { onSet(value - step) } label: { Image(systemName: "minus") }
                    .buttonStyle(RoundIconButtonStyle())
                    .disabled(isLocked)
                    .accessibilityLabel(String(localized: "Decrease \(title)"))
                    .accessibilityIdentifier("\(idPrefix)-minus")

                VStack(spacing: 0) {
                    TextField(format(value), text: $text)
                        .font(.title2.weight(.bold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        #if os(iOS)
                        .keyboardType(allowsDecimals ? .decimalPad : .numberPad)
                        #endif
                        .disabled(isLocked)
                        .accessibilityIdentifier("\(idPrefix)-field")
                        .accessibilityLabel(title)
                    if !unit.isEmpty { Text(verbatim: unit).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                }
                .frame(minWidth: 60, maxWidth: .infinity, minHeight: 52)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button { onSet(value + step) } label: { Image(systemName: "plus") }
                    .buttonStyle(RoundIconButtonStyle())
                    .disabled(isLocked)
                    .accessibilityLabel(String(localized: "Increase \(title)"))
                    .accessibilityIdentifier("\(idPrefix)-plus")
            }
        }
        .opacity(isLocked ? 0.55 : 1)
        .onAppear { text = format(value) }
        .onChange(of: value) { _, new in if !focused { text = format(new) } }
        .onChange(of: text) { _, new in
            guard focused, let parsed = parse(new) else { return }
            onSet(parsed)
        }
        .onChange(of: focused) { _, isFocused in text = isFocused ? "" : format(value) }
    }

    private func format(_ number: Double) -> String { allowsDecimals ? LoadFormat.kg(number) : String(Int(number)) }

    private func parse(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : Double(cleaned)
    }
}

// MARK: - Exercise media (video, poster, placeholder)

/// Demonstration video: **always silent**, no controls, loops. Whether it starts by itself is `MediaPolicy`'s call: on Wi-Fi it
/// does (a muted loop is what makes an exercise understandable at a glance); with "reduce motion & data" on, off Wi-Fi, or in Low
/// Power Mode it waits for a tap and nothing is downloaded until then (clips can be tens of MB). It never touches the student's
/// music (the audio session is "ambient, mix with others"). Tapping the playing video pauses it.
struct ExerciseMediaView: View {
    let exercise: Exercise?
    let title: String
    let isLoading: Bool

    @Environment(MediaPolicy.self) private var policy: MediaPolicy?
    @State private var isPlaying = false

    private var autoplays: Bool { policy?.allowsAutoplay ?? !ProcessInfo.processInfo.isLowPowerModeEnabled }

    var body: some View {
        ZStack {
            poster                                          // sits under the video until its first frame arrives
            if isPlaying, let url = exercise?.videoURL {
                SilentLoopingVideo(url: url)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)                                 // fixed height: a portrait clip must not push the set controls off-screen
        .clipped()
        .background(Color.black.opacity(0.85))
        .overlay(alignment: .bottomLeading) {
            if let credit = exercise?.mediaCredit {
                Text(verbatim: credit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(6)
                    .shadow(radius: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .onAppear { isPlaying = autoplays }
        .onChange(of: exercise?.id) { _, _ in isPlaying = autoplays }
        // Switching to mobile data (or turning the saver on) while a clip plays stops it.
        .onChange(of: policy?.allowsAutoplay) { _, allowed in if allowed == false { isPlaying = false } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exercise-media")
    }

    @ViewBuilder
    private var poster: some View {
        ZStack {
            if let image = exercise?.imageURL, policy?.allowsPosterDownload ?? true {
                AsyncImage(url: image) { phase in
                    if case .success(let loaded) = phase { loaded.resizable().scaledToFill() } else { placeholder }
                }
            } else {
                placeholder
            }
            if exercise?.videoURL != nil, !isPlaying {
                Button { isPlaying = true } label: {
                    Image(systemName: "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 60, height: 60)
                        .background(Theme.accent, in: Circle())
                }
                .accessibilityLabel(String(localized: "Play demonstration video"))
                .accessibilityIdentifier("play-video")
                .overlay(alignment: .bottom) {
                    if let reason = policy?.pauseReason {
                        Text(verbatim: reason.caption).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                            .fixedSize().offset(y: 34)
                    }
                }
            } else if isLoading {
                ProgressView().tint(.white)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.rest.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 40)).foregroundStyle(.white.opacity(0.9))
        }
    }
}

#if canImport(UIKit)
/// A bare `AVPlayerLayer`: no transport controls, no volume UI — just the picture.
private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct SilentLoopingVideo: View {
    let url: URL
    @State private var player = AVPlayer()
    @State private var isPaused = false

    var body: some View {
        PlayerSurface(player: player)
            .contentShape(Rectangle())
            .onTapGesture {
                isPaused.toggle()
                isPaused ? player.pause() : player.play()
            }
            .onAppear {
                // Ambient + mix: never interrupts or ducks the music the student is listening to.
                try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback, options: [.mixWithOthers])
                player.isMuted = true
                player.volume = 0
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.play()
            }
            .onDisappear { player.pause() }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
                player.seek(to: .zero)
                player.play()
            }
            .accessibilityLabel(String(localized: "Demonstration video, muted"))
            .accessibilityIdentifier("exercise-video")
    }

    private struct PlayerSurface: UIViewRepresentable {
        let player: AVPlayer
        func makeUIView(context: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.playerLayer.player = player
            view.playerLayer.videoGravity = .resizeAspectFill
            return view
        }
        func updateUIView(_ view: PlayerLayerView, context: Context) { view.playerLayer.player = player }
    }
}
#else
private struct SilentLoopingVideo: View {
    let url: URL
    @State private var player = AVPlayer()
    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.isMuted = true; player.replaceCurrentItem(with: AVPlayerItem(url: url)); player.play() }
    }
}
#endif

// MARK: - Muscles & equipment

struct MuscleChips: View {
    let primary: [MuscleGroup]
    let secondary: [MuscleGroup]
    let equipment: Equipment?

    var body: some View {
        if primary.isEmpty && secondary.isEmpty && equipment == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !primary.isEmpty {
                    labelled(String(localized: "Main muscle")) {
                        ForEach(primary, id: \.self) { Chip($0.displayName, systemImage: "target", tint: Theme.accent, filled: true) }
                    }
                }
                if !secondary.isEmpty {
                    labelled(String(localized: "Also works")) {
                        ForEach(secondary, id: \.self) { Chip($0.displayName, tint: .secondary) }
                    }
                }
                if let equipment {
                    labelled(String(localized: "Equipment")) { Chip(equipment.displayName, systemImage: equipment.systemImage, tint: .secondary) }
                }
            }
            .accessibilityIdentifier("muscles")
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) { content() }
        }
    }
}

/// Wraps its children onto as many lines as needed (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Rest timer

/// Slim bar pinned to the bottom while resting: the countdown, a thin progress line, ±15 s and skip.
/// Tap the digits to pause/resume. When the rest runs out it says so, once, and gets out of the way.
struct RestPanel: View {
    let viewModel: ResistanceBlockViewModel

    var body: some View {
        let timer = viewModel.restTimer
        if timer.isRunning || timer.isPaused {
            VStack(spacing: 10) {
                ProgressView(value: timer.progress).tint(timer.liveRemaining <= 10 ? Theme.warning : Theme.rest)
                HStack(spacing: 12) {
                    Button { timer.isPaused ? viewModel.resumeRest() : viewModel.pauseRest() } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ClockFormat.minutesSeconds(timer.remaining))
                                .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(timer.liveRemaining <= 10 ? Theme.warning : .primary)
                                .contentTransition(.numericText())
                                .accessibilityIdentifier("rest-remaining")
                            Text(timer.isPaused ? String(localized: "Paused · tap to resume") : String(localized: "Rest"))
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rest-pause")

                    Spacer(minLength: 8)

                    HStack(spacing: 0) {
                        Button { viewModel.adjustRest(by: -15) } label: { Text(verbatim: "−15").frame(width: 52, height: 40) }
                            .accessibilityIdentifier("rest-minus")
                        Divider().frame(height: 20)
                        Button { viewModel.adjustRest(by: 15) } label: { Text(verbatim: "+15").frame(width: 52, height: 40) }
                            .accessibilityIdentifier("rest-plus")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.rest)
                    .background(Theme.rest.opacity(0.14), in: Capsule())

                    Button(String(localized: "Skip")) { viewModel.skipRest() }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 40)
                        .background(Theme.field, in: Capsule())
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("rest-skip")
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rest-panel")
        } else if viewModel.restFinishedWaiting, let next = viewModel.nextSetNumber {
            Button { viewModel.dismissRestFinished() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    Text(String(localized: "Rest over · set \(next)")).font(.headline)
                    Spacer()
                    Text(String(localized: "OK")).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.success)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rest-finished-ok")
        }
    }
}
