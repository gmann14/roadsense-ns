import SwiftUI

struct ContentView: View {
    let config: AppConfig

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("RoadSense NS")
                    .font(.largeTitle.bold())

                Text("Bootstrap shell")
                    .font(.headline)

                LabeledContent("Environment", value: config.environment.displayName)
                LabeledContent("API Base", value: config.apiBaseURL.absoluteString)
                LabeledContent("Functions Base", value: config.functionsBaseURL.absoluteString)

                Spacer()
            }
            .padding(24)
            .navigationTitle("RoadSense NS")
        }
    }
}

#Preview {
    ContentView(
        config: AppConfig(
            environment: .local,
            apiBaseURL: URL(string: "http://127.0.0.1:54321")!,
            mapboxAccessToken: "pk.preview"
        )
    )
}
