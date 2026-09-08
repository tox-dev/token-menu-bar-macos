import AppKit

@MainActor
public enum ApplicationMenu {
  public static func install(on application: NSApplication, appName: String) {
    let mainMenu = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(
      NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    let appMenuItem = NSMenuItem()
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redo)
    editMenu.addItem(.separator())
    editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    let editMenuItem = NSMenuItem()
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    let windowMenuItem = NSMenuItem()
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    application.mainMenu = mainMenu
    application.windowsMenu = windowMenu
  }
}
