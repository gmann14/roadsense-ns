import AVFoundation
import SwiftUI
import UIKit

struct PotholeCameraFlowView: View {
    let coordinateLabel: String
    let isLikelyMoving: Bool
    let onCancel: () -> Void
    let onSubmit: (Data) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraCaptureModel()
    @State private var capturedData: Data?
    @State private var safetyBannerDismissed: Bool = false

    init(
        coordinateLabel: String,
        isLikelyMoving: Bool = false,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (Data) -> Void
    ) {
        self.coordinateLabel = coordinateLabel
        self.isLikelyMoving = isLikelyMoving
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.authorizationState {
            case .notDetermined, .authorized:
                if let setupErrorMessage = camera.setupErrorMessage {
                    unavailableBody(message: setupErrorMessage)
                } else {
                    cameraBody
                }
            case .denied, .restricted:
                deniedBody
            @unknown default:
                unavailableBody(message: "RoadSense received an unknown camera permission state. Close this screen and try again.")
            }
        }
        .task {
            await camera.startIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await camera.refreshAuthorizationState()
            }
        }
        .onDisappear {
            camera.stop()
        }
    }

    @ViewBuilder
    private var cameraBody: some View {
        if let capturedData, let image = UIImage(data: capturedData) {
            VStack(spacing: DesignTokens.Space.lg) {
                Spacer(minLength: 0)

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
                    .padding(.horizontal, DesignTokens.Space.lg)

                VStack(spacing: DesignTokens.Space.xs) {
                    Text("Review photo")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text(coordinateLabel)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: DesignTokens.Space.md) {
                    Button("Retake") {
                        self.capturedData = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button("Submit") {
                        onSubmit(capturedData)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Palette.signal)
                }

                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.78))

                Spacer(minLength: DesignTokens.Space.lg)
            }
        } else {
            VStack(spacing: 0) {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .topLeading) {
                        Button(action: onCancel) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(DesignTokens.Space.lg)
                        }
                        .accessibilityLabel("Close camera")
                    }
                    .overlay(alignment: .top) {
                        if isLikelyMoving && !safetyBannerDismissed {
                            safetyBanner
                                .padding(.top, DesignTokens.Space.xxxl)
                                .padding(.horizontal, DesignTokens.Space.lg)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        VStack(spacing: DesignTokens.Space.md) {
                            Text(BrandVoice.Camera.captureGuidance)
                                .font(.system(.callout, weight: .medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, DesignTokens.Space.lg)

                            Button {
                                camera.capturePhoto { data in
                                    capturedData = data
                                }
                            } label: {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 78, height: 78)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.black.opacity(0.18), lineWidth: 2)
                                            .padding(6)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("camera.shutter")
                            .accessibilityLabel("Take pothole photo")
                            .accessibilityHint("Captures a photo for the pothole report.")
                            .padding(.bottom, DesignTokens.Space.xl)
                        }
                    }
            }
        }
    }

    /// Soft, dismissable warning shown over the camera preview when the device's
    /// reported speed suggests the user might be driving. Capture stays available;
    /// this is a nudge, not a block. Per §13.4 of the design audit.
    private var safetyBanner: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
            Image(systemName: "car.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Text(BrandVoice.Camera.safetyWarningWhileMoving)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignTokens.Space.xs)

            Button {
                withAnimation(DesignTokens.Motion.standard) {
                    safetyBannerDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(6)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss warning")
        }
        .padding(.horizontal, DesignTokens.Space.md)
        .padding(.vertical, DesignTokens.Space.sm)
        .background(
            Capsule().fill(DesignTokens.Palette.warning)
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 12, y: 4)
    }

    private var deniedBody: some View {
        VStack(spacing: DesignTokens.Space.lg) {
            Image(systemName: "camera.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white)

            Text("Camera access is off")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text("Allow camera access in Settings to submit pothole photos.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Button("Open Settings") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settingsURL)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Palette.signal)

            Button("Close", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.76))
        }
        .padding(DesignTokens.Space.xl)
    }

    private func unavailableBody(message: String) -> some View {
        VStack(spacing: DesignTokens.Space.lg) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white)

            Text("Camera unavailable")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.body)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button("Close", action: onCancel)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Palette.signal)
        }
        .padding(DesignTokens.Space.xl)
    }
}

private final class CameraCaptureModel: NSObject, ObservableObject {
    @Published var authorizationState: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var setupErrorMessage: String?

    let session = AVCaptureSession()

    private let output = AVCapturePhotoOutput()
    private var continuation: ((Data) -> Void)?

    @MainActor
    func startIfNeeded() async {
        if authorizationState == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
            authorizationState = granted ? .authorized : .denied
        }

        await refreshAuthorizationState()
    }

    @MainActor
    func refreshAuthorizationState() async {
        authorizationState = AVCaptureDevice.authorizationStatus(for: .video)

        guard authorizationState == .authorized else {
            stop()
            return
        }

        guard !session.isRunning else { return }

        guard configureSessionIfNeeded() else { return }
        session.startRunning()
    }

    @MainActor
    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func capturePhoto(onCapture: @escaping (Data) -> Void) {
        guard session.isRunning else {
            setupErrorMessage = "RoadSense could not start the camera. Close this screen and try again after checking iOS camera permissions."
            return
        }

        continuation = onCapture
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = .off
        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = output.maxPhotoDimensions
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    private func configureSessionIfNeeded() -> Bool {
        guard session.inputs.isEmpty else {
            return true
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            setupErrorMessage = "This device does not have an available back camera."
            return false
        }

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output) else {
            setupErrorMessage = "RoadSense could not configure the camera. Close this screen and try again."
            return false
        }

        session.addInput(input)
        session.addOutput(output)
        if #available(iOS 16.0, *) {
            if let maxDimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: { lhs, rhs in
                lhs.width * lhs.height < rhs.width * rhs.height
            }) {
                output.maxPhotoDimensions = maxDimensions
            }
        }
        setupErrorMessage = nil
        return true
    }
}

extension CameraCaptureModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation() else {
            return
        }

        DispatchQueue.main.async { [continuation] in
            continuation?(data)
        }
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewHostingView {
        let view = PreviewHostingView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewHostingView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class PreviewHostingView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
