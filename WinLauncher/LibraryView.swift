import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 18)]

    var body: some View {
        NavigationStack {
            Group {
                if model.applications.isEmpty {
                    welcome
                } else {
                    library
                }
            }
            .navigationTitle("Apps")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: model.chooseApplicationFile) {
                        Label("Open App", systemImage: "plus")
                    }
                    .disabled(model.operation != .idle)
                }
            }
            .overlay(alignment: .bottom) { operationStatus }
        }
        .sheet(isPresented: $model.showingEngineSetup) {
            EngineSetupView()
                .environmentObject(model)
        }
        .sheet(item: $model.compatibilityHelp) { help in
            CompatibilityHelpView(help: help)
                .environmentObject(model)
        }
        .alert(item: $model.failure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.message),
                primaryButton: failure.logURL == nil ? .default(Text("OK")) : .default(Text("Show Log")) {
                    if let log = failure.logURL { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Run Windows and Android apps on your Mac.")
                    .font(.largeTitle.weight(.semibold))
                Text("Open an .exe, .msi, or .apk. WinLauncher prepares the appropriate environment automatically.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            dropArea
                .frame(maxWidth: 560, minHeight: 150)
            Button("Open App", action: model.chooseApplicationFile)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.operation != .idle)
            Spacer()
        }
        .padding(36)
    }

    private var library: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.applications) { application in
                    ApplicationCard(application: application)
                        .environmentObject(model)
                }
                dropArea.frame(minHeight: 170)
            }
            .padding(28)
        }
    }

    private var dropArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 29, weight: .regular))
            Text("Drop an .exe, .msi, or .apk here")
                .font(.headline)
            Text("The correct environment is selected automatically")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.22),
                        lineWidth: dropTargeted ? 2 : 1)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.receiveDrop(urls)
            return urls.contains { ["exe", "msi", "apk"].contains($0.pathExtension.lowercased()) }
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    @ViewBuilder private var operationStatus: some View {
        if let message = model.operation.message {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thickMaterial, in: Capsule())
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct CompatibilityHelpView: View {
    @EnvironmentObject private var model: AppModel
    let help: CompatibilityHelp

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(spacing: 9) {
                Text(help.title)
                    .font(.title2.weight(.semibold))
                Text(help.message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }
            VStack(spacing: 10) {
                Button(help.recommendedTitle, action: model.useRecommendedAlternative)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if help.canTryAnyway {
                    Button("Try Windows Installer Anyway", action: model.tryCompatibilityFileAnyway)
                        .buttonStyle(.bordered)
                }
                if help.logURL != nil {
                    Button("Show Diagnostic Log", action: model.revealCompatibilityLog)
                        .buttonStyle(.link)
                }
            }
            Button("Close", action: model.dismissCompatibilityHelp)
                .keyboardShortcut(.cancelAction)
        }
        .padding(36)
        .frame(width: 560)
        .frame(minHeight: 410)
    }
}

private struct ApplicationCard: View {
    @EnvironmentObject private var model: AppModel
    let application: LibraryApplication

    var body: some View {
        Button {
            Task { await model.launch(application) }
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                ApplicationArtwork(application: application, image: model.applicationIcon(for: application))
                Spacer(minLength: 10)
                Text(application.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(lastOpenedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 155, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.operation != .idle)
        .contextMenu {
            Button("Run") { Task { await model.launch(application) } }
            Button(application.effectivePlatform == .android ? "Show APK in Finder" : "Open C: Drive") {
                model.revealFiles(for: application)
            }
            Divider()
            Button("Remove from Library", role: .destructive) { model.remove(application) }
        }
    }

    private var lastOpenedText: String {
        guard let date = application.lastLaunchedAt else {
            return application.effectivePlatform == .android ? "Android · Not opened yet" : "Windows · Not opened yet"
        }
        return "Opened \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct ApplicationArtwork: View {
    let application: LibraryApplication
    let image: NSImage?

    private var symbol: String {
        let name = application.name.lowercased()
        if name.contains("steam") { return "gamecontroller.fill" }
        if name.contains("ubisoft") { return "u.circle.fill" }
        if name.contains("epic") { return "bolt.fill" }
        if name.contains("battle") { return "sparkles" }
        if name.contains("trackmania") { return "flag.checkered" }
        if application.effectivePlatform == .android { return "app.badge.fill" }
        return "face.smiling.fill"
    }

    private var colors: [Color] {
        let palette: [[Color]] = [
            [.blue, .purple], [.orange, .pink], [.mint, .blue], [.indigo, .cyan], [.pink, .purple]
        ]
        let value = application.name.unicodeScalars.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1.value) }
        return palette[Int(value % UInt(palette.count))]
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: 68, height: 68)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
    }
}
