import SwiftUI

@main
struct OMTReceiverApp: App {
    @StateObject private var receiver = ReceiverSession(applicationResources: ReceiverApplicationResources())
    @StateObject private var discovery = OMTDiscovery()
    @Environment(\.scenePhase) private var scenePhase
    private var isUnitTest: Bool {
        if let explicit = ProcessInfo.processInfo.environment["OMT_UNIT_TESTS"] { return explicit == "1" }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            ReceiverRootView(receiver: receiver, discovery: discovery)
                .preferredColorScheme(.dark)
                .onAppear { if !isUnitTest { discovery.start() } }
                .task { if !isUnitTest { receiver.startBenchmarkIfRequested() } }
                .onChange(of: scenePhase) { _, phase in
                    guard !isUnitTest else { return }
                    switch phase {
                    case .active: discovery.start(); receiver.resume()
                    case .background: discovery.stop(); receiver.suspend()
                    default: break
                    }
                }
        }
    }
}
