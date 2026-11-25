import Foundation
import Testing
@testable import TerminalApp

@Suite @MainActor struct RecoveryCoordinatorTests {
  private final class FakeScheduler {
    struct Entry {
      let id: Int
      let due: TimeInterval
      var cancelled = false
      var fired = false
      let action: () -> Void
    }

    var now: TimeInterval = 0
    private var nextID = 0
    private(set) var entries: [Entry] = []

    var activeCount: Int {
      entries.filter { !$0.cancelled && !$0.fired }.count
    }

    func schedule(delay: TimeInterval, action: @escaping () -> Void) -> RecoveryCoordinator.ScheduledTask {
      let id = nextID
      nextID += 1
      entries.append(Entry(id: id, due: now + max(0, delay), action: action))
      return RecoveryCoordinator.ScheduledTask { [weak self] in
        guard let self, let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
        self.entries[index].cancelled = true
      }
    }

    func advance(by delta: TimeInterval) {
      let target = now + delta
      while let nextIndex = entries.indices
        .filter({ !entries[$0].cancelled && !entries[$0].fired && entries[$0].due <= target })
        .min(by: { lhs, rhs in
          if entries[lhs].due != entries[rhs].due { return entries[lhs].due < entries[rhs].due }
          return entries[lhs].id < entries[rhs].id
        })
      {
        now = max(now, entries[nextIndex].due)
        entries[nextIndex].fired = true
        entries[nextIndex].action()
      }
      now = target
    }

    /// Invokes every scheduled action regardless of cancellation to verify
    /// weak-self / stopped guards.
    func fireAllRaw() {
      for entry in entries where !entry.fired {
        entry.action()
      }
    }
  }

  @Test func layoutChangesCoalesceAndRespectMaximumAge() {
    let scheduler = FakeScheduler()
    var layoutSaves = 0
    let coordinator = RecoveryCoordinator(
      now: { scheduler.now },
      schedule: { scheduler.schedule(delay: $0, action: $1) },
      isPaneAlive: { _ in true },
      saveLayout: { layoutSaves += 1 },
      captureCheckpoint: { _, _, _ in },
      saveScrollback: { _, _, _ in }
    )

    coordinator.layoutChanged()
    #expect(coordinator.layoutRevision == 1)
    scheduler.advance(by: 0.6)
    #expect(layoutSaves == 0)

    // Repeated changes every 0.6s postpone the 1s debounce, but must still
    // save at the 5s cap from the first change.
    for _ in 0..<7 {
      coordinator.layoutChanged()
      scheduler.advance(by: 0.6)
    }
    #expect(layoutSaves == 0)
    #expect(scheduler.now == 4.8)

    coordinator.layoutChanged()
    scheduler.advance(by: 0.2)
    #expect(layoutSaves == 1)
    #expect(coordinator.layoutRevision == 9)

    // After flushing at the cap, a subsequent change starts a fresh 1s window.
    scheduler.advance(by: 1.0)
    coordinator.layoutChanged()
    scheduler.advance(by: 0.9)
    #expect(layoutSaves == 1)
    scheduler.advance(by: 0.1)
    #expect(layoutSaves == 2)
  }

  @Test func paneReadyTracksCompletionAndSchedulesLayoutSave() {
    let scheduler = FakeScheduler()
    var layoutSaves = 0
    let coordinator = RecoveryCoordinator(
      now: { scheduler.now },
      schedule: { scheduler.schedule(delay: $0, action: $1) },
      isPaneAlive: { _ in true },
      saveLayout: { layoutSaves += 1 },
      captureCheckpoint: { _, _, _ in },
      saveScrollback: { _, _, _ in }
    )

    #expect(!coordinator.allPanesReady(["a", "b"]))
    coordinator.paneReady("a")
    #expect(!coordinator.allPanesReady(["a", "b"]))
    coordinator.paneReady("b")
    #expect(coordinator.allPanesReady(["a", "b"]))

    scheduler.advance(by: 1.0)
    #expect(layoutSaves == 1)
  }

