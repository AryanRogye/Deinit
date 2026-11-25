//
//  DeinitRegistry.swift
//  Deinit
//
//  Created by Aryan Rogye on 11/23/26.
//

import Foundation

public enum DeinitRegistryStatus: String, Sendable {
    case normal = "Normal"
    case warning = "Warning"
    case leak = "Leak"

    var label: String {
        switch self {
        case .normal:
            "✅"
        case .warning:
            "⚠️"
        case .leak:
            "🚨"
        }
    }
}

private struct TrackedObject: Sendable {
    let identifier: UUID
    let objectIdentifier: ObjectIdentifier
    let name: String
    var status: DeinitRegistryStatus
}

public final class DeinitRegistry: Sendable {

    nonisolated(unsafe) private static var trackableObjects: [UUID: TrackedObject] = [:]
    nonisolated(unsafe) private static var shouldDeinitTrackers: [UUID: Task<Void, Never>] = [:]

    nonisolated(unsafe) private static var warningDelay: Double = 5
    nonisolated(unsafe) private static var leakDelay: Double = 30

    nonisolated(unsafe) private static var onUpdate: (@MainActor ([ListResult]) -> Void)?

    private static let lock = NSLock()

    private init() {}
}

// MARK: - Setters
extension DeinitRegistry {
    public static func assignOnUpdate(_ closure: @escaping @MainActor ([ListResult]) -> Void) {
        lock.withLock {
            onUpdate = closure
        }
    }

    public static func removeOnUpdate() {
        lock.withLock {
            onUpdate = nil
        }
    }

    /// Set delay in which a warning status will be set for a object that should be
    /// deallocated
    public static func setWarningDelay(_ delay: Double) {
        lock.withLock {
            warningDelay = delay
        }
    }

    /// Set delay in which a leak status will be set for a object that should be
    /// deallocated
    public static func setLeakDelay(_ delay: Double) {
        lock.withLock {
            leakDelay = delay
        }
    }
}

// MARK: - Helpers
extension DeinitRegistry {

    /// A snapshot of a tracked object's identity and deallocation status.
    /// Contains metadata only and does not retain the tracked object.
    public struct ListResult: Hashable {

        /// The name of the tracked object's type.
        public let name: String

        /// The unique identifier assigned by the registry.
        public let id: UUID

        /// The runtime identity of the tracked object.
        public let objectIdentifier: ObjectIdentifier

        /// The object's deallocation status at the time of retrieval.
        public let status: DeinitRegistryStatus
    }

    /// Returns a snapshot of all objects currently tracked by the registry.
    ///
    /// This operation is thread-safe and does not retain any tracked objects.
    /// The returned results are unordered and may become outdated as
    /// objects are registered, deallocated, or change status.
    ///
    /// - Returns: An array containing the metadata and deallocation
    ///   status of each tracked object.
    public static func detailedList() -> [ListResult] {
        lock.withLock {
            trackableObjects.values.map {
                .init(
                    name: $0.name,
                    id: $0.identifier,
                    objectIdentifier: $0.objectIdentifier,
                    status: $0.status
                )
            }
        }
    }

    /// Lists out all registered objects in the format
    /// "Name: ObjectIdentifier [Status]"
    public static func list() -> [String] {
        lock.withLock {
            trackableObjects.values.map {
                "\($0.name): \($0.objectIdentifier) [\($0.status)]"
            }
        }
    }

    /// Function to reset all values stored by the registery
    /// This should not really be used
    public static func reset() {
        lock.withLock {
            for id in trackableObjects.keys {
                trackableObjects.removeValue(forKey: id)
                if let task = shouldDeinitTrackers.removeValue(forKey: id) {
                    task.cancel()
                }
            }
        }
        notify()
    }

    /// Returns if the object still exists
    ///
    /// - Parameter object: The object to check if it is deallocated or not
    public static func doesObjectExist(_ object: any DeinitTrackable) -> Bool {
        lock.withLock {
            trackableObjects[object.deinitIdentifier] != nil
        }
    }

    /// Returns if the object still exists
    ///
    /// - Paramter id: The id to check if the object was deallocated or not
    public static func doesObjectExist(_ id: UUID) -> Bool {
        lock.withLock {
            trackableObjects[id] != nil
        }
    }

    /// Returns status for the object
    ///
    /// - Parameter object: The object to get the status of
    public static func status(for object: any DeinitTrackable) -> DeinitRegistryStatus? {
        lock.withLock {
            return trackableObjects[object.deinitIdentifier]?.status
        }
    }

    /// Returns status for the object
    ///
    /// - Parameter id: The object id to get the status of
    public static func status(for id: UUID) -> DeinitRegistryStatus? {
        lock.withLock {
            return trackableObjects[id]?.status
        }
    }

