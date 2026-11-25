import Deinit
import Foundation

// MARK: - Test Types

@DeinitClass
final class Test {

    let name: String

    @DeinitAttach
    init(name: String) {
        self.name = name
    }

    @DeinitAttach
    deinit {}
}

/// Used to build retain cycles.
@DeinitClass
final class Node {

    let name: String
    var other: Node?

    @DeinitAttach
    init(name: String) {
        self.name = name
    }

    @DeinitAttach
    deinit {}
}

/// Has a non-empty deinit with an early return, to check the `defer` path
/// still unregisters.
@DeinitClass
final class EarlyReturn {

    let shouldReturnEarly: Bool
    nonisolated(unsafe) static var deinitBodyRan = 0

    @DeinitAttach
    init(shouldReturnEarly: Bool) {
        self.shouldReturnEarly = shouldReturnEarly
    }

    @DeinitAttach
    deinit {
        if shouldReturnEarly { return }
        EarlyReturn.deinitBodyRan += 1
    }
}

// MARK: - Real-World Leak Patterns
//
// Each type takes `weakCapture`:
//   false → the common bug (strong capture, so the object leaks)
//   true  → the usual fix (weak capture or cleanup, so the object is freed)

/// 1. A stored closure that captures `self`.
@DeinitClass
final class Downloader {

    var onComplete: (() -> Void)?
    var finished = false

    @DeinitAttach
    init(weakCapture: Bool) {
        start(weakCapture: weakCapture)
    }

    // Kept out of `init`: Swift 6.4.2 fails to compile `[weak self]` inside an
    // `init` whose body is rewritten by `@DeinitAttach`.
    private func start(weakCapture: Bool) {
        if weakCapture {
            onComplete = { [weak self] in self?.finished = true }
        } else {
            onComplete = { self.finished = true }
        }
    }

    @DeinitAttach
    deinit {}
}

/// 2. A child view that holds its delegate (the parent) strongly.
protocol ListDelegate: AnyObject {
    func didSelect(_ index: Int)
}

@DeinitClass
final class ListView {

    var strongDelegate: ListDelegate?
    weak var weakDelegate: ListDelegate?

    @DeinitAttach
    init() {}

    @DeinitAttach
    deinit {}
}

@DeinitClass
final class ListScreen: ListDelegate {

    let list = ListView()
    var selected = -1

    @DeinitAttach
    init(weakCapture: Bool) {
        if weakCapture {
            list.weakDelegate = self
        } else {
            list.strongDelegate = self
        }
    }

    func didSelect(_ index: Int) { selected = index }

    @DeinitAttach
    deinit {}
}

/// 3. A repeating Timer whose block captures `self`. The run loop keeps
/// the timer alive, and the timer keeps `self` alive.
@DeinitClass
final class Poller: @unchecked Sendable {

    var timer: Timer?
    var ticks = 0

    @DeinitAttach
    init(weakCapture: Bool) {
        start(weakCapture: weakCapture)
    }

    // Kept out of `init`: Swift 6.4.2 fails to compile `[weak self]` inside an
    // `init` whose body is rewritten by `@DeinitAttach`.
    private func start(weakCapture: Bool) {
        if weakCapture {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.ticks += 1
            }
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                self.ticks += 1
            }
        }
    }

    @DeinitAttach
    deinit {
        timer?.invalidate()
    }
}

/// 4. A NotificationCenter block observer that captures `self`.
/// NotificationCenter keeps the block alive until the observer is removed.
extension Notification.Name {
    static let themeChanged = Notification.Name("DeinitClient.themeChanged")
}

@DeinitClass
final class ThemeObserver: @unchecked Sendable {

    var token: NSObjectProtocol?
    var changes = 0

    @DeinitAttach
    init(weakCapture: Bool) {
        start(weakCapture: weakCapture)
    }

    // Kept out of `init`: Swift 6.4.2 fails to compile `[weak self]` inside an
    // `init` whose body is rewritten by `@DeinitAttach`.
    private func start(weakCapture: Bool) {
        if weakCapture {
            token = NotificationCenter.default.addObserver(
                forName: .themeChanged, object: nil, queue: nil
            ) { [weak self] _ in
                self?.changes += 1
            }
        } else {
            token = NotificationCenter.default.addObserver(
                forName: .themeChanged, object: nil, queue: nil
            ) { _ in
                self.changes += 1
            }
        }
    }

    @DeinitAttach
    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// 5. A long-running Task that captures `self` for its whole lifetime.
@DeinitClass
final class LiveFeed: @unchecked Sendable {

