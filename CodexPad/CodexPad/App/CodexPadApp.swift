import SwiftUI

@main
@MainActor
struct CodexPadApp: App {
    @StateObject private var appState: AppState
    @StateObject private var settings: AppSettings
    @StateObject private var workspace: WorkspaceStore
    @StateObject private var agent: AgentController

    init() {
        let settings = AppSettings()
        let workspace = WorkspaceStore()
        let agent = AgentController(workspace: workspace, settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _workspace = StateObject(wrappedValue: workspace)
        _agent = StateObject(wrappedValue: agent)
        _appState = StateObject(wrappedValue: AppState(settings: settings, workspace: workspace, agent: agent))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(workspace)
                .environmentObject(agent)
        }
    }
}
