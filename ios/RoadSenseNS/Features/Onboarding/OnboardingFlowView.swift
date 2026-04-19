import SwiftUI

struct OnboardingFlowView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("RoadSense NS")
                .font(.largeTitle.bold())

            switch model.readiness.stage {
            case .permissionsRequired:
                permissionIntro
            case .permissionHelp:
                permissionHelp
            case .privacyZonesRequired:
                privacyZoneDecision
            case .ready:
                readyState
            }

            Spacer()
        }
        .padding(24)
    }

    private var permissionIntro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("We need Location and Motion access before collection can start.")
                .font(.title3.weight(.semibold))

            Text("RoadSense NS asks for When-In-Use Location first, then Motion & Fitness. Always Location comes later, after you have seen a successful drive and understand the tradeoff.")
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await model.requestInitialPermissions()
                }
            } label: {
                if model.isRequestingPermissions {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRequestingPermissions)
        }
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions are still incomplete.")
                .font(.title3.weight(.semibold))

            Text("Open Settings and enable Location and Motion access. Passive collection stays off until both are granted.")
                .foregroundStyle(.secondary)

            permissionStatusSummary

            Button("Refresh status") {
                model.refreshPermissions()
            }
            .buttonStyle(.bordered)
        }
    }

    private var privacyZoneDecision: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up privacy protection before collection starts.")
                .font(.title3.weight(.semibold))

            Text("RoadSense NS filters readings near home and work on-device. Configure at least one privacy zone, or explicitly accept the risk before you continue.")
                .foregroundStyle(.secondary)

            Button("I configured my privacy zones") {
                model.markPrivacyZonesConfigured()
            }
            .buttonStyle(.borderedProminent)

            Button("Skip for now and accept the risk") {
                model.skipPrivacyZonesForNow()
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
    }

    private var readyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RoadSense NS is ready to collect.")
                .font(.title3.weight(.semibold))

            if model.readiness.showsPrivacyRiskWarning {
                Text("Privacy zones are still skipped. Collection can start, but home/work exposure risk remains high until you configure them.")
                    .foregroundStyle(.orange)
            } else {
                Text("Permissions are in place and the privacy gate is satisfied.")
                    .foregroundStyle(.secondary)
            }

            permissionStatusSummary
        }
    }

    private var permissionStatusSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Location", value: model.snapshot.location.displayName)
            LabeledContent("Motion", value: model.snapshot.motion.displayName)
            LabeledContent("Background collection", value: model.readiness.backgroundCollection.displayName)
        }
        .font(.subheadline)
    }
}
