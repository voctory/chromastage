import AppKit
import SwiftUI

@main
struct ChromastageApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .windowStyle(.titleBar)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Chromastage") {
          showAbout()
        }
      }
    }

    Settings {
      SettingsView()
    }
  }
}

@MainActor
private func showAbout() {
  NSApp.activate(ignoringOtherApps: true)

  let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
  let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
  let versionString = build.isEmpty ? version : "\(version) (\(build))"

  let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
  let credits = NSMutableAttributedString(string: "MIT License\n", attributes: [
    .font: font,
  ])
  credits.append(NSAttributedString(string: "Copyright (c) 2013-2018 Jordan Berg\n", attributes: [
    .font: font,
  ]))
  credits.append(NSAttributedString(string: "Copyright (c) 2026 Victor Vannara", attributes: [
    .font: font,
  ]))

  let options: [NSApplication.AboutPanelOptionKey: Any] = [
    .applicationName: "Chromastage",
    .applicationVersion: versionString,
    .version: versionString,
    .credits: credits,
    .applicationIcon: (NSApplication.shared.applicationIconImage ?? NSImage()) as Any,
  ]

  NSApp.orderFrontStandardAboutPanel(options: options)

  if let aboutPanel = NSApp.windows.first(where: { $0.className.contains("About") }) {
    removeFocusRings(in: aboutPanel.contentView)
  }
}

@MainActor
private func removeFocusRings(in view: NSView?) {
  guard let view else { return }
  if let imageView = view as? NSImageView {
    imageView.focusRingType = .none
  }
  for subview in view.subviews {
    removeFocusRings(in: subview)
  }
}
