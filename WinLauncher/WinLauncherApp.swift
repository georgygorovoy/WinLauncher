import SwiftUI

@main
struct WinLauncherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
                .task { await model.start() }
                .onOpenURL { model.receiveDrop([$0]) }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Windows App…") { model.chooseWindowsFile() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 680, height: 520)
        }
    }
}
