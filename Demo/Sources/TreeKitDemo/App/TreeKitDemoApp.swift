import SwiftUI

@main
struct TreeKitDemoApp: App {
  var body: some Scene {
    WindowGroup("TreeKit Demo") {
      ContentView()
    }
    .defaultSize(width: 1_100, height: 700)
    .windowResizability(.contentMinSize)
  }
}
