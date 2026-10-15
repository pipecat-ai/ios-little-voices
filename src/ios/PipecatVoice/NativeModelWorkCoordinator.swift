import Foundation

/// Serializes the language model's preparation and generation: a cancelled call may take time
/// to unwind, so its replacement waits for it.
@MainActor
final class NativeModelWorkCoordinator {
    private enum Kind { case preparation, generation }
    private struct Entry {
        let id: UUID
        let kind: Kind
        let task: Task<Void, Never>
    }
    private var latest: Entry?

    @discardableResult
    func prepare(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard latest?.kind != .generation else { return nil }
        return replace(kind: .preparation, operation: operation)
    }

    func generate(_ operation: @escaping @MainActor () async -> Void,
                  onCompletion: @escaping @MainActor () -> Void = {}) -> Task<Void, Never> {
        replace(kind: .generation, operation: operation, onCompletion: onCompletion)
    }

    func cancel() {
        // Retain the task as a barrier until it actually exits. Clearing it here
        // would allow a new generation to overlap canceled native work.
        latest?.task.cancel()
    }

    private func replace(kind: Kind, operation: @escaping @MainActor () async -> Void,
                         onCompletion: @escaping @MainActor () -> Void = {}) -> Task<Void, Never> {
        let previous = latest?.task
        previous?.cancel()
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            defer { onCompletion() }
            if !Task.isCancelled { await operation() }
            if self?.latest?.id == id { self?.latest = nil }
        }
        latest = Entry(id: id, kind: kind, task: task)
        return task
    }
}
