import SwiftUI

/// Segmented control in the warm-gray grok.com style: a rounded track with a clearly raised selected pill.
/// Light: white pill on an F0EFED track. Dark: light pill on a dark track, like the system control it replaces.
struct SegmentedTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(Theme.ui(13, selected ? .medium : .regular))
                        .foregroundStyle(selected ? selectedText : Theme.fg2)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(selectedFill)
                                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.10), radius: 1.5, y: 1)
                                    .overlay(Capsule().stroke(Color.black.opacity(scheme == .dark ? 0 : 0.06), lineWidth: 0.5))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(track))
        .fixedSize()
    }

    private var track: Color { scheme == .dark ? Color(white: 1, opacity: 0.10) : Color(red: 240 / 255, green: 239 / 255, blue: 237 / 255) }
    private var selectedFill: Color { scheme == .dark ? Color(white: 0.99) : .white }
    private var selectedText: Color { scheme == .dark ? Color(white: 0.02) : Theme.fg1 }
}
