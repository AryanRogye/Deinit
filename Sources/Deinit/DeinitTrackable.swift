//
//  DeinitTrackable.swift
//  Deinit
//
//  Created by Aryan Rogye on 11/23/26.
//

import Foundation

public typealias DeinitID = UUID

public protocol DeinitTrackable: AnyObject {
    nonisolated var deinitObjectName: String { get }
    nonisolated var deinitIdentifier: UUID { get }
}
