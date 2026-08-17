import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack { ChatView(model: model) }
                .tabItem { Label("Chat", systemImage: AppModel.Tab.chat.symbol) }
                .tag(AppModel.Tab.chat)
            NavigationStack { WorkspaceView(model: model) }
                .tabItem { Label("Workspace", systemImage: AppModel.Tab.workspace.symbol) }
                .tag(AppModel.Tab.workspace)
            NavigationStack { ModelsView(model: model) }
                .tabItem { Label("Models", systemImage: AppModel.Tab.models.symbol) }
                .tag(AppModel.Tab.models)
            NavigationStack { ActivityView(model: model) }
                .tabItem { Label("Activity", systemImage: AppModel.Tab.activity.symbol) }
                .tag(AppModel.Tab.activity)
            NavigationStack { SettingsView(model: model) }
                .tabItem { Label("Settings", systemImage: AppModel.Tab.settings.symbol) }
                .tag(AppModel.Tab.settings)
        }
        .tint(.primary)
        .sheet(isPresented: $model.showTasks) { TodoView(model: model) }
        .sheet(isPresented: $model.showContext) { ContextInspectorView(model: model) }
        .sheet(isPresented: $model.showPerformance) { PerformanceView(model: model) }
        .sheet(isPresented: $model.showHistory) { SessionHistoryView(model: model) }
        .alert(
            "TriInfer",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}
