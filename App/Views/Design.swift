import SwiftUI

/// Motion and component rules (Emil Kowalski's design-engineering approach):
/// - UI motion uses strong ease-out curves and stays under 300 ms.
/// - Nothing animates when the user acted from the keyboard (shortcuts are used constantly).
/// - Pressable things scale to 0.97 so the app feels like it heard you.
/// - Things enter from somewhere (scale 0.98 + fade), never from scale 0.
/// - Exits are faster than entrances. Reduce Motion keeps fades, drops movement.
enum Motion {
    /// Strong ease-out for entering/responding: cubic-bezier(0.23, 1, 0.32, 1).
    static let out = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    static let outFast = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    /// For things moving on screen: cubic-bezier(0.77, 0, 0.175, 1).
    static let move = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.26)
    static let press = Animation.easeOut(duration: 0.14)

    static func rowTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)).animation(out),
            removal: .opacity.animation(outFast))
    }

    static func toastTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).animation(out),
            removal: .move(edge: .bottom).combined(with: .opacity).animation(outFast))
    }
}

/// Performs a change with no animation — for keyboard-initiated state changes.
func withoutAnimation(_ body: () -> Void) {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t, body)
}

struct PressableStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            }
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Icon-only toolbar-style button with press feedback and a hover wash.
struct IconButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

extension View {
    /// Subtle card used for rows and panels.
    func card(selected: Bool = false) -> some View {
        background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.clear))
        }
    }
}
