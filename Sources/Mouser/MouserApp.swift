import SwiftUI

@main
struct MouserApp: App {
    @StateObject private var mouse = MouseController()

    var body: some Scene {
        Window("Mouser", id: "main") {
            ContentView().environmentObject(mouse)
        }
        .windowResizability(.contentMinSize)
    }
}
