//
//  DeinitViewModel.swift
//  Deinit
//
//  Created by Aryan Rogye on 11/24/26.
//

import Foundation
import Observation

@Observable
@MainActor
public final class DeinitViewModel {
    /// Public accessor
    public static let shared = DeinitViewModel()

    /// Tracked allocations grouped by their object names.
    /// Each Containing:
    /// name, id, objectIdentifier, status
    public private(set) var allocationNames: [String: [DeinitRegistery.ListResult]] = [:]

    /// Private initializer to avoid anyone running DeinitViewModel.init()
    private init() { startTracking() }

    /// Begins observing allocation updates from the registry.
    public func startTracking() {
        DeinitRegistery.assignOnUpdate { [weak self] list in
            guard let self else { return }
            self.allocationNames = Dictionary(grouping: list, by: \.name)
        }
    }

    /// Stops observing allocation updates from the registry.
    /// Existing allocation data is preserved.
    public func stopTracking() {
        DeinitRegistery.removeOnUpdate()
    }
}