    /// Returns if any object registered with the `DeinitRegistry`
    /// is leaking or not.
    public static func doesAnyLeaksExist() -> Bool {
        lock.withLock {
            return trackableObjects.values.filter { $0.status == .leak }.isEmpty == false
        }
    }

    /// Return to if any object registered with the `DeinitRegistry`
    /// is leaking or not.
    public static func doesAnyWarningsExist() -> Bool {
        lock.withLock {
            return trackableObjects.values.filter { $0.status == .warning }.isEmpty == false
        }
    }
}

// MARK: - Internal Helpers
extension DeinitRegistry {

    /// Internal list function used when we need to call list
    /// in a function using a lock
    private static func unsafeList() ->  [String] {
        trackableObjects.values.map {
            "\($0.name): \($0.objectIdentifier) [\($0.status)]"
        }
    }

    /// Internal detailed list function used when we need to call detailedList
    /// in a function using a lock
    private static func unsafeDetailedList() -> [ListResult] {
        trackableObjects.values.map {
            .init(name: $0.name, id: $0.identifier, objectIdentifier: $0.objectIdentifier, status: $0.status)
        }
    }

    /// calls the `onUpdate` callback if it was set
    private static func notify() {
        let (callback, snapshot) = lock.withLock {
            (onUpdate, onUpdate == nil ? [] : unsafeDetailedList())
        }
        DispatchQueue.main.async {
            callback?(snapshot)
        }
    }
}

// MARK: - Should Deinit
extension DeinitRegistry {
    /// Begins monitoring an object that is expected to be deallocated.
    ///
    /// If the object remains alive after `warningDelay` seconds, its status is set to
    /// `.warning`. If it remains alive after the subsequent timeout: `leakDelay`,
    /// its status is set to `.leak`, indicating a potential memory leak.
    ///
    /// Monitoring is automatically cancelled when the object is deallocated.
    ///
    /// - Parameter object: The object expected to be deallocated.
    public static func shouldDeinit(_ object: any DeinitTrackable) {
        lock.withLock {
            let identifier = object.deinitIdentifier

            /// Make sure the object didnt already get destroyed
            guard trackableObjects[identifier] != nil else {
                return
            }
            /// Make sure that the objects status is not already set to a leak
            guard trackableObjects[identifier]?.status != .leak else {
                return
            }
            /// Make sure there already isnt a tracker on this object
            guard shouldDeinitTrackers[identifier] == nil else {
                return
            }
            shouldDeinitTrackers[object.deinitIdentifier] = Task {
                /// make sure that the status is only normal or warning, if its leak then the `_unregister`
                /// should remove it
                guard let status = lock.withLock({ trackableObjects[identifier]?.status }), status != .leak else {
                    return
                }

                /// if normal we wait for `warningDelay` seconds and see if we can get a status again
                /// if it doenst exist then that means it got deallocated
                /// if it still does exist we mark it as a warning
                if status == .normal {
                    try? await Task.sleep(for: .seconds(lock.withLock{ warningDelay }))
                    if Task.isCancelled { return }
                    if lock.withLock({ trackableObjects[identifier] }) == nil {
                        return
                    }
                }
                lock.withLock {
                    trackableObjects[identifier]?.status = .warning
                }
                notify()

                /// This point means that status is a warning
                /// so now we wait 30 seconds and we collect the
                /// status again, this time if its not nil
                /// then we mark it as leaked
                try? await Task.sleep(for: .seconds(lock.withLock{ leakDelay }))
                if Task.isCancelled { return }
                if lock.withLock({ trackableObjects[identifier] == nil }) {
                    return
                }
                lock.withLock {
                    trackableObjects[identifier]?.status = .leak
                }
                notify()
            }
        }
    }
}

// MARK: - Creation
extension DeinitRegistry {

    /// This should not be publicly called. This is only called
    /// by a class's init that implements the `DeinitTrackable`
    /// through the macro extension.
    public static func _register(_ object: any DeinitTrackable) {
        lock.withLock {
            trackableObjects[object.deinitIdentifier] = .init(
                identifier: object.deinitIdentifier,
                objectIdentifier: ObjectIdentifier(object),
                name: object.deinitObjectName,
                status: .normal
            )
        }
        notify()
    }

    /// This should not be publicly called. This is only called
    /// by a class's deinit that implements the `DeinitTrackable`
    /// through the macro extension.
    public static func _unregister(_ object: any DeinitTrackable) {
        lock.withLock {
            trackableObjects.removeValue(forKey: object.deinitIdentifier)
            if let task = shouldDeinitTrackers.removeValue(forKey: object.deinitIdentifier) {
                task.cancel()
            }
        }
        notify()
    }

    public static func _unregister(_ id: UUID) {
        lock.withLock {
            trackableObjects.removeValue(forKey: id)
            if let task = shouldDeinitTrackers.removeValue(forKey: id) {
                task.cancel()
            }
        }
        notify()
    }
}