  @Test func checkpointsCoalesceSerializeRetryAndSkipDeadPanes() {
    let scheduler = FakeScheduler()
    var alive: Set<String> = ["a", "b", "c"]
    var layoutSaves = 0
    var captures: [(pane: String, force: Bool, completion: RecoveryCoordinator.CaptureCompletion)] = []
    var savedScrollback: [(pane: String, text: String, rows: Int)] = []

    let coordinator = RecoveryCoordinator(
      now: { scheduler.now },
      schedule: { scheduler.schedule(delay: $0, action: $1) },
      isPaneAlive: { alive.contains($0) },
      saveLayout: { layoutSaves += 1 },
      captureCheckpoint: { pane, force, completion in
        captures.append((pane, force, completion))
      },
      saveScrollback: { pane, text, rows in
        savedScrollback.append((pane, text, rows))
      }
    )

    coordinator.output(paneID: "a")
    scheduler.advance(by: 1.0)
    // Repeated output on "a" pushes its checkpoint out to t=3.0.
    coordinator.output(paneID: "a")
    scheduler.advance(by: 0.5)
    coordinator.output(paneID: "b") // due t=3.5
    coordinator.output(paneID: "c") // due t=3.5
    alive.remove("b") // "b" closes before capture

    scheduler.advance(by: 1.4) // t=2.9
    #expect(captures.isEmpty)

    scheduler.advance(by: 0.1) // t=3.0: only "a" starts
    #expect(captures.count == 1)
    #expect(captures[0].pane == "a")
    #expect(captures[0].force == false)

    // Advancing past t=3.5 must not start a second capture while "a" is in flight.
    scheduler.advance(by: 1.0) // t=4.0
    #expect(captures.count == 1)

    // Complete "a" with scrollback; "b" is dead so "c" should be scheduled next.
    captures[0].completion("scrollback-a", 12, nil)
    #expect(savedScrollback.count == 1)
    #expect(savedScrollback[0].pane == "a")
    #expect(savedScrollback[0].text == "scrollback-a")
    #expect(savedScrollback[0].rows == 12)

    scheduler.advance(by: 0.0) // "c" was already due at 3.5 <= 4.0
    #expect(captures.count == 2)
    #expect(captures[1].pane == "c")

    // "c" asks to retry in 3 seconds.
    captures[1].completion(nil, 0, 3.0)
    #expect(savedScrollback.count == 1)

    scheduler.advance(by: 2.9)
    #expect(captures.count == 2)
    #expect(layoutSaves == 1) // triggered by "a"'s scrollback save

    scheduler.advance(by: 0.1)
    #expect(captures.count == 3)
    #expect(captures[2].pane == "c")
  }

  @Test func immediateFlushSavesLayoutAndForcesAllPendingCheckpoints() {
    let scheduler = FakeScheduler()
    var layoutSaves = 0
    var captures: [(pane: String, force: Bool, completion: RecoveryCoordinator.CaptureCompletion)] = []

    let coordinator = RecoveryCoordinator(
      now: { scheduler.now },
      schedule: { scheduler.schedule(delay: $0, action: $1) },
      isPaneAlive: { _ in true },
      saveLayout: { layoutSaves += 1 },
      captureCheckpoint: { pane, force, completion in
        captures.append((pane, force, completion))
      },
      saveScrollback: { _, _, _ in }
    )

    coordinator.layoutChanged()
    coordinator.output(paneID: "a")
    coordinator.output(paneID: "b")
    #expect(layoutSaves == 0)
    #expect(captures.isEmpty)

    coordinator.flush()
    #expect(layoutSaves == 1)
    #expect(captures.count == 1)
    #expect(captures[0].pane == "a")
    #expect(captures[0].force == true)

    // Completing "a" during sleep flush immediately schedules "b" with force=true.
    captures[0].completion("a-text", 5, nil)
    scheduler.advance(by: 0.0)
    #expect(captures.count == 2)
    #expect(captures[1].pane == "b")
    #expect(captures[1].force == true)

    captures[1].completion("b-text", 6, nil)

    // After flush finishes, new output returns to normal non-forced capture.
    coordinator.output(paneID: "a")
    scheduler.advance(by: 2.0)
    #expect(captures.count == 3)
    #expect(captures[2].force == false)
  }

  private final class Counter: @unchecked Sendable {
    var value = 0
  }

