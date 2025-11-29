//
//  LiquidGlassDesignSystem.swift
//  scorewatch Watch App
//
//  Liquid Glass design system for watchOS
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

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(style.material)

                    if let tintColor = style.tintColor {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(tintColor.opacity(0.2))
                    }

                    if style.isInteractive {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.white.opacity(0.08))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
            )
    }
}

extension View {
    func glassEffect(_ style: GlassEffectStyle = .regular) -> some View {
        self.modifier(GlassEffectModifier(style: style, cornerRadius: 8))
    }
}

// MARK: - Glass Button Styles

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(configuration.isPressed ? 0.2 : 0.05))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

struct GlassProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.regularMaterial)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(configuration.isPressed ? 0.3 : 0.15))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
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
