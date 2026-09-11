import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let settings: AppSettings
    let workspace: WorkspaceStore
    let agent: AgentController

    @Published var showingSettings = false
    @Published var showingFolderImporter = false

    init(settings: AppSettings, workspace: WorkspaceStore, agent: AgentController) {
        self.settings = settings
        self.workspace = workspace
        self.agent = agent
    }
}
