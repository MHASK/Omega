import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updater = GitHubUpdater.shared
    let scale: CGFloat
    var body: some View {
        SettingsCard("App updates", subtitle: "New versions from GitHub, delivered quietly.", scale: scale) {
            Toggle("Automatically check and download", isOn: $updater.automatic).toggleStyle(.switch).font(.system(size: 11 * scale))
            Text("You choose when to restart. Your notes, settings, and history are backed up before an update is installed.").font(.system(size: 10 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).fixedSize(horizontal: false, vertical: true)
        } footer: {
            HStack(spacing: 10 * scale) {
                if updater.busy { ProgressView().controlSize(.small).scaleEffect(0.8) }
                Text(updater.message).foregroundStyle(Color(nsColor: Ink.muted)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if updater.readyVersion != nil { Button("Restart to update") { updater.install() }.fixedSize() }
                else { Button("Check now") { updater.check() }.disabled(updater.busy).fixedSize() }
            }
        }
    }
}
