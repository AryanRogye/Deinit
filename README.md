
# How To Use

## Tracking A  Class

```swift
@DeinitClass
final class Person {
    let name: String

    @DeinitAttach
    init(name: String) {
        self.name = name
    }

    @DeinitAttach
    deinit {}
}
```

DeinitRegistery automatically tracks the allocation and deallocation of registered objects.

## Tracking Expected Deallocation

Best way to check if an object is going to deallocate
is to set `DeinitRegistery.shouldDeinit(_)`

- For Example
```swift
private func cleanupPeople() {
    for person in people {
        DeinitRegistery.shouldDeinit(person)
    }

    people.removeAll()
}
```

## Inspecting Allocations


There are two ways to retrieve currently tracked allocations.

### Basic List

```swift
DeinitRegistery.list()
```

will return back all allocated objects as a `[String]`

### Detailed List

```swift
DeinitRegistery.detailedList()
```

will return back all allocated objects as a `[DeinitRegistery.ListResult]`

- `name`: The object's name.
- `id`: The object's unique tracking identifier.
- `objectIdentifier`: The object's identity.
- `status`: The object's current allocation status.


## Checking for Memory Leaks

You can inspect an object's allocation status using its deinitIdentifier.

```swift
private func cleanupPeople() async {
    var ids: [UUID] = []
    for person in people {
        ids.append(person.deinitIdentifier)
        DeinitRegistery.shouldDeinit(person)
    }
    try? await Task.sleep(for: .seconds(6))

    for id in ids {
        if let status = DeinitRegistery.status(for: id) {
            switch status {
            case .normal:
                print("Allocated")
            case .warning:
                print("Expected deallocation has not occurred")
            case .leak:
                print("Potential memory leak")
            }
        } else {
            print("Deallocated")
        }
    }
}
```

## Configuring Deallocation Delays

The default warning delay is 5 seconds. You can configure it using:

```swift
DeinitRegistery.setWarningDelay(10)
```

Similarly, the leak delay default is 30 seconds which can be configured using:

```swift
DeinitRegistery.setLeakDelay(10)
```

The warning and leak delays are cumulative. When shouldDeinit(_:) is called, the registry waits for the warning delay before beginning the leak delay.

| Elapsed Time | Status  |
|--------------|---------|
| 0 seconds    | Normal  |
| 10 seconds   | Warning |
| 20 seconds   | Leak    |

If the object deallocates at any point, it is removed from the registry.
A leak status indicates that an object has exceeded its expected deallocation time. It does not necessarily confirm a memory leak.

## SwiftUI Integration

TODO

# Usage

```swift
.package(
    url: "https://github.com/AryanRogye/Deinit.git",
    branch: "main"
)
```

```swift
dependencies: [
    .product(name: "Deinit", package: "Deinit")
]
```

## Macro Setup in Xcode

When using this package in an Xcode project for the first time,
you may need to explicitly trust and enable the macro.

1. Press **⌘ + 5** to open the Issue Navigator.
2. Click the macro validation warning at the top.

   <img src="./Assets/DebugNavigatiorWarning.png" width="600" alt="Macro validation warning in Xcode">

3. When the confirmation dialog appears, click **Trust & Enable**.

   <img src="./Assets/TrustAndEnableMacro.png" width="400" alt="Trust and enable macro confirmation dialog">

Once enabled, the macro is ready to use in your project.

# Known Issues

## Capture lists in an `@DeinitAttach` body don't compile (Swift 6.4.2)

A closure with a capture list (`[weak self]`, `[unowned self]`, `[weak x]`)
written directly inside an `@DeinitAttach` initializer fails to build:

```swift
@DeinitClass
final class Downloader {
    var onComplete: (() -> Void)?
    var finished = false

    @DeinitAttach
    init() {
        onComplete = { [weak self] in self?.finished = true } // ❌ won't build
    }

    @DeinitAttach
    deinit {}
}
```

```
error: failed to produce diagnostic for expression; please submit a bug report
```

This is a Swift compiler bug, not a bug in Deinit. It affects every
`@attached(body)` macro: a macro that returns the body unchanged fails the
same way. Closures without a capture list are not affected.

**Workaround:** move the closure setup into a method without a body macro and
call it from `init`:

```swift
@DeinitAttach
init() {
    start()
}

private func start() {
    onComplete = { [weak self] in self?.finished = true } // ✅ builds
}
```

Seen on Apple Swift 6.4.2 (`swiftlang-6.4.2.1.9`).
