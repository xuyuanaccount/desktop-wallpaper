import AppKit

@MainActor
enum EditingMenu {
    private static let commands: [(key: String, title: String, action: Selector)] = [
        ("x", "剪切", #selector(NSText.cut(_:))),
        ("c", "复制", #selector(NSText.copy(_:))),
        ("v", "粘贴", #selector(NSText.paste(_:))),
        ("a", "全选", #selector(NSText.selectAll(_:)))
    ]

    static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = menu.addItem(withTitle: "动态壁纸", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: app.title)
        appMenu.addItem(withTitle: "退出动态壁纸", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu

        let edit = menu.addItem(withTitle: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: edit.title)
        for command in commands {
            editMenu.addItem(withTitle: command.title, action: command.action, keyEquivalent: command.key)
        }
        edit.submenu = editMenu
        return menu
    }

    static func performShortcut(_ event: NSEvent) -> Bool {
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.type == .keyDown, event.modifierFlags.intersection(shortcutModifiers) == .command,
              let command = commands.first(where: { $0.key == event.charactersIgnoringModifiers?.lowercased() }),
              let editor = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView else { return false }

        // Accessory apps have no visible menu bar. Route the shortcut to the editor and honor its native validation.
        let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: command.key)
        guard editor.validateUserInterfaceItem(item) else { return false }
        return NSApp.sendAction(command.action, to: editor, from: item)
    }
}
