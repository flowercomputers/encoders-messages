import AppKit

/// Makes the whole window behave like the search field. Whenever the app is
/// active and the field does not have keyboard focus (after clicking a result,
/// say), typing a letter or digit starts a search, and the arrow keys, Return
/// and Escape still drive the results.
@MainActor
final class KeyboardRouter {
    private var monitor: Any?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model, let window = event.window, window.isKeyWindow,
                  window.attachedSheet == nil,
                  // Already typing in a text field: leave the event alone.
                  !(window.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control]).isEmpty
            else { return event }

            switch event.keyCode {
            case 125: model.moveSelection(1); return nil     // down
            case 126: model.moveSelection(-1); return nil    // up
            case 36, 76: model.openSelection(); return nil   // return, enter
            case 53: model.query = ""; return nil            // escape
            default: break
            }

            guard let character = event.charactersIgnoringModifiers?.first,
                  character.isLetter || character.isNumber,
                  let field = Self.searchField(in: window),
                  window.makeFirstResponder(field)
            else { return event }
            // Focusing a field selects its text; put the cursor at the end
            // instead, so the key adds to the query rather than replacing it.
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
            }
            return event  // now delivered to the field, which types it
        }
    }

    /// The window's one editable text field (it lives in the toolbar).
    private static func searchField(in window: NSWindow) -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            for subview in view.subviews {
                if let field = find(subview) { return field }
            }
            return nil
        }
        return (window.contentView?.superview ?? window.contentView).flatMap(find)
    }
}
