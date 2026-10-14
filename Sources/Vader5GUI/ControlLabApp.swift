import SwiftUI
import AppKit

@MainActor
final class ControlLabAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BridgeViewModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.deviceBusy == true {
            NSSound.beep()
            return .terminateCancel
        }
        return .terminateNow
    }
}

@main
struct ControlLabApp: App {
    @NSApplicationDelegateAdaptor(ControlLabAppDelegate.self) private var appDelegate
    @StateObject private var model = BridgeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { appDelegate.model = model }
                .frame(minWidth: 1120, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1336, height: 950)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
