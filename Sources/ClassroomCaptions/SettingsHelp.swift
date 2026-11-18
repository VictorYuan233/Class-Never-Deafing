import AppKit
import SwiftUI

@MainActor
final class SettingsHelp: ObservableObject {
    private var pending: Task<Void, Never>?
    private var owner: UUID?
    private var tooltip: NSPanel?

    func hover(_ text: String, owner: UUID) {
        dismiss()
        self.owner = owner
        guard let window = NSApp.keyWindow else { return }
        pending = Task { [weak self, weak window] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self, let window, window.isKeyWindow, window.attachedSheet == nil else { return }
            self.show(text, over: window)
        }
    }

    func dismiss(owner: UUID? = nil) {
        guard owner == nil || self.owner == owner else { return }
        pending?.cancel()
        pending = nil
        self.owner = nil
        if let tooltip {
            tooltip.parent?.removeChildWindow(tooltip)
            tooltip.orderOut(nil)
        }
        tooltip = nil
    }

    private func show(_ text: String, over window: NSWindow) {
        guard let screen = window.screen else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 0
        let width = min(320, max(120, label.intrinsicContentSize.width))
        let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 18)
        let size = NSSize(width: width + 20, height: height + 14)
        let cursor = NSEvent.mouseLocation
        let area = screen.visibleFrame
        let x = min(max(cursor.x + 12, area.minX + 4), area.maxX - size.width - 4)
        let below = cursor.y - size.height - 18
        let y = below >= area.minY + 4 ? below : min(cursor.y + 20, area.maxY - size.height - 4)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .toolTip
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 10, y: 7, width: width, height: height)
        background.addSubview(label)
        panel.contentView = background
        panel.setAccessibilityHidden(true)
        window.addChildWindow(panel, ordered: .above)
        tooltip = panel
    }
}

private struct SettingsHelpModifier: ViewModifier {
    private final class Identity: ObservableObject { let id = UUID() }

    @EnvironmentObject private var help: SettingsHelp
    @StateObject private var identity = Identity()
    let text: String

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .onHover { inside in
                if inside { help.hover(text, owner: identity.id) }
                else { help.dismiss(owner: identity.id) }
            }
            .onDisappear { help.dismiss(owner: identity.id) }
    }
}

extension View {
    func settingsHelp(_ text: String) -> some View {
        modifier(SettingsHelpModifier(text: text))
    }
}

struct DefaultChoicePicker<Choice: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Choice
    let choices: [Choice]
    let defaultChoice: Choice
    let label: (Choice) -> String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, choices: choices) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.setAccessibilityLabel(title)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.select(_:))
        for choice in choices {
            popup.addItem(withTitle: label(choice))
            if choice == defaultChoice, let item = popup.lastItem {
                let display = NSMutableAttributedString(string: label(choice))
                display.append(NSAttributedString(string: " （默认）", attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                item.attributedTitle = display
                item.setAccessibilityLabel("\(label(choice))（默认）")
            }
        }
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if let index = choices.firstIndex(of: selection) { popup.selectItem(at: index) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Choice>
        let choices: [Choice]

        init(selection: Binding<Choice>, choices: [Choice]) {
            self.selection = selection
            self.choices = choices
        }

        @objc func select(_ popup: NSPopUpButton) {
            let index = popup.indexOfSelectedItem
            if choices.indices.contains(index) { selection.wrappedValue = choices[index] }
        }
    }
}
