import Foundation

@MainActor
private final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        // Deliberately ignore cancellation like an SDK call still unwinding.
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main
@MainActor
enum ModelWorkCoordinatorChecks {
    static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Native model coordination did not make progress")
    }

    static func main() async {
        let coordinator = NativeModelWorkCoordinator()
        var events: [String] = []
        let preparation = Gate()
        let first = coordinator.prepare {
            events.append("prepare-start")
            await preparation.wait()
            precondition(Task.isCancelled)
            events.append("prepare-drained")
        }!
        await wait { preparation.entered }
        let generated = coordinator.generate { events.append("generate") }
        var unrelatedNativeWorkRan = false
        let otherService = Task { @MainActor in unrelatedNativeWorkRan = true }
        await otherService.value
        precondition(unrelatedNativeWorkRan && first.isCancelled)
        precondition(events == ["prepare-start"])
        precondition(coordinator.prepare { events.append("ignored-hint") } == nil)
        preparation.release()
        await generated.value
        precondition(events == ["prepare-start", "prepare-drained", "generate"])

        // A canceled generation remains a barrier until the native operation
        // finishes, even when several replacements arrive in the meantime.
        events = []
        let oldGeneration = Gate()
        let old = coordinator.generate {
            events.append("old-start")
            await oldGeneration.wait()
            precondition(Task.isCancelled)
            events.append("old-drained")
        }
        await wait { oldGeneration.entered }
        coordinator.cancel()
        var skippedCompleted = false
        let skipped = coordinator.generate({ events.append("must-not-run") },
            onCompletion: { skippedCompleted = true })
        let newest = coordinator.generate { events.append("newest") }
        await Task.yield()
        precondition(old.isCancelled && skipped.isCancelled)
        precondition(events == ["old-start"] && !skippedCompleted)
        oldGeneration.release()
        await newest.value
        precondition(skippedCompleted)
        precondition(events == ["old-start", "old-drained", "newest"])

        // Completed preparation is not canceled or invalidated by a new reply;
        // the model can retain its ready exact-context session in its own cache.
        var readySession: UUID?
        let warmed = coordinator.prepare { readySession = UUID() }!
        await warmed.value
        let expected = readySession
        let useWarm = coordinator.generate {
            precondition(readySession == expected && expected != nil)
        }
        await useWarm.value
        precondition(!warmed.isCancelled)

        // Replacing a preparation also drains its predecessor rather than
        // launching overlapping token-count requests.
        events = []
        let oldPreparation = Gate()
        _ = coordinator.prepare {
            events.append("first-preparation")
            await oldPreparation.wait()
            events.append("first-finished")
        }
        await wait { oldPreparation.entered }
        let second = coordinator.prepare { events.append("second-preparation") }!
        await Task.yield()
        precondition(events == ["first-preparation"])
        oldPreparation.release()
        await second.value
        precondition(events == ["first-preparation", "first-finished", "second-preparation"])
        print("MODEL_WORK_COORDINATOR_CHECKS_PASSED: preparation/generation drain, cancellation chains, ready-cache retention, unrelated native work")
    }
}
