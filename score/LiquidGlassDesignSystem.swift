//
//  LiquidGlassDesignSystem.swift
//  score
//
//  Liquid Glass design system components for fluid, translucent UI elements
//

import SwiftUI

// MARK: - Glass Effect Configuration

struct GlassEffectStyle {
    var material: Material
    var tintColor: Color?
    var isInteractive: Bool

    static let regular = GlassEffectStyle(
        material: .ultraThinMaterial,
        tintColor: nil,
        isInteractive: false
    )

    static let thick = GlassEffectStyle(
        material: .regularMaterial,
        tintColor: nil,
        isInteractive: false
    )

    static let thin = GlassEffectStyle(
        material: .ultraThinMaterial,
        tintColor: nil,
        isInteractive: false
    )

    func tint(_ color: Color) -> GlassEffectStyle {
        GlassEffectStyle(
            material: self.material,
            tintColor: color,
            isInteractive: self.isInteractive
        )
    }

    func interactive() -> GlassEffectStyle {
        GlassEffectStyle(
            material: self.material,
            tintColor: self.tintColor,
            isInteractive: true
        )
    }
}

// MARK: - Glass Effect View Modifier

struct GlassEffectModifier: ViewModifier {
    let style: GlassEffectStyle
    let cornerRadius: CGFloat
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Base glass material
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(style.material)

                    // Optional tint overlay
                    if let tintColor = style.tintColor {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(tintColor.opacity(0.15))
                    }

                    // Interactive highlight effect
                    if style.isInteractive {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.white.opacity(isPressed ? 0.15 : 0.05))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            )
            .scaleEffect(style.isInteractive && isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
    }
}

// MARK: - Glass Effect In Shape Modifier

struct GlassEffectInShapeModifier: ViewModifier {
    let style: GlassEffectStyle
    let shape: AnyShape

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Base glass material
                    shape
                        .fill(style.material)

                    // Optional tint overlay
                    if let tintColor = style.tintColor {
                        shape
                            .fill(tintColor.opacity(0.15))
                    }
                }
            )
            .overlay(
                shape
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
    }
}

// MARK: - Shape Helper

struct AnyShape: Shape, @unchecked Sendable {
    private let _path: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        _path = { rect in
            shape.path(in: rect)
        }
    }

    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

// MARK: - View Extension

extension View {
    /// Applies a liquid glass effect with default rounded corners
    func glassEffect(_ style: GlassEffectStyle = .regular) -> some View {
        self.modifier(GlassEffectModifier(style: style, cornerRadius: 12))
    }

    /// Applies a liquid glass effect with a custom shape
    func glassEffect<S: Shape>(in shape: S) -> some View {
        self.modifier(GlassEffectInShapeModifier(
            style: .regular,
            shape: AnyShape(shape)
        ))
    }
}

// MARK: - Glass Effect Container

struct GlassEffectContainer<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(spacing: spacing) {
            content()
        }
    }
}

// MARK: - Glass Button Styles

struct GlassButtonStyle: ButtonStyle {
    var material: Material = .ultraThinMaterial

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(material)

                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(configuration.isPressed ? 0.2 : 0.05))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct GlassProminentButtonStyle: ButtonStyle {
    var material: Material = .regularMaterial

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(material)

                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(configuration.isPressed ? 0.3 : 0.15))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle {
        GlassButtonStyle()
    }
}

extension ButtonStyle where Self == GlassProminentButtonStyle {
    static var glassProminent: GlassProminentButtonStyle {
        GlassProminentButtonStyle()
    }
}