    var task: Task<Void, Never>?
    var updates = 0

    @DeinitAttach
    init(weakCapture: Bool) {
        start(weakCapture: weakCapture)
    }

    // Kept out of `init`: Swift 6.4.2 fails to compile `[weak self]` inside an
    // `init` whose body is rewritten by `@DeinitAttach`.
    private func start(weakCapture: Bool) {
        if weakCapture {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    // Only hold `self` strongly for the moment it's needed.
                    guard let self else { return }
                    self.updates += 1
                }
            }
        } else {
            task = Task {
                while !Task.isCancelled {
                    self.updates += 1
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    @DeinitAttach
    deinit {
        task?.cancel()
    }
}

// MARK: - Harness

var passed = 0
var failed = 0
var currentSuite = ""

@MainActor func suite(_ name: String) {
    currentSuite = name
    print("\n▶ \(name)")
    DeinitRegistry.reset()
}

@MainActor func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        passed += 1
        print("  ✅ \(message)")
    } else {
        failed += 1
        print("  ❌ \(message)  (main.swift:\(line))")
    }
}

func sleep(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
}

func registeredCount(named name: String) -> Int {
    DeinitRegistry.list().filter { $0.hasPrefix("\(name): ") }.count
}

/// Simulates a screen being dismissed: builds a leaky and a fixed version,
/// asks the registry to watch both, drops both, then checks the result.
@MainActor
func leakScenario(_ title: String, make: (_ weakCapture: Bool) -> any DeinitTrackable) async {
    suite("Real-world leak: \(title)")
    var leaky: (any DeinitTrackable)? = make(false)
    var fixed: (any DeinitTrackable)? = make(true)
    let leakyID = leaky!.deinitIdentifier
    let fixedID = fixed!.deinitIdentifier

    DeinitRegistry.shouldDeinit(leaky!)
    DeinitRegistry.shouldDeinit(fixed!)
    leaky = nil
    fixed = nil

    await sleep(waitForLeak)
    check(DeinitRegistry.status(for: leakyID) == .leak, "strong version is flagged as .leak")
    check(!DeinitRegistry.doesObjectExist(fixedID), "fixed version is freed")
}

// MARK: - Race Stress Mode
//
// `swift run DeinitClient race` hammers the registry from several threads.
// `swift run DeinitClient race noreset` does the same without calling reset().
// Build with `--sanitize=thread` to have Thread Sanitizer report any unlocked access.

/// Lets a background task safely see the latest batch of ids.
final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [DeinitID] = []
    var current: [DeinitID] {
        get { lock.withLock { ids } }
        set { lock.withLock { ids = newValue } }
    }
}

if CommandLine.arguments.contains("race") {
    print("Race stress: reading status(for:) and calling reset() while trackers write…")
    DeinitRegistry.setWarningDelay(0.001)
    DeinitRegistry.setLeakDelay(0.001)

    let box = IDBox()
    let deadline = Date().addingTimeInterval(3)

    let reader = Task.detached {
        var reads = 0
        while Date() < deadline {
            for id in box.current {
                _ = DeinitRegistry.status(for: id)
                reads += 1
            }
            await Task.yield()
        }
        return reads
    }

    // `race noreset` leaves reset() out, to test status(for:) on its own.
    let callReset = !CommandLine.arguments.contains("noreset")
    let resetter = Task.detached {
        var resets = 0
        while callReset && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(3))
            DeinitRegistry.reset()
            resets += 1
        }
        return resets
    }

    var rounds = 0
    var alive: [Test] = []
    while Date() < deadline {
        alive = (0..<200).map { Test(name: "Stress\($0)") }
        box.current = alive.map(\.deinitIdentifier)
        alive.forEach { DeinitRegistry.shouldDeinit($0) }
        rounds += 1
        await sleep(0.005)
    }
    alive.removeAll()

    let reads = await reader.value
    let resets = await resetter.value
    print("Finished without crashing: \(rounds) rounds, \(reads) status reads, \(resets) resets.")
    print("Without Thread Sanitizer a clean finish proves nothing. Build with --sanitize=thread to check.")
    exit(0)
}

// Short delays so the whole run takes a few seconds instead of ~35s.
let warningDelay = 0.3
let leakDelay = 0.6
DeinitRegistry.setWarningDelay(warningDelay)
DeinitRegistry.setLeakDelay(leakDelay)

/// Waits past the warning point, but well before the leak point.
let waitForWarning = warningDelay + leakDelay / 2
/// Waits past the leak point.
let waitForLeak = warningDelay + leakDelay + 0.4

