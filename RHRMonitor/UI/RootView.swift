import SwiftUI
import HeartRateKit

enum AppTab: Hashable {
    case live, resting, trends, history, settings
}

/// Tab shell. Also reports this scene's keep-awake needs and app lifecycle to the model.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(KeepAwakeController.self) private var keepAwake
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: AppTab = .live
    @State private var sceneID = UUID().uuidString

    /// Whether this scene should hold the screen awake right now.
    private var wantsAwake: Bool {
        KeepAwakeArbiter.sceneWantsAwake(userEnabled: model.settings.keepScreenAwake,
                                         monitoringActive: model.isMonitoring,
                                         sceneActive: scenePhase == .active,
                                         monitorVisible: tab == .live || tab == .resting)
    }

    var body: some View {
        TabView(selection: $tab) {
            LiveMonitorView(tab: $tab)
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }
                .tag(AppTab.live)
            RestingHRView()
                .tabItem { Label("Resting", systemImage: "figure.mind.and.body") }
                .tag(AppTab.resting)
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.trends)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onAppear { keepAwake.update(scene: sceneID, wantsAwake: wantsAwake) }
        .onDisappear { keepAwake.update(scene: sceneID, wantsAwake: false) }
        .onChange(of: wantsAwake) { _, newValue in
            keepAwake.update(scene: sceneID, wantsAwake: newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.appDidEnterBackground()
            case .active: model.appWillEnterForeground()
            default: break
            }
        }
    }
}
