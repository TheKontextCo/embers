import AppKit
import SwiftUI
import EmbersPluginHost
import EmbersPluginKit

struct ConnectionControlPresentation: Equatable {
    let statusLabel: String?
    let actionTitle: String
    let isConnecting: Bool

    init(state: PluginConnectionState?) {
        isConnecting = state == .connecting
        switch state {
        case .connected:
            statusLabel = "Connected"
            actionTitle = "Connect"
        case .connecting:
            statusLabel = nil
            actionTitle = "Connecting…"
        case .expired:
            statusLabel = "Reconnect to sync"
            actionTitle = "Reconnect"
        case .failed:
            statusLabel = "Connection unavailable"
            actionTitle = "Reconnect"
        case .requiresAuthentication, .disconnected, nil:
            statusLabel = nil
            actionTitle = "Connect"
        }
    }
}

private struct AppleSwitchToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Color(nsColor: .systemGreen) : Color.white.opacity(0.16))
                .frame(width: 44, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .padding(2)
                        .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @ObservedObject var vm: DashboardViewModel
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var context: ContextIndexController
    @ObservedObject private var voiceRoutingStatus: VoiceRoutingStatus
    @State private var showsDiagnostics = false
    @State private var showsIgnoredContexts = false
    @State private var removesSource: PluginSourceDescriptor?
    @State private var disconnectsPlugin: PluginIdentifier?

    init(vm: DashboardViewModel) {
        self._vm = ObservedObject(wrappedValue: vm)
        self._context = ObservedObject(wrappedValue: vm.context)
        self._voiceRoutingStatus = ObservedObject(wrappedValue: vm.voiceRoutingStatus)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Style.hairline).frame(height: 1)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    generalSection
                    sourcesSection
                    listeningSection
                    advancedSection
                    aboutSection
                    privacyFooter
                }
            }
        }
        .frame(width: NotchMetrics.openSize.width, height: NotchMetrics.openSize.height)
        .background(Style.panelFill)
        .confirmationDialog(
            "Remove this source?",
            isPresented: Binding(
                get: { removesSource != nil },
                set: { if !$0 { removesSource = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let source = removesSource,
               let provider = providerDescriptor(for: source.id.pluginID) {
                Button(provider.presentation.removeActionTitle, role: .destructive) {
                    removesSource = nil
                    Task { await context.remove(source.id) }
                }
            }
            Button("Cancel", role: .cancel) { removesSource = nil }
        } message: {
            Text("Embers will erase its local cache and saved access for this source. Original provider content will not be deleted.")
        }
        .confirmationDialog(
            "Disconnect this source?",
            isPresented: Binding(
                get: { disconnectsPlugin != nil },
                set: { if !$0 { disconnectsPlugin = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pluginID = disconnectsPlugin,
               let provider = providerDescriptor(for: pluginID) {
                Button(provider.presentation.removeActionTitle, role: .destructive) {
                    disconnectsPlugin = nil
                    Task { await context.disconnect(pluginID) }
                }
            }
            Button("Cancel", role: .cancel) { disconnectsPlugin = nil }
        } message: {
            Text("Embers will remove the local cache and connection for this provider.")
        }
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.fill").foregroundStyle(Style.ember2)
            Text(L10n.string("settings.title")).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            Spacer()
            Button { vm.toggleSettings() } label: {
                Image(systemName: "xmark").foregroundStyle(Style.inkDim).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Close Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var generalSection: some View {
        section(L10n.string("settings.general")) {
            card {
                preferenceRow(L10n.string("settings.launchAtLogin"), L10n.string("settings.launchAtLoginDetail")) {
                    VStack(alignment: .trailing, spacing: 5) {
                        toggle(Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        ))
                        if settings.launchAtLoginStatus.shouldOfferLoginItemsSettings {
                            Text(settings.launchAtLoginStatus.message)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Style.inkDim)
                            Button("Open Login Items Settings…") { settings.openLoginItemsSettings() }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Style.ember2)
                        }
                    }
                }
                if displayPlacements.count > 1 || !settings.displayIdentifier.isEmpty {
                    preferenceRow("Display", "Where the notch appears") {
                        Picker("", selection: $settings.displayIdentifier) {
                            Text("Automatic").tag("")
                            if !settings.displayIdentifier.isEmpty,
                               !displayPlacements.contains(where: { $0.persistentIdentifier == settings.displayIdentifier }) {
                                Text("Saved display unavailable").tag(settings.displayIdentifier)
                            }
                            ForEach(displayPlacements) { display in
                                Text(DisplayPlacementPolicy.displayLabel(for: display, among: displayPlacements))
                                    .tag(display.persistentIdentifier)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }
            }
        }
    }

    private var displayPlacements: [DisplayPlacement] {
        NSScreen.embersDisplayPlacements.map(\.placement)
    }

    private var sourcesSection: some View {
        section("SOURCES") {
            VStack(spacing: 8) {
                providerCards
                if showsDiagnostics && !context.diagnostics.isEmpty {
                    card {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(context.diagnostics.prefix(5)) { diagnostic in
                                Label(
                                    diagnostic.message,
                                    systemImage: diagnostic.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill"
                                )
                                .font(.system(size: 9.5))
                                .foregroundStyle(diagnostic.severity == .error ? .red : Style.inkDim)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var providerCards: some View {
        ForEach(context.providerDescriptors, id: \.id) { plugin in
            let status = context.connectionStatuses[plugin.id]
            let connection = ConnectionControlPresentation(state: status?.state)
            let sources = context.contextSources.filter { $0.descriptor.id.pluginID == plugin.id }
            if sources.isEmpty {
                if plugin.capabilities.contains(.connection) || plugin.sourceSetup != .none {
                    providerCard(
                        systemImage: plugin.presentation.systemImage,
                        title: plugin.displayName,
                        subtitle: status?.detail ?? plugin.presentation.sourceDescription,
                        status: connection.statusLabel,
                        isWorking: false
                    ) {
                        if plugin.capabilities.contains(.connection) {
                            connectionAction(connection) { Task { await context.connect(plugin.id) } }
                        } else {
                            action(plugin.presentation.setupActionTitle) { vm.configureSource(plugin) }
                        }
                    }
                }
            } else {
                ForEach(sources, id: \.descriptor.id) { source in
                    providerCard(
                        systemImage: plugin.presentation.systemImage,
                        title: source.descriptor.displayName,
                        subtitle: sourceDetail(
                            source,
                            fallback: source.descriptor.detail ?? plugin.presentation.sourceDescription
                        ),
                        status: sourceLabel(source),
                        isWorking: source.health == .refreshing
                    ) {
                        if case .stale = source.health {
                            action("Retry") { Task { await context.refresh(source.descriptor.id) } }
                        }
                        if plugin.sourceSetup != .none {
                            action(plugin.presentation.changeActionTitle) { vm.configureSource(plugin) }
                        }
                        Menu {
                            Button("Open Context Lens") {
                                vm.openContextLens(source.descriptor.id)
                            }
                            .disabled(!vm.canOpenContextLens(source.descriptor.id))
                            Divider()
                            Button("Refresh") { Task { await context.refresh(source.descriptor.id) } }
                            if !context.diagnostics.isEmpty {
                                Button(showsDiagnostics ? "Hide Indexing Issues" : "View \(context.diagnostics.count) Indexing Issues") {
                                    showsDiagnostics.toggle()
                                }
                            }
                            if plugin.capabilities.contains(.connection) {
                                Divider()
                                Button(plugin.presentation.removeActionTitle, role: .destructive) { disconnectsPlugin = plugin.id }
                            } else if plugin.sourceSetup != .none {
                                Divider()
                                Button(plugin.presentation.removeActionTitle, role: .destructive) { removesSource = source.descriptor }
                            }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Style.inkMut).frame(width: 28, height: 24)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
    }

    private var listeningSection: some View {
        section(L10n.string("settings.listening")) {
            card {
                preferenceRow("Listen on launch", "Starts after indexing only when access is already granted") { toggle($settings.listenOnLaunch) }
                if voiceRoutingStatus.state.shouldPresentInSettings {
                    preferenceRow("Voice vocabulary", voiceRoutingStatus.state.detail) {
                        HStack(spacing: 7) {
                            if voiceRoutingStatus.state.isWorking { ProgressView().controlSize(.small) }
                            Text(voiceRoutingStatus.state.label)
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(voiceRoutingStatus.state.isFallback ? Style.ember2 : Style.inkDim)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var advancedSection: some View {
        if !context.ignoredAnchorIDs.isEmpty {
            section("HIDDEN CONTEXTS") {
                card {
                    DisclosureGroup("Hidden contexts (\(context.ignoredAnchorIDs.count))", isExpanded: $showsIgnoredContexts) {
                        VStack(spacing: 4) {
                            ForEach(context.ignoredAnchorIDs.sorted(), id: \.self) { id in
                                let name = context.snapshot?.anchors.first(where: { $0.id == id })?.canonicalName ?? id
                                preferenceRow(name, nil) { action("Restore") { vm.restore(id) } }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).tint(Style.inkMut)
                }
            }
        }
    }

    private var aboutSection: some View {
        section(L10n.string("about.title").uppercased()) {
            card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill").foregroundStyle(Style.ember2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Embers").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                            Text(L10n.string("about.version", ReleaseInformation.version(), ReleaseInformation.build()))
                                .font(.system(size: 9.5)).foregroundStyle(Style.inkDim)
                        }
                    }
                    Text(L10n.string("about.localFirst"))
                        .font(.system(size: 9.5)).foregroundStyle(Style.inkDim)
                    HStack(spacing: 14) {
                        action(L10n.string("about.openProject")) { ReleaseInformation.open(ReleaseInformation.projectURL) }
                        action(L10n.string("about.reportIssue")) { ReleaseInformation.open(ReleaseInformation.issueURL) }
                        action(L10n.string("about.security")) { ReleaseInformation.open(ReleaseInformation.securityURL) }
                    }
                }
            }
        }
    }

    private var privacyFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Style.green2)
            Text(L10n.string("settings.privacy"))
                .font(.system(size: 9.5)).foregroundStyle(Style.inkDim).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1.5).foregroundStyle(Style.inkDim)
            content()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Style.hairline).frame(height: 1) }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.cardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Style.hairline))
    }

    private func preferenceRow<Control: View>(_ title: String, _ description: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5)).foregroundStyle(.white)
                if let description {
                    Text(description).font(.system(size: 9.5)).foregroundStyle(Style.inkDim).lineLimit(2)
                }
            }
            Spacer()
            control().font(.system(size: 11))
        }
        .padding(.vertical, 5)
    }

    private func toggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding)
            .labelsHidden()
            .toggleStyle(AppleSwitchToggleStyle())
    }

    private func action(_ title: String, _ perform: @escaping () -> Void) -> some View {
        Button(title, action: perform).buttonStyle(.plain).foregroundStyle(Style.ember2)
    }

    private func providerCard<Controls: View>(
        systemImage: String,
        title: String,
        subtitle: String?,
        status: String?,
        isWorking: Bool,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        card {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Style.ember2)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 9.5)).foregroundStyle(Style.inkDim).lineLimit(1)
                    }
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                if let status {
                    Text(status.uppercased()).font(.system(size: 8, weight: .heavy)).foregroundStyle(Style.inkMut)
                }
                controls()
            }
        }
    }

    private func connectionAction(_ presentation: ConnectionControlPresentation, _ perform: @escaping () -> Void) -> some View {
        return Button(action: perform) {
            HStack(spacing: 6) {
                if presentation.isConnecting { ProgressView().controlSize(.mini) }
                Text(presentation.actionTitle)
            }
            .frame(minWidth: 96, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(presentation.isConnecting ? Style.inkMut : Style.ember2)
        .disabled(presentation.isConnecting)
    }

    private func sourceLabel(_ source: HostedPluginSource?) -> String {
        switch source?.health {
        case .idle: return "Waiting"
        case .refreshing: return "Refreshing…"
        case .ready: return "Ready"
        case .stale: return "Cached — unavailable"
        case nil: return "Loading…"
        }
    }

    private func sourceDetail(_ source: HostedPluginSource, fallback: String) -> String {
        if case let .stale(message) = source.health { return message }
        return fallback
    }

    private func providerDescriptor(for id: PluginIdentifier) -> PluginDescriptor? {
        context.providerDescriptors.first { $0.id == id }
    }
}
