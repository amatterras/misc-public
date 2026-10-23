// Asks iOS to redraw THEapp's home-screen widgets. Kept in its own file:
// with `import WidgetKit` (which brings in SwiftUI) next to `import PhotosUI`
// in AppDelegate.swift, the cloud build could no longer find the PhotosUI
// picker types.
import WidgetKit

enum WidgetReload {
  static func all() {
    WidgetCenter.shared.reloadAllTimelines()
  }
}
