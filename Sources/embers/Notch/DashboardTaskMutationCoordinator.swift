import EmbersCore
import EmbersPluginKit
import Foundation

/// Owns optimistic task-mutation state, duplicate suppression, rollback errors, and detail reload.
@MainActor
final class DashboardTaskMutationCoordinator: ObservableObject {
    @Published private(set) var mutatingTaskIDs: Set<String> = []
    @Published private(set) var taskMutationError: String?

    private let context: ContextIndexController
    private let navigation: DashboardNavigationCoordinator

    init(context: ContextIndexController, navigation: DashboardNavigationCoordinator) {
        self.context = context
        self.navigation = navigation
    }

    func supportsCompletion(_ task: AnchorTask) async -> Bool {
        await context.supportedTaskStates(for: task).contains(.completed)
    }

    func complete(_ task: AnchorTask) async {
        guard mutatingTaskIDs.insert(task.id).inserted else { return }
        taskMutationError = nil
        defer { mutatingTaskIDs.remove(task.id) }
        do {
            try await context.setTaskState(.completed, for: task)
            await navigation.reload()
        } catch {
            taskMutationError = error.localizedDescription
        }
    }

    func report(_ error: Error) {
        taskMutationError = error.localizedDescription
    }
}
