import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation


private func getBody(
    from declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax
) -> [CodeBlockItemListSyntax.Element] {
    return Array(declaration.body?.statements ?? [])
}

public struct DeinitMacro: MemberMacro, ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        return [
            try ExtensionDeclSyntax(
                "extension \(type): DeinitTrackable"
            ) {}
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            return []
        }
        let className = classDecl.name.text
        return [
            """
            let deinitObjectName = "\(raw: className)"
            let deinitIdentifier = DeinitID()
            """
        ]
    }
}

public struct DeinitAttachMacro: BodyMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {

        if declaration.as(InitializerDeclSyntax.self) != nil {
            var existing = getBody(from: declaration)

            existing.insert(
            """
            DeinitRegistery._register(self)
            """,
            at: existing.count
            )

            return existing
        }

        if declaration.as(DeinitializerDeclSyntax.self) != nil {
            var existing = getBody(from: declaration)

            if existing.isEmpty {
                existing.insert(
                """
                DeinitRegistery._unregister(self)
                """,
                at: 0
                )
            } else {
                existing.insert(
                """
                defer { DeinitRegistery._unregister(self) }
                """,
                at: 0
                )
            }

            return existing
        }

        return getBody(from: declaration)
    }
}

@main
struct DeinitPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        DeinitAttachMacro.self,
        DeinitMacro.self
    ]
}