// MARK: - Tests

suite("Registration")
do {
    let object = Test(name: "Alex")
    let id = object.deinitIdentifier
    check(DeinitRegistry.doesObjectExist(object), "object is registered after init")
    check(DeinitRegistry.doesObjectExist(id), "object is registered by id")
    check(DeinitRegistry.status(for: object) == .normal, "new object has .normal status")
    check(object.deinitObjectName == "Test", "deinitObjectName is the class name")
    check(object.name == "Alex", "original init body still runs")
    check(registeredCount(named: "Test") == 1, "list() has exactly one Test entry")
    check(
        DeinitRegistry.list().first?.hasSuffix("[normal]") == true,
        "list() format ends with [normal]"
    )
    withExtendedLifetime(object) {}
}

suite("Unique identifiers")
do {
    let a = Test(name: "A")
    let b = Test(name: "B")
    check(a.deinitIdentifier != b.deinitIdentifier, "each instance gets its own id")
    withExtendedLifetime((a, b)) {}
}

suite("Unregister on dealloc")
do {
    var object: Test? = Test(name: "Emma")
    let id = object!.deinitIdentifier
    check(DeinitRegistry.doesObjectExist(id), "exists before release")
    object = nil
    check(!DeinitRegistry.doesObjectExist(id), "removed after release")
    check(DeinitRegistry.status(for: id) == nil, "status is nil after release")
}

suite("Many objects")
do {
    let names = [
        "Alex", "Emma", "Liam", "Olivia", "Noah", "Sophia", "James", "Isabella",
        "Lucas", "Mia", "Ethan", "Charlotte", "Henry", "Amelia", "Benjamin",
        "Harper", "Daniel", "Evelyn", "Oliver", "Ava",
    ]
    var tests = names.map { Test(name: $0) }
    check(registeredCount(named: "Test") == names.count, "all \(names.count) objects registered")

    tests.removeLast(5)
    check(registeredCount(named: "Test") == names.count - 5, "releasing 5 leaves \(names.count - 5)")

    tests.removeAll()
    check(registeredCount(named: "Test") == 0, "releasing all leaves 0")
}

suite("Deinit body with early return")
do {
    EarlyReturn.deinitBodyRan = 0

    var early: EarlyReturn? = EarlyReturn(shouldReturnEarly: true)
    let earlyID = early!.deinitIdentifier
    early = nil
    check(!DeinitRegistry.doesObjectExist(earlyID), "unregistered even when deinit returns early")
    check(EarlyReturn.deinitBodyRan == 0, "early return skipped the rest of the body")

    var normal: EarlyReturn? = EarlyReturn(shouldReturnEarly: false)
    let normalID = normal!.deinitIdentifier
    normal = nil
    check(!DeinitRegistry.doesObjectExist(normalID), "unregistered when deinit runs fully")
    check(EarlyReturn.deinitBodyRan == 1, "original deinit body still runs")
}

suite("shouldDeinit on an object that is freed")
do {
    var object: Test? = Test(name: "Liam")
    let id = object!.deinitIdentifier
    DeinitRegistry.shouldDeinit(object!)
    object = nil
    await sleep(waitForLeak)
    check(!DeinitRegistry.doesObjectExist(id), "object is gone")
    check(!DeinitRegistry.doesAnyWarningsExist(), "no warnings")
    check(!DeinitRegistry.doesAnyLeaksExist(), "no leaks")
}

suite("shouldDeinit on an already-freed object")
do {
    var object: Test? = Test(name: "Ghost")
    let id = object!.deinitIdentifier
    object = nil
    // Can't pass a freed object, so this checks the registry stays clean
    // when nothing is tracked.
    await sleep(waitForWarning)
    check(!DeinitRegistry.doesObjectExist(id), "freed object never reappears")
    check(DeinitRegistry.list().isEmpty, "registry is empty")
}

