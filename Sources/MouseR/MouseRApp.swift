import SwiftUI

@main
struct MouseRApp: App {
    @StateObject private var mouse = MouseController()

    var body: some Scene {
        Window("MouseR", id: "main") {
            ContentView().environmentObject(mouse)
        }
        .windowResizability(.contentMinSize)
    }
}
