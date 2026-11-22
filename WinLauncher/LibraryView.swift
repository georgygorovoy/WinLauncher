import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false
    @State private var showingAddPopover = false
    @State private var selectedTab: HomeTab = .store

    private enum HomeTab: Hashable {
        case store, android, profile

        var title: String {
            switch self {
            case .store: String(localized: "Store")
            case .android: "Android"
            case .profile: String(localized: "Profile")
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 18)]

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                storePage
                    .tabItem { Label("Store", systemImage: "bag") }
                    .tag(HomeTab.store)
                androidPage
                    .tabItem { Label("Android", systemImage: "app.badge") }
                    .tag(HomeTab.android)
                profilePage
                    .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                    .tag(HomeTab.profile)
            }
            .navigationTitle(selectedTab.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddPopover.toggle() } label: {
                        Label("Add App", systemImage: "plus")
                    }
                    .disabled(model.operation != .idle)
                    .popover(isPresented: $showingAddPopover, arrowEdge: .bottom) {
                        VStack(spacing: 14) {
                            Text("Add an app").font(.headline)
                            dropArea.frame(width: 310, height: 150)
                            Button("Choose .exe, .msi, or .apk…") {
                                showingAddPopover = false
                                model.chooseApplicationFile()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(20)
                    }
                }
            }
            .overlay(alignment: .bottom) { operationStatus }
        }
        .sheet(isPresented: $model.showingEngineSetup) {
            EngineSetupView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingAndroidSetup) {
            AndroidSetupView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingXboxSetup) {
            XboxSetupView()
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

    private var storePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Get started").font(.title2.weight(.semibold))
                        TechnologyGuideButton()
                    }
                    Text("Useful apps and game launchers")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(FeaturedApplication.allCases.filter { $0 != .fdroid }) { featured in
                        FeaturedApplicationCard(application: featured)
                            .environmentObject(model)
                    }
                }
                StoreDiscoveryView()
            }
            .padding(28)
        }
    }

    private var androidPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Text("Android apps").font(.title2.weight(.semibold))
                    TechnologyGuideButton()
                }
                Text("F-Droid is an open-source app store inside WinLauncher's Android emulator. Google Play is not included.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 18) {
                    FeaturedApplicationCard(application: .fdroid).environmentObject(model)
                }
                let androidApps = model.applications.filter { $0.effectivePlatform == .android && $0.packageIdentifier != "org.fdroid.fdroid" }
                if !androidApps.isEmpty {
                    Text("Your Android apps").font(.title2.weight(.semibold))
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(androidApps) { application in
                            ApplicationCard(application: application).environmentObject(model)
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var profilePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your profile").font(.title2.weight(.semibold))
                    Text("Apps known to WinLauncher and launches made through it")
                        .foregroundStyle(.secondary)
                }
                let recentApps = model.applications.filter { $0.lastLaunchedAt != nil }
                    .sorted { ($0.lastLaunchedAt ?? .distantPast) > ($1.lastLaunchedAt ?? .distantPast) }
                let recentGames = model.steamGames.filter { model.steamGameLaunchHistory[$0.id] != nil }
                    .sorted { (model.steamGameLaunchHistory[$0.id] ?? .distantPast) >
                              (model.steamGameLaunchHistory[$1.id] ?? .distantPast) }
                if !recentApps.isEmpty || !recentGames.isEmpty {
                    Text("Recently played and opened").font(.headline)
                    ForEach(recentGames.prefix(5)) { game in
                        Button {
                            Task { await model.launchSteamGame(game) }
                        } label: {
                            Label("\(game.name) · Steam", systemImage: "gamecontroller")
                        }
                        .buttonStyle(.link)
                    }
                    ForEach(recentApps.prefix(5)) { application in
                        Button {
                            Task { await model.launch(application) }
                        } label: {
                            Label("\(application.name) · \(application.lastLaunchedAt?.formatted(.relative(presentation: .named)) ?? "")",
                                  systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.link)
                    }
                }
                let installedLaunchers = FeaturedApplication.allCases.filter { featured in
                    switch featured {
                    case .steam: model.nativeSteamInstalled
                    case .ubisoft: model.installedUbisoftConnect != nil
                    case .epic: model.nativeEpicInstalled || model.installedEpicWindowsLauncher != nil
                    case .fdroid: model.installedFDroid != nil
                    case .minecraft: model.xboxGamePrepared
                    case .gog: false
                    }
                }
                if !installedLaunchers.isEmpty {
                    Text("Installed launchers and stores").font(.title2.weight(.semibold))
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(installedLaunchers) { featured in
                            FeaturedApplicationCard(application: featured).environmentObject(model)
                        }
                    }
                }
                if !model.steamGames.isEmpty {
                    HStack(spacing: 8) {
                        Text("Steam Windows games").font(.title2.weight(.semibold))
                        SteamGuideButton()
                    }
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.steamGames) { game in
                            SteamGameCard(game: game).environmentObject(model)
                        }
                    }
                }
                if !model.applications.isEmpty {
                    Text("Installed apps").font(.title2.weight(.semibold))
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.applications) { application in
                            ApplicationCard(application: application)
                                .environmentObject(model)
                        }
                    }
                }
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
            let accepted = urls.contains { ["exe", "msi", "apk"].contains($0.pathExtension.lowercased()) }
            if accepted { showingAddPopover = false }
            return accepted
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

