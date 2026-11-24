// The Swift Programming Language
// https://docs.swift.org/swift-book

@attached(member, names: named(deinitIdentifier), named(deinitObjectName))
@attached(extension, conformances: DeinitTrackable)
public macro DeinitClass() = #externalMacro(
    module: "DeinitMacros",
    type: "DeinitMacro"
)

@attached(body)
public macro DeinitAttach() = #externalMacro(
    module: "DeinitMacros",
    type: "DeinitAttachMacro"
)
