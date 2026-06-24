// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OXRSys visionOS")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text(appModel.statusText)
                .foregroundStyle(.secondary)

            if appModel.connectionState == .streaming {
                // Server already found and streaming: offer to (re-)enter the immersive view
                // and to fully disconnect.
                HStack(spacing: 12) {
                    Button("Enter Immersive View") {
                        appModel.enterImmersiveSpace()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.immersiveSpaceState != .closed)

                    Button("Disconnect", role: .destructive) {
                        appModel.disconnect()
                    }
                }
            } else {
                Button("Search") {
                    appModel.startDiscovery()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.connectionState != .disconnected)
            }
        }
        .padding(28)
        .frame(width: 360, height: 180)
        .task {
            await synchronizePresentationState()
        }
        .onChange(of: appModel.connectionState) { _, _ in
            Task {
                await synchronizePresentationState()
            }
        }
        .onChange(of: appModel.wantsImmersiveSpace) { _, _ in
            Task {
                await synchronizePresentationState()
            }
        }
    }

    /// Drives the immersive space from the user's intent (`wantsImmersiveSpace`) rather than the
    /// raw connection state, so exiting via the Digital Crown returns to this menu instead of
    /// auto re-entering. The control window is intentionally left open: `.full` immersion hides
    /// it while immersed, and keeping it alive makes it reappear automatically on exit.
    private func synchronizePresentationState() async {
        let shouldBeImmersed = appModel.connectionState == .streaming && appModel.wantsImmersiveSpace

        if shouldBeImmersed {
            guard appModel.immersiveSpaceState == .closed else { return }
            appModel.immersiveSpaceState = .inTransition
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                appModel.immersiveSpaceDidOpen()
            case .userCancelled, .error:
                appModel.immersiveSpaceState = .closed
            @unknown default:
                appModel.immersiveSpaceState = .closed
            }
        } else {
            guard appModel.immersiveSpaceState == .open else { return }
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
