import Domain
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct SignInView: View {
    private let model: SignInViewModel
    private let onFirstAccess: (() -> Void)?
    private let onForgotPassword: (() -> Void)?
    private let notice: String?
    @State private var identifier: String
    @State private var password = ""
    @FocusState private var focused: Field?
    private enum Field { case identifier, password }

    /// - Parameters:
    ///   - notice: a good-news line above the form ("Password changed…").
    ///   - prefill: a CPF to start with (after a password reset).
    public init(model: SignInViewModel, onFirstAccess: (() -> Void)? = nil, onForgotPassword: (() -> Void)? = nil,
                notice: String? = nil, prefill: String = "") {
        self.model = model
        self.onFirstAccess = onFirstAccess
        self.onForgotPassword = onForgotPassword
        self.notice = notice
        _identifier = State(initialValue: prefill)
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text(verbatim: "FitCoach").font(.largeTitle.bold())
            }

            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("sign-in-notice")
            }

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(String(localized: "CPF or CREF"), text: $identifier)
                        .textFieldStyle(.plain)
                        .padding(14).background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .focused($focused, equals: .identifier)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        #endif
                        .accessibilityIdentifier("sign-in-identifier")
                    if let label = model.detectedLabel {
                        Label(label, systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("sign-in-detected")
                    }
                }
                SecureField(String(localized: "Password"), text: $password)
                    .padding(14).background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await model.submit() } }
                    .accessibilityIdentifier("sign-in-password")
            }

            if let message = model.errorMessage {
                Text(verbatim: message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("sign-in-error")
            }

            Button(String(localized: "Sign in")) { Task { await model.submit() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("sign-in-button")
            if let onForgotPassword {
                Button(String(localized: "Forgot your password?"), action: onForgotPassword)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("forgot-password")
            }
            if let onFirstAccess {
                Button(String(localized: "First access? Register here"), action: onFirstAccess)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("first-access")
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(24)
        .adaptiveContentWidth(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onChange(of: identifier) { _, new in
            let masked = CPFMask.loginIdentifier(new)
            if masked != new { identifier = masked } else { model.identifier = new }
        }
        .onChange(of: password) { _, new in model.password = new }
        .onAppear { if !identifier.isEmpty { model.identifier = identifier } }       // a CPF carried over from a password reset
    }
}

public struct ProfileView: View {
    private let model: ProfileViewModel
    private let onOpenConnections: (() -> Void)?
    private let bodyModel: StudentBodyViewModel?
    private let trainerModel: StudentTrainerViewModel?
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var crefText = ""
    @State private var loadedCREF = false

    public init(model: ProfileViewModel, bodyModel: StudentBodyViewModel? = nil, trainerModel: StudentTrainerViewModel? = nil,
                onOpenConnections: (() -> Void)? = nil) {
        self.model = model
        self.bodyModel = bodyModel
        self.trainerModel = trainerModel
        self.onOpenConnections = onOpenConnections
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Avatar(initials: model.initials, photo: model.photo, size: 72)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.name).font(.headline).accessibilityIdentifier("profile-name")
                            Text(verbatim: model.roleTitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if model.canChangePhoto {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label(String(localized: "Change photo"), systemImage: "photo")
                        }
                        .accessibilityIdentifier("change-photo")
                        if model.photo != nil {
                            Button(String(localized: "Remove photo"), role: .destructive) { Task { await model.setPhoto(nil) } }
                                .accessibilityIdentifier("remove-photo")
                        }
                    }
                }

                if model.canEditCREF {
                    Section {
                        LabeledContent(String(localized: "CREF")) {
                            TextField("012345-G/AL", text: $crefText)
                                .multilineTextAlignment(.trailing)
                                .submitLabel(.done)
                                #if os(iOS)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                #endif
                                .onSubmit { Task { await model.setCREF(crefText); crefText = model.cref ?? crefText } }
                                .accessibilityIdentifier("trainer-cref")
                        }
                        if let error = model.crefError { Text(verbatim: error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("trainer-cref-error") }
                    } header: { Text(String(localized: "Professional details")) } footer: {
                        Text(String(localized: "Your students see your name, photo and CREF."))
                    }
                }

                if let trainer = trainerModel?.profile {
                    Section {
                        HStack(spacing: 14) {
                            Avatar(initials: Avatar.initials(for: trainer.displayName), photo: trainer.photo, size: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: trainer.displayName).font(.headline).accessibilityIdentifier("your-trainer-name")
                                if let cref = trainer.crefDisplay { Text(verbatim: cref).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("your-trainer-cref") }
                            }
                        }
                        .padding(.vertical, 2)
                    } header: { Text(String(localized: "Your trainer")) }
                }

                if let bodyModel {
                    Section {
                        NavigationLink {
                            BodyView(model: bodyModel)
                        } label: {
                            HStack {
                                Text(String(localized: "Body"))
                                Spacer()
                                Text(verbatim: Self.bodySummary(bodyModel.snapshot)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("open-body")
                    }
                }

                if model.hasDataSaver {
                    Section {
                        Toggle(String(localized: "Reduce motion & data"),
                               isOn: Binding(get: { model.dataSaverEnabled }, set: { model.setDataSaver($0) }))
                            .accessibilityIdentifier("toggle-data-saver")
                    } footer: {
                        Text(String(localized: "Videos start paused and play only when you tap them. This turns on by itself when you're not on Wi-Fi, so your mobile data is never used without you choosing it."))
                    }
                }

                if let onOpenConnections {
                    Section {
                        Button {
                            dismiss()
                            onOpenConnections()
                        } label: {
                            HStack { Text(String(localized: "Connections")); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("open-connections")
                    }
                }
                Section {
                    Button(String(localized: "Log out"), role: .destructive) { Task { await model.requestLogout() } }
                        .accessibilityIdentifier("log-out")
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
            .task(id: trainerModel.map(ObjectIdentifier.init)) { await trainerModel?.run() }       // the model arrives a moment after the sheet opens
            .onAppear { if !loadedCREF { crefText = model.cref ?? ""; loadedCREF = true } }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { await model.setPhoto(data) }
                    pickerItem = nil
                }
            }
            .confirmationDialog(String(localized: "Some changes haven't been sent yet"), isPresented: Binding(get: { model.isConfirmingLogout }, set: { model.isConfirmingLogout = $0 }),
                                titleVisibility: .visible) {
                Button(String(localized: "Log out anyway"), role: .destructive) { Task { await model.confirmLogout() } }
                Button(String(localized: "Stay signed in"), role: .cancel) {}
            } message: {
                Text(String(localized: "\(model.unsyncedChanges) changes will be lost if you log out now. Connect to the internet first."))
            }
        }
        .tint(Theme.accent)                        // sheets don't inherit the app's tint
        .presentationDetents([.large])
    }
}

extension ProfileView {
    /// "82 kg · BMI 25.9" — whatever is known.
    static func bodySummary(_ snapshot: BodySnapshot) -> String {
        var parts: [String] = []
        if let weight = snapshot.weightKg { parts.append(BodyFormat.number(weight) + " kg") }
        if let bmi = snapshot.bmi { parts.append(String(localized: "BMI \(BodyFormat.bmi(bmi))")) }
        return parts.joined(separator: " · ")
    }
}

/// The student's photo (or initials). Always at the top-left of the main screens; tapping it opens settings.
public struct Avatar: View {
    private let initials: String
    private let photo: Data?
    private let size: CGFloat

    public init(initials: String, photo: Data? = nil, size: CGFloat = 40) {
        self.initials = initials
        self.photo = photo
        self.size = size
    }

    public static func initials(for name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }

    static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #elseif canImport(AppKit)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        nil
        #endif
    }

    public var body: some View {
        Group {
            if let photo, let image = Self.image(from: photo) {
                image.resizable().scaledToFill()
            } else {
                Text(verbatim: initials)
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: size, height: size)
                    .background(Theme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// The toolbar item every main screen shows at the top-left.
public struct ProfileToolbarButton: View {
    private let initials: String
    private let photo: Data?
    private let action: () -> Void

    public init(initials: String, photo: Data?, action: @escaping () -> Void) {
        self.initials = initials
        self.photo = photo
        self.action = action
    }

    public var body: some View {
        Button(action: action) { Avatar(initials: initials, photo: photo, size: 34) }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Settings"))
            .accessibilityIdentifier("open-profile")
    }
}

/// Where the avatar sits in a navigation bar: top-left, as a plain circle. Recent iOS wraps toolbar items in a glass capsule, which turns a
/// round avatar into an oval pill — so the capsule is switched off here and the picture stands on its own.
public struct ProfileToolbarSlot: ToolbarContent {
    private let content: AnyView

    public init(_ content: AnyView) { self.content = content }

    public var body: some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { content }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { content }
        }
    }
}

/// First access: CPF + name (as the personal registered them), then e-mail, age, gender, height, weight and a password.
public struct FirstAccessView: View {
    private let model: FirstAccessViewModel
    private let onBack: () -> Void

    public init(model: FirstAccessViewModel, onBack: @escaping () -> Void) {
        self.model = model
        self.onBack = onBack
    }

    public var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { model.step == .profile ? model.back() : onBack() } label: { Label(String(localized: "Back"), systemImage: "chevron.left") }
                    .accessibilityIdentifier("first-access-back")

                Text(String(localized: "First access")).font(.largeTitle.bold())

                switch model.step {
                case .identify:
                    Text(String(localized: "Enter the CPF and full name your personal trainer registered for you.")).foregroundStyle(.secondary)
                    AuthTextField(String(localized: "CPF"), prompt: "000.000.000-00", text: $model.cpf, id: "first-access-cpf", keyboard: .numbers, mask: CPFMask.apply)
                    if model.cpfIsValid { Label(String(localized: "Valid CPF"), systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent) }
                    AuthTextField(String(localized: "Full name"), prompt: String(localized: "As your trainer registered it"), text: $model.fullName,
                          id: "first-access-name", keyboard: .name)
                    AuthPrimaryButton(String(localized: "Continue"), enabled: model.canContinue, id: "first-access-continue") { await model.continueTapped() }
                case .profile:
                    if let trainer = model.trainerName {
                        Label(String(localized: "Registered by \(trainer)"), systemImage: "person.badge.shield.checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    AuthTextField(String(localized: "E-mail"), prompt: "name@email.com", text: $model.email, id: "first-access-email", keyboard: .email)
                    HStack(alignment: .top, spacing: 12) {
                        AuthTextField(String(localized: "Age"), prompt: "25", text: $model.ageText, id: "first-access-age", keyboard: .numbers)
                        LabelledField(String(localized: "Gender")) {
                            Picker(String(localized: "Gender"), selection: $model.gender) {
                                ForEach(Gender.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).frame(minHeight: 50)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityIdentifier("first-access-gender")
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        AuthTextField(String(localized: "Height (cm)"), prompt: "175", text: $model.heightText, id: "first-access-height", keyboard: .decimal)
                        AuthTextField(String(localized: "Weight (kg)"), prompt: "70.5", text: $model.weightText, id: "first-access-weight", keyboard: .decimal)
                    }
                    AuthSecureField(String(localized: "Password"), prompt: String(localized: "At least 8 characters"), text: $model.password, id: "first-access-password")
                    AuthSecureField(String(localized: "Repeat password"), prompt: nil, text: $model.confirmPassword, id: "first-access-password-2")
                    AuthPrimaryButton(String(localized: "Create my account"), enabled: model.canSubmit, id: "first-access-submit") { await model.submit() }
                }

                if let message = model.errorMessage {
                    Text(verbatim: message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("first-access-error")
                }
            }
            .padding(24)
            .adaptiveContentWidth(maxWidth: 480)
        }
        .scrollDismissesKeyboard(.interactively)       // the keyboard never hides the button below the fields
        .background(Theme.background)
    }
}

// MARK: - Adaptive width (iPhone: full width · iPad: a readable column, centred)

public extension View {
    /// Keeps content at a comfortable reading width on wide screens (iPad, landscape) and leaves iPhone untouched.
    func adaptiveContentWidth(maxWidth: CGFloat = 720) -> some View {
        modifier(AdaptiveContentWidth(maxWidth: maxWidth))
    }
}

struct AdaptiveContentWidth: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content.frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
