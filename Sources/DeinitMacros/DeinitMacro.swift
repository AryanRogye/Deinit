import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics
import Foundation

struct DeinitDiagnostic: DiagnosticMessage {
    let id: String
    let message: String
    var diagnosticID: MessageID {
        .init(domain: "DeinitMacro", id: id)
    }
    let severity: DiagnosticSeverity

    init(message: String, id: String, severity: DiagnosticSeverity) {
        self.message = message
        self.id = id
        self.severity = severity
    }
}

private func getBody(
    from declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax
) -> [CodeBlockItemListSyntax.Element] {
    return Array(declaration.body?.statements ?? [])
}

private func isFinal(
    on classDecl: ClassDeclSyntax,
) -> Bool {
    classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
}

public struct DeinitMacro: MemberMacro, ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) else {
            return []
        }
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
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: DeinitDiagnostic(
                        message: "@DeinitClass can only be applied to a class",
                        id: "DeinitClass",
                        severity: .error
                    )
                )
            )
            return []
        }
        if !isFinal(on: classDecl) {
            context.diagnose(
                Diagnostic(
                    node: Syntax(classDecl.name),
                    message: DeinitDiagnostic(
                        message: "@DeinitClass This class should be final",
                        id: "DeinitClass",
                        severity: .error
                    )
                )
            )
        }
        let className = classDecl.name.text
        return [
            """
            public let deinitObjectName = "\(raw: className)"
            public let deinitIdentifier = DeinitID()
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
            DeinitRegistry._register(self)
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
                DeinitRegistry._unregister(self.deinitIdentifier)
                """,
                at: 0
                )
            } else {
                existing.insert(
                """
                defer { DeinitRegistry._unregister(self.deinitIdentifier) }
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
