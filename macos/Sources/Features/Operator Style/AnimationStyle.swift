#if os(macOS)
import SwiftUI

// Five motion personalities for the chrome.
// Stored in UserDefaults so it survives relaunches and is readable from any context.

enum AnimationStyle: String, CaseIterable, Identifiable {
    case original  = "original"   // rotating conic gradient
    case radar     = "radar"      // radial sweep + phosphor trail
    case waveform  = "waveform"   // oscilloscope / sine wave
    case comet     = "comet"      // comet arc + falling streams
    case geometric = "geometric"  // stepping diamond, no continuous spin

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original:  return "Original"
        case .radar:     return "Radar"
        case .waveform:  return "Waveform"
        case .comet:     return "Comet"
        case .geometric: return "Geometric"
        }
    }

    var symbol: String {
        switch self {
        case .original:  return "◌"
        case .radar:     return "⊕"
        case .waveform:  return "∿"
        case .comet:     return "★"
        case .geometric: return "◇"
        }
    }
}

extension UserDefaults {
    static let animStyleKey = "operatorAnimStyle"
    var animStyle: AnimationStyle {
        get { AnimationStyle(rawValue: string(forKey: Self.animStyleKey) ?? "") ?? .original }
        set { set(newValue.rawValue, forKey: Self.animStyleKey) }
    }
}

/// Context-menu items — right-click the sigil to change style.
struct AnimationStyleMenuItems: View {
    @AppStorage(UserDefaults.animStyleKey) private var styleKey: String = AnimationStyle.original.rawValue

    var body: some View {
        ForEach(AnimationStyle.allCases) { style in
            Button {
                styleKey = style.rawValue
            } label: {
                HStack {
                    Text(style.symbol).frame(width: 14)
                    Text(style.label)
                    if styleKey == style.rawValue {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }
}

/// Single-tap menu button for the sidebar header — shows the current style's symbol.
struct AnimationStyleMenuButton: View {
    @AppStorage(UserDefaults.animStyleKey) private var styleKey: String = AnimationStyle.original.rawValue
    private var current: AnimationStyle { AnimationStyle(rawValue: styleKey) ?? .original }

    var body: some View {
        Menu {
            AnimationStyleMenuItems()
        } label: {
            Text(current.symbol)
                .font(.system(size: 11))
                .foregroundColor(Operator.dim.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Operator.raised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Animation style: \(current.label)")
    }
}

/// Compact inline strip for the sidebar header.
struct AnimationStylePicker: View {
    @AppStorage(UserDefaults.animStyleKey) private var styleKey: String = AnimationStyle.original.rawValue

    var body: some View {
        HStack(spacing: 1) {
            ForEach(AnimationStyle.allCases) { style in
                let selected = styleKey == style.rawValue
                Button {
                    styleKey = style.rawValue
                } label: {
                    Text(style.symbol)
                        .font(.system(size: 9))
                        .frame(width: 22, height: 15)
                        .foregroundColor(selected ? Operator.gold : Operator.dim.opacity(0.7))
                        .background(selected ? Operator.gold.opacity(0.14) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help(style.label)
            }
        }
    }
}
#endif
