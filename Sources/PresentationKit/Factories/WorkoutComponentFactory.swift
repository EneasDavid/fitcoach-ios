import Domain
import SwiftUI

/// A fully assembled, renderable piece of a workout: its state holder *and* its view.
@MainActor
public struct WorkoutComponent: Identifiable {
    public let id: BlockID
    public let kind: WorkoutBlockKind
    public let viewModel: any WorkoutBlockViewModel
    /// The dedicated screen for this block (opened from the workout overview). Type-erased so a template can mix
    /// block types; blocks are coarse-grained (a handful per workout), so the lost diffing of `AnyView` is irrelevant
    /// and each screen stays fully typed inside.
    public let detailView: AnyView

    public init(id: BlockID, kind: WorkoutBlockKind, viewModel: any WorkoutBlockViewModel, detailView: AnyView) {
        self.id = id
        self.kind = kind
        self.viewModel = viewModel
        self.detailView = detailView
    }
}

@MainActor
public protocol WorkoutComponentBuilding {
    func makeComponent(for block: WorkoutBlock, context: BlockBuildContext) -> WorkoutComponent
}

/// **Factory + registry** for dynamic workout rendering.
///
/// A template is a heterogeneous list (`resistance`, `hiit`, `cardio`, …). Rather than a `switch` scattered
/// through the UI, every block kind registers one builder here. Adding "mobility" or "superset" later means
/// registering one more builder — no existing screen changes (Open/Closed). Kinds this build doesn't know
/// (a trainer on a newer app version) render a harmless placeholder instead of crashing.
@MainActor
public final class WorkoutComponentFactory: WorkoutComponentBuilding {
    public typealias Builder = @MainActor (WorkoutBlock, BlockBuildContext) -> WorkoutComponent?

    private var builders: [WorkoutBlockKind: Builder] = [:]

    public init() {}

    public func register(_ kind: WorkoutBlockKind, builder: @escaping Builder) {
        builders[kind] = builder
    }

    public var registeredKinds: Set<WorkoutBlockKind> { Set(builders.keys) }

    public func makeComponent(for block: WorkoutBlock, context: BlockBuildContext) -> WorkoutComponent {
        if let component = builders[block.kind]?(block, context) { return component }
        // Keep the trainer's original type name for the message; a *known* kind whose builder declined falls back too.
        let original: UnsupportedBlock
        if case .unsupported(let unsupported) = block { original = unsupported } else { original = UnsupportedBlock(originalType: block.kind.rawValue) }
        let placeholder = UnsupportedBlockViewModel(block: original)
        return WorkoutComponent(id: block.id, kind: .unsupported, viewModel: placeholder,
                                detailView: AnyView(UnsupportedBlockScreen(viewModel: placeholder)))
    }

    public func makeComponents(for template: WorkoutTemplate, context: BlockBuildContext) -> [WorkoutComponent] {
        template.blocks.map { makeComponent(for: $0, context: context) }
    }

    /// The production registry.
    public static func standard() -> WorkoutComponentFactory {
        let factory = WorkoutComponentFactory()

        factory.register(.resistance) { block, context in
            guard case .resistance(let resistance) = block else { return nil }
            let viewModel = ResistanceBlockViewModel(block: resistance, context: context)
            return WorkoutComponent(id: resistance.id, kind: .resistance, viewModel: viewModel,
                                    detailView: AnyView(ResistanceExerciseScreen(viewModel: viewModel)))
        }
        factory.register(.hiit) { block, context in
            guard case .hiit(let hiit) = block else { return nil }
            let viewModel = HIITBlockViewModel(block: hiit, context: context)
            return WorkoutComponent(id: hiit.id, kind: .hiit, viewModel: viewModel,
                                    detailView: AnyView(HIITScreen(viewModel: viewModel)))
        }
        factory.register(.cardio) { block, context in
            guard case .cardio(let cardio) = block else { return nil }
            let viewModel = CardioBlockViewModel(block: cardio, context: context)
            return WorkoutComponent(id: cardio.id, kind: .cardio, viewModel: viewModel,
                                    detailView: AnyView(CardioScreen(viewModel: viewModel)))
        }
        return factory
    }
}

/// Screen-level factory, implemented by the app's composition root. `RoleRootView` asks it for the
/// right shell, so the two profiles never reference each other's concrete screens.
@MainActor
public protocol AppViewFactory {
    func makeSignInView() -> AnyView
    func makeTrainerRoot() -> AnyView
    func makeStudentRoot() -> AnyView
}

public struct RoleRootView: View {
    private let role: UserRole?
    private let factory: any AppViewFactory

    public init(role: UserRole?, factory: any AppViewFactory) {
        self.role = role
        self.factory = factory
    }

    public var body: some View {
        switch role {
        case .trainer: factory.makeTrainerRoot()
        case .student: factory.makeStudentRoot()
        case nil: factory.makeSignInView()
        }
    }
}