private struct SteamGameCard: View {
    @EnvironmentObject private var model: AppModel
    let game: SteamWindowsGame

    var body: some View {
        Button {
            Task { await model.launchSteamGame(game) }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if let artwork = game.artwork, let image = NSImage(contentsOf: artwork) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image("Steam").resizable().scaledToFit()
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                Spacer(minLength: 4)
                Text(game.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text("Windows game · Play with WinLauncher")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(model.operation != .idle)
        .contextMenu {
            Button("Show Game Files") {
                NSWorkspace.shared.activateFileViewerSelecting([game.executable])
            }
        }
    }
}

private enum FeaturedApplication: String, CaseIterable, Identifiable {
    case steam, minecraft, ubisoft, epic, gog, fdroid

    var id: Self { self }
    var title: String {
        switch self {
        case .steam: "Steam"
        case .minecraft: "Minecraft Bedrock"
        case .ubisoft: "Ubisoft Connect"
        case .epic: "Epic Games Store"
        case .gog: "GOG GALAXY"
        case .fdroid: "F-Droid"
        }
    }
    var detail: String {
        switch self {
        case .steam: String(localized: "Mac app · Official download")
        case .minecraft: String(localized: "Windows game · Set up and play")
        case .ubisoft: String(localized: "Windows launcher · Official download")
        case .epic: String(localized: "Mac app · Official download")
        case .gog: String(localized: "Mac app · Official download")
        case .fdroid: String(localized: "Android app store · Install in WinLauncher")
        }
    }
    var asset: String {
        switch self {
        case .steam: "Steam"
        case .minecraft: "Minecraft"
        case .ubisoft: "Ubisoft"
        case .epic: "Epic"
        case .gog: "GOG"
        case .fdroid: "FDroid"
        }
    }
}

private struct FeaturedApplicationCard: View {
    @EnvironmentObject private var model: AppModel
    let application: FeaturedApplication

    var body: some View {
        Button {
            switch application {
            case .steam: model.openNativeSteam()
            case .minecraft: model.showXboxSetup()
            case .ubisoft:
                if let installed = model.installedUbisoftConnect {
                    Task { await model.launch(installed) }
                } else {
                    model.openFeaturedURL("https://www.ubisoft.com/en-us/ubisoft-connect/download")
                }
            case .epic: model.openEpicGames()
            case .gog: model.openFeaturedURL("https://www.gog.com/galaxy")
            case .fdroid: model.openFDroid()
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(application.asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                Spacer(minLength: 4)
                Text(application.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(L10n.text(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if application == .steam && model.steamPlayNeedsAttention {
                    Text(model.steamPlayBridgeStatus)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                } else if application == .steam && model.steamPlayReady {
                    Text("Windows games ready to play")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(model.operation != .idle)
        .overlay(alignment: .topTrailing) {
            if application == .steam {
                HStack(spacing: 6) {
                    if model.steamPlayNeedsAttention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .help(model.steamPlayBridgeStatus)
                            .accessibilityLabel(model.steamPlayBridgeStatus)
                    } else if model.steamPlayReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help(model.steamPlayBridgeStatus)
                            .accessibilityLabel(model.steamPlayBridgeStatus)
                    }
                    SteamGuideButton()
                }
                .padding(14)
            }
        }
    }

    private var detail: String {
        switch application {
        case .steam where model.nativeSteamInstalled:
            return model.steamWindowsModeState == .enabled || model.steamWindowsModeState == .enabledOutsideWinLauncher
                ? String(localized: "Installed · Windows downloads on") : String(localized: "Installed · Open Steam")
        case .ubisoft where model.installedUbisoftConnect != nil:
            return String(localized: "Installed · Open Ubisoft Connect")
        case .epic where model.nativeEpicInstalled:
            return String(localized: "Installed · Open Mac app")
        case .epic where model.installedEpicWindowsLauncher != nil:
            return String(localized: "Installed · Open Windows app")
        case .fdroid where model.installedFDroid != nil:
            return String(localized: "Installed · Open Android store")
        default:
            return application.detail
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
            Button(fileMenuTitle) {
                model.revealFiles(for: application)
            }
            Divider()
            Button("Remove from Library", role: .destructive) { model.remove(application) }
        }
    }

    private var lastOpenedText: String {
        guard let date = application.lastLaunchedAt else {
            return application.effectivePlatform == .android
                ? String(localized: "Android · Not opened yet") : String(localized: "Windows · Not opened yet")
        }
        return String(localized: "Opened \(date.formatted(.relative(presentation: .named)))")
    }

    private var fileMenuTitle: String {
        if application.packageIdentifier == "org.minecraft.windows.gdk" { return String(localized: "Show Game Files") }
        if application.effectivePlatform == .android { return String(localized: "Show APK in Finder") }
        return String(localized: "Open C: Drive")
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
        if name.contains("minecraft") { return "cube.fill" }
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

private struct StoreDiscoveryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var games: [CatalogGame] = []
    @State private var unavailableStores = Set<CatalogStore>()
    @State private var loading = false
    @State private var reloadToken = 0
    @State private var selectedStore: StoreFilter = .all
    @State private var displayMode: DisplayMode = .alphabetical

    private enum StoreFilter: String, CaseIterable, Identifiable {
        case all = "All", steam = "Steam", gog = "GOG", epic = "Epic", ubisoft = "Ubisoft"
        var id: Self { self }
    }

    private enum DisplayMode: String, CaseIterable, Identifiable {
        case alphabetical = "A–Z"
        case free = "Free"
        case cheap = "Low price (paid)"
        case expensive = "High price"
        case popular = "Popular"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Games from stores").font(.title2.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh store results")
                    .buttonStyle(.borderless)
            }
            Text("Browse Steam and GOG together. Epic and Ubisoft open their official stores for search and installation.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("Search games", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search games in stores")
                Picker("Store", selection: $selectedStore) {
                    ForEach(StoreFilter.allCases) { store in Text(L10n.text(store.rawValue)).tag(store) }
                }
                .frame(width: 145)
                Picker("Show", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in Text(L10n.text(mode.rawValue)).tag(mode) }
                }
                .frame(width: 175)
            }
            if displayMode == .cheap || displayMode == .expensive {
                Text("Prices are sorted by the numbers shown by each store; currencies are not converted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if displayMode == .popular {
                Text("Popular follows Steam bestsellers and each store's result order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (selectedStore == .all || selectedStore == .steam),
               displayMode == .alphabetical {
                let freePicks = games.filter { $0.store == .steam && $0.priceAmount == 0 }
                if !freePicks.isEmpty {
                    Label("Free picks on Steam", systemImage: "gift.fill")
                        .font(.headline)
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(freePicks.prefix(6)) { game in
                                Button(game.name) { openGame(game) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }

            if selectedStore == .all || selectedStore == .epic || selectedStore == .ubisoft {
                HStack(spacing: 12) {
                    if selectedStore == .all || selectedStore == .epic {
                        Button("Search Epic Games Store ↗") { openEpicSearch() }
                    }
                    if selectedStore == .all || selectedStore == .ubisoft {
                        Button("Open Ubisoft Store ↗") {
                            NSWorkspace.shared.open(URL(string: "https://store.ubisoft.com/")!)
                        }
                    }
                }
                .buttonStyle(.link)
            }

            if !unavailableStores.isEmpty {
                Text("Could not refresh \(unavailableStores.map(\.rawValue).sorted().joined(separator: " and ")). Try again later.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if selectedStore == .epic || selectedStore == .ubisoft {
                Text("This store does not provide a supported public game catalog to WinLauncher. Search and install on its official site.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if visibleGames.isEmpty && !loading && unavailableStores.isEmpty {
                ContentUnavailableView("No games in these results", systemImage: "magnifyingglass",
                                       description: Text("Try another name, filter or store."))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(visibleGames) { game in
                        HStack(spacing: 13) {
                            AsyncImage(url: game.imageURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "gamecontroller.fill")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(.quaternary)
                            }
                            .frame(width: 96, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name).font(.headline).lineLimit(1)
                                Text("\(game.store.rawValue) · \(L10n.text(game.platforms))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let price = game.price {
                                    Text(L10n.text(price)).font(.caption)
                                }
                            }
                            Spacer(minLength: 8)
                            Button(canInstallInSteam(game) ? "Install in Steam" : "Get game ↗") {
                                openGame(game)
                            }
                            .help(canInstallInSteam(game)
                                  ? "Ask Steam to install this game. Steam handles ownership and download."
                                  : "Open the official store page to buy or install this game")
                        }
                        .padding(11)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                    }
                }
            }
        }
        .task(id: "\(searchText):\(reloadToken)") {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            loading = true
            let result = await StoreCatalog.games(matching: query)
            guard !Task.isCancelled else { return }
            games = result.games
            unavailableStores = result.unavailableStores
            loading = false
        }
    }

    private var visibleGames: [CatalogGame] {
        let filtered = games.filter { game in
            switch selectedStore {
            case .all: true
            case .steam: game.store == .steam
            case .gog: game.store == .gog
            case .epic, .ubisoft: false
            }
        }
        switch displayMode {
        case .alphabetical:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .free:
            return filtered.filter { $0.priceAmount == 0 }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .cheap:
            return filtered.filter { ($0.priceAmount ?? 0) > 0 }
                .sorted { ($0.priceAmount ?? .infinity) < ($1.priceAmount ?? .infinity) }
        case .expensive:
            return filtered.filter { ($0.priceAmount ?? 0) > 0 }
                .sorted { ($0.priceAmount ?? 0) > ($1.priceAmount ?? 0) }
        case .popular:
            return filtered.sorted {
                if $0.popularityRank != $1.popularityRank { return $0.popularityRank < $1.popularityRank }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private func openEpicSearch() {
        var components = URLComponents(string: "https://store.epicgames.com/browse")!
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { components.queryItems = [URLQueryItem(name: "q", value: query)] }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func canInstallInSteam(_ game: CatalogGame) -> Bool {
        guard game.store == .steam, game.steamAppID != nil, model.nativeSteamInstalled else { return false }
        if game.supportsMac { return true }
        return game.supportsWindows &&
            (model.steamWindowsModeState == .enabled || model.steamWindowsModeState == .enabledOutsideWinLauncher)
    }

    private func openGame(_ game: CatalogGame) {
        if canInstallInSteam(game), let id = game.steamAppID,
           let installURL = URL(string: "steam://install/\(id)"),
           NSWorkspace.shared.open(installURL) { return }
        NSWorkspace.shared.open(game.productURL)
    }
}