  @Test func cancelForNormalQuitStopsTimersDropsInFlightAndIsIdempotent() {
    let scheduler = FakeScheduler()
    var layoutSaves = 0
    var savedScrollback = 0
    var cleanExitCalls = 0
    let completionCalls = Counter()
    var pendingCapture: RecoveryCoordinator.CaptureCompletion?

    let coordinator = RecoveryCoordinator(
      now: { scheduler.now },
      schedule: { scheduler.schedule(delay: $0, action: $1) },
      isPaneAlive: { _ in true },
      saveLayout: { layoutSaves += 1 },
      captureCheckpoint: { _, _, completion in pendingCapture = completion },
      saveScrollback: { _, _, _ in savedScrollback += 1 },
      cleanExit: { done in
        cleanExitCalls += 1
        done()
      }
    )

    coordinator.layoutChanged()
    coordinator.output(paneID: "a")
    coordinator.output(paneID: "b")
    scheduler.advance(by: 2.0) // layout saved once, "a" capture now in flight
    #expect(layoutSaves == 1)
    #expect(pendingCapture != nil)

    coordinator.layoutChanged() // pending layout save to be cancelled
    coordinator.cancelForNormalQuit { completionCalls.value += 1 }
    #expect(coordinator.isStopped)
    #expect(cleanExitCalls == 1)
    #expect(completionCalls.value == 1)
    #expect(scheduler.activeCount == 0)

    // Late completion of in-flight capture must not persist or reschedule.
    pendingCapture?("late-text", 10, nil)
    #expect(savedScrollback == 0)
    #expect(scheduler.activeCount == 0)

    // Subsequent events and flushes are ignored.
    coordinator.layoutChanged()
    coordinator.paneReady("a")
    coordinator.output(paneID: "a")
    coordinator.flush()
    scheduler.advance(by: 10.0)
    #expect(layoutSaves == 1)
    #expect(savedScrollback == 0)

    // Second cancel is idempotent: does not re-run cleanExit, still completes.
    coordinator.cancelForNormalQuit { completionCalls.value += 1 }
    #expect(cleanExitCalls == 1)
    #expect(completionCalls.value == 2)
  }

  @Test func reentrancyDuplicateCompletionAndTeardownSafety() {
    let scheduler = FakeScheduler()
    var saved: [String] = []
    var captureCount = 0
    var capturedCompletion: RecoveryCoordinator.CaptureCompletion?

    // 1. Synchronous completion re-entrancy + duplicate completion guard.
    let syncCoordinator = RecoveryCoordinator(
      now: { scheduler.now },
      schedule: { scheduler.schedule(delay: $0, action: $1) },
      isPaneAlive: { _ in true },
      saveLayout: {},
      captureCheckpoint: { pane, _, completion in
        captureCount += 1
        capturedCompletion = completion
        completion("sync-\(pane)", 1, nil)
        completion("duplicate-\(pane)", 1, nil)
      },
      saveScrollback: { pane, text, _ in saved.append("\(pane):\(text)") }
    )

    syncCoordinator.output(paneID: "a")
    syncCoordinator.output(paneID: "b")
    scheduler.advance(by: 2.0)
    #expect(captureCount == 2)
    #expect(saved == ["a:sync-a", "b:sync-b"])
    capturedCompletion?("stale-duplicate", 1, nil)
    #expect(saved.count == 2)

    // 2. Re-entrant cancel inside saveLayout halts flush before capturing panes.
    var reentrantCoordinator: RecoveryCoordinator?
    var reentrantCaptures = 0
    reentrantCoordinator = RecoveryCoordinator(
      now: { scheduler.now },
      schedule: { scheduler.schedule(delay: $0, action: $1) },
      isPaneAlive: { _ in true },
      saveLayout: { reentrantCoordinator?.cancelForNormalQuit() },
      captureCheckpoint: { _, _, _ in reentrantCaptures += 1 },
      saveScrollback: { _, _, _ in }
    )
    reentrantCoordinator?.output(paneID: "a")
    reentrantCoordinator?.flush()
    #expect(reentrantCaptures == 0)
    #expect(reentrantCoordinator?.isStopped == true)

    // 3. Deallocation cancels timers and stale closures do not crash or fire.
    let teardownScheduler = FakeScheduler()
    var postDeinitSaves = 0
    var ephemeral: RecoveryCoordinator? = RecoveryCoordinator(
      now: { teardownScheduler.now },
      schedule: { teardownScheduler.schedule(delay: $0, action: $1) },
      isPaneAlive: { _ in true },
      saveLayout: { postDeinitSaves += 1 },
      captureCheckpoint: { _, _, _ in postDeinitSaves += 1 },
      saveScrollback: { _, _, _ in postDeinitSaves += 1 }
    )
    ephemeral?.layoutChanged()
    ephemeral?.output(paneID: "a")
    #expect(teardownScheduler.activeCount == 2)

    ephemeral = nil
    #expect(teardownScheduler.activeCount == 0)
    teardownScheduler.fireAllRaw()
    #expect(postDeinitSaves == 0)
  }
}
