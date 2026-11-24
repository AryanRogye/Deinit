//
//  DeinitRegistery.swift
//  Deinit
//
//  Created by Aryan Rogye on 11/23/26.
//

import Foundation

public enum DeinitRegisteryStatus: Sendable {
    case normal
    case warning
    case leak
}

private struct TrackedObject: Sendable {
    let identifier: UUID
    let objectIdentifier: ObjectIdentifier
    let name: String
    var status: DeinitRegisteryStatus
}

public final class DeinitRegistery: Sendable {

    nonisolated(unsafe) private static var trackableObjects: [UUID: TrackedObject] = [:]
    nonisolated(unsafe) private static var shouldDeinitTrackers: [UUID: Task<Void, Never>] = [:]

    nonisolated(unsafe) private static var warningDelay: Double = 5
    nonisolated(unsafe) private static var leakDelay: Double = 30

    private static let lock = NSLock()

    private init() {}

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

    /// Lists out all registered objects in the format
    /// "Name: ObjectIdentifier [Status]"
    public static func list() -> [String] {
        lock.withLock {
            trackableObjects.values.map {
                "\($0.name): \($0.objectIdentifier) [\($0.status)]"
            }
        }
    }

    public static func reset() {
        lock.withLock {
            for id in trackableObjects.keys {
                trackableObjects.removeValue(forKey: id)
                if let task = shouldDeinitTrackers.removeValue(forKey: id) {
                    task.cancel()
                }
            }
        }
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
    public static func status(for object: any DeinitTrackable) -> DeinitRegisteryStatus? {
        lock.withLock {
            return trackableObjects[object.deinitIdentifier]?.status
        }
    }

    /// Returns status for the object
    ///
    /// - Parameter id: The object id to get the status of
    public static func status(for id: UUID) -> DeinitRegisteryStatus? {
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
            }
        }
    }
}

// MARK: - Creation
extension DeinitRegistery {

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
    }

    public static func _unregister(_ id: UUID) {
        lock.withLock {
            trackableObjects.removeValue(forKey: id)
            if let task = shouldDeinitTrackers.removeValue(forKey: id) {
                task.cancel()
            }
        }
    }

}
