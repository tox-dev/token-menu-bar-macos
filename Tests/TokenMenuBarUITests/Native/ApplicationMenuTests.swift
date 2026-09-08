import AppKit
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Suite(.serialized)
struct ApplicationMenuTests {
  @Test @MainActor func installedMainMenuBindsEditingAndWindowCommands() throws {
    prepareTestApp()
    let application = NSApplication.shared
    let previousMainMenu = application.mainMenu
    let previousWindowsMenu = application.windowsMenu
    defer {
      application.mainMenu = previousMainMenu
      application.windowsMenu = previousWindowsMenu
    }

    ApplicationMenu.install(on: application, appName: "Token Menu Bar")

    let mainMenu = try #require(application.mainMenu)
    let submenus = Dictionary(uniqueKeysWithValues: mainMenu.items.compactMap(\.submenu).map { ($0.title, $0) })
    let edit = try #require(submenus["Edit"])
    let expected: [(title: String, action: Selector, key: String)] = [
      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ]
    for (title, action, key) in expected {
      let item = try #require(edit.items.first { $0.title == title })
      #expect(item.action == action)
      #expect(item.keyEquivalent == key)
      #expect(item.keyEquivalentModifierMask == .command)
    }
    let window = try #require(submenus["Window"])
    let close = try #require(window.items.first { $0.title == "Close" })
    #expect(close.action == #selector(NSWindow.performClose(_:)))
    #expect(close.keyEquivalent == "w")
    #expect(application.windowsMenu === window)
    #expect(submenus[""]?.items.first?.title == "Quit Token Menu Bar")
    #expect(submenus[""]?.items.first?.action == #selector(NSApplication.terminate(_:)))
  }
}
