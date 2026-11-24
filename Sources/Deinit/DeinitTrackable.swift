//
//  DeinitTrackable.swift
//  Deinit
//
//  Created by Aryan Rogye on 11/23/26.
//

import Foundation

public typealias DeinitID = UUID

public protocol DeinitTrackable: AnyObject {
    var deinitObjectName: String { get }
    var deinitIdentifier: UUID { get }
}
