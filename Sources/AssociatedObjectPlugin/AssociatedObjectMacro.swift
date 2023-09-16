//
//  AssociatedObjectMacro.swift
//
//
//  Created by p-x9 on 2023/06/12.
//
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct AssociatedObjectMacro {}

extension AssociatedObjectMacro: PeerMacro {
    public static func expansion<Context: MacroExpansionContext, Declaration: DeclSyntaxProtocol>(
        of node: AttributeSyntax,
        providingPeersOf declaration: Declaration,
        in context: Context
    ) throws -> [DeclSyntax] {

        guard let varDecl = declaration.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
            context.diagnose(AssociatedObjectMacroDiagnostic.requiresVariableDeclaration.diagnose(at: declaration))
            return []
        }

        let keyDecl = VariableDeclSyntax(
            bindingSpecifier: .identifier("static var"),
            bindings: PatternBindingListSyntax {
                PatternBindingSyntax(
                    pattern: IdentifierPatternSyntax(identifier: .identifier("__associated_\(identifier)Key")),
                    typeAnnotation: .init(type: IdentifierTypeSyntax(name: .identifier("UInt8"))),
                    initializer: InitializerClauseSyntax(value: ExprSyntax(stringLiteral: "0"))
                )
            }
        )

        return [
            DeclSyntax(keyDecl)
        ]
    }
}

extension AssociatedObjectMacro: AccessorMacro {
    public static func expansion<Context: MacroExpansionContext, Declaration: DeclSyntaxProtocol>(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: Declaration,
        in context: Context
    ) throws -> [AccessorDeclSyntax] {

        guard let varDecl = declaration.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
        else {
            // Probably can't add a diagnose here, since this is an Accessor macro
            context.diagnose(AssociatedObjectMacroDiagnostic.requiresVariableDeclaration.diagnose(at: declaration))
            return []
        }

        if varDecl.bindings.count > 1 {
            context.diagnose(AssociatedObjectMacroDiagnostic.multipleVariableDeclarationIsNotSupported.diagnose(at: binding))
            return []
        }

        //  Explicit specification of type is required
        guard let type = binding.typeAnnotation?.type else {
            context.diagnose(AssociatedObjectMacroDiagnostic.specifyTypeExplicitly.diagnose(at: identifier))
            return []
        }

        // Error if setter already exists
        if let setter = binding.setter {
            context.diagnose(AssociatedObjectMacroDiagnostic.getterAndSetterShouldBeNil.diagnose(at: setter))
            return []
        }

        // Error if getter already exists
        if let getter = binding.getter {
            context.diagnose(AssociatedObjectMacroDiagnostic.getterAndSetterShouldBeNil.diagnose(at: getter))
            return []
        }

        let defaultValue = binding.initializer?.value
        // Initial value required if type is optional
        if defaultValue == nil && !type.isOptional {
            context.diagnose(AssociatedObjectMacroDiagnostic.requiresInitialValue.diagnose(at: declaration))
            return []
        }

        guard case let .argumentList(arguments) = node.arguments,
              let firstElement = arguments.first?.expression,
              let policy = firstElement.as(MemberAccessExprSyntax.self) else {
            return []
        }

        return [
            AccessorDeclSyntax(
                accessorSpecifier: .keyword(.get),
                body: CodeBlockSyntax {
                    """
                    objc_getAssociatedObject(
                        self,
                        &Self.__associated_\(identifier)Key
                    ) as? \(type)
                    ?? \(defaultValue ?? "nil")
                    """
                }
            ),

            AccessorDeclSyntax(
                accessorSpecifier: .keyword(.set),
                body: CodeBlockSyntax {
                    if let willSet = binding.willSet,
                       let body = willSet.body {
                        let newValue = willSet.parameters?.name.trimmed ?? .identifier("newValue")
                        """
                        let willSet: (\(type.trimmed)) -> Void = { [self] \(newValue) in
                            \(body.statements.trimmed)
                        }
                        willSet(newValue)
                        """
                    }

                    if binding.didSet != nil {
                        "let oldValue = \(identifier)"
                    }

                    """
                    objc_setAssociatedObject(
                        self,
                        &Self.__associated_\(identifier)Key,
                        newValue,
                        \(policy)
                    )
                    """

                    if let didSet = binding.didSet,
                       let body = didSet.body {
                        let oldValue = didSet.parameters?.name.trimmed ?? .identifier("oldValue")
                        """
                        let didSet: (\(type.trimmed)) -> Void = { [self] \(oldValue) in
                            \(body.statements.trimmed)
                        }
                        didSet(oldValue)
                        """
                    }
                })
        ]
    }
}
