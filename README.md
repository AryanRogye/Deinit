
# How To Use

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