suite("shouldDeinit on a retained object: normal → warning → leak")
do {
    var object: Test? = Test(name: "Olivia")
    let id = object!.deinitIdentifier
    DeinitRegistry.shouldDeinit(object!)

    check(DeinitRegistry.status(for: id) == .normal, "starts as .normal")

    await sleep(waitForWarning)
    check(DeinitRegistry.status(for: id) == .warning, "becomes .warning after warningDelay")
    check(DeinitRegistry.doesAnyWarningsExist(), "doesAnyWarningsExist() is true")
    check(!DeinitRegistry.doesAnyLeaksExist(), "not a leak yet")

    await sleep(waitForLeak - waitForWarning)
    check(DeinitRegistry.status(for: id) == .leak, "becomes .leak after leakDelay")
    check(DeinitRegistry.doesAnyLeaksExist(), "doesAnyLeaksExist() is true")
    check(
        DeinitRegistry.list().contains { $0.hasSuffix("[leak]") },
        "list() shows [leak]"
    )

    // Calling again on a leaked object should be a no-op.
    DeinitRegistry.shouldDeinit(object!)
    check(DeinitRegistry.status(for: id) == .leak, "shouldDeinit again keeps .leak")

    // Releasing it late still unregisters it.
    object = nil
    check(!DeinitRegistry.doesObjectExist(id), "late release removes it")
    check(!DeinitRegistry.doesAnyLeaksExist(), "no leaks after late release")
}

suite("Released between warning and leak")
do {
    var object: Test? = Test(name: "Noah")
    let id = object!.deinitIdentifier
    DeinitRegistry.shouldDeinit(object!)

    await sleep(waitForWarning)
    check(DeinitRegistry.status(for: id) == .warning, "is .warning")

    object = nil
    await sleep(waitForLeak - waitForWarning)
    check(!DeinitRegistry.doesObjectExist(id), "gone after release")
    check(!DeinitRegistry.doesAnyLeaksExist(), "never marked as leak")
}

suite("Duplicate shouldDeinit calls")
do {
    var object: Test? = Test(name: "Sophia")
    let id = object!.deinitIdentifier
    DeinitRegistry.shouldDeinit(object!)
    DeinitRegistry.shouldDeinit(object!)
    DeinitRegistry.shouldDeinit(object!)
    await sleep(waitForWarning)
    check(DeinitRegistry.status(for: id) == .warning, "still a single normal → warning transition")
    object = nil
    check(!DeinitRegistry.doesObjectExist(id), "release cancels tracking")
}

suite("Retain cycle is detected as a leak")
do {
    var a: Node? = Node(name: "A")
    var b: Node? = Node(name: "B")
    a!.other = b
    b!.other = a
    let aID = a!.deinitIdentifier
    let bID = b!.deinitIdentifier

    DeinitRegistry.shouldDeinit(a!)
    DeinitRegistry.shouldDeinit(b!)
    a = nil
    b = nil

    check(DeinitRegistry.doesObjectExist(aID), "A survives release (cycle)")
    check(DeinitRegistry.doesObjectExist(bID), "B survives release (cycle)")

    await sleep(waitForLeak)
    check(DeinitRegistry.status(for: aID) == .leak, "A marked .leak")
    check(DeinitRegistry.status(for: bID) == .leak, "B marked .leak")
    check(registeredCount(named: "Node") == 2, "list() shows both Nodes")
}

suite("Broken cycle (weak-style fix) is not a leak")
do {
    var a: Node? = Node(name: "A")
    var b: Node? = Node(name: "B")
    a!.other = b
    b!.other = a
    let aID = a!.deinitIdentifier
    let bID = b!.deinitIdentifier

    DeinitRegistry.shouldDeinit(a!)
    DeinitRegistry.shouldDeinit(b!)
    a!.other = nil // break the cycle
    a = nil
    b = nil

    await sleep(waitForLeak)
    check(!DeinitRegistry.doesObjectExist(aID), "A freed")
    check(!DeinitRegistry.doesObjectExist(bID), "B freed")
    check(!DeinitRegistry.doesAnyLeaksExist(), "no leaks")
}

await leakScenario("closure capturing self") { Downloader(weakCapture: $0) }
await leakScenario("strong delegate") { ListScreen(weakCapture: $0) }
await leakScenario("repeating Timer") { Poller(weakCapture: $0) }
await leakScenario("NotificationCenter observer") { ThemeObserver(weakCapture: $0) }
await leakScenario("long-running Task") { LiveFeed(weakCapture: $0) }

suite("reset()")
do {
    let kept = Test(name: "Kept")
    DeinitRegistry.shouldDeinit(kept)
    DeinitRegistry.reset()
    check(DeinitRegistry.list().isEmpty, "list() is empty after reset")
    check(!DeinitRegistry.doesObjectExist(kept), "live object no longer tracked")

    await sleep(waitForLeak)
    check(!DeinitRegistry.doesAnyWarningsExist(), "reset cancels pending warning")
    check(!DeinitRegistry.doesAnyLeaksExist(), "reset cancels pending leak")
    withExtendedLifetime(kept) {}
}

// MARK: - Summary

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
