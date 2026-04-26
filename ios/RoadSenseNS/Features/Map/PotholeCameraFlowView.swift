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
                cameraBody
            case .denied, .restricted:
                deniedBody
            }
        }
        .task {
            await camera.startIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
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
            ZStack {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()

                VStack {
                    HStack {
                        Button(action: onCancel) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(DesignTokens.Space.lg)
                        }
                        .accessibilityLabel("Close camera")

                        Spacer()
                    }

                    Spacer()
                }

                if isLikelyMoving && !safetyBannerDismissed && camera.startupState == .running {
                    VStack {
                        safetyBanner
                            .padding(.top, DesignTokens.Space.xxxl)
                            .padding(.horizontal, DesignTokens.Space.lg)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                }

                switch camera.startupState {
                case .idle, .starting:
                    cameraLoadingBody
                case .running:
                    cameraControls
                case let .failed(message):
                    cameraFailureBody(message)
                }
            }
        }
    }

    private var cameraLoadingBody: some View {
        VStack(spacing: DesignTokens.Space.md) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.15)
            Text("Starting camera…")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Text("If iOS shows a camera prompt, allow access to continue.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(DesignTokens.Space.xl)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var cameraControls: some View {
        VStack(spacing: DesignTokens.Space.md) {
            Spacer()

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

    private func cameraFailureBody(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Space.lg) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white)

            Text("Camera did not start")
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
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .padding(DesignTokens.Space.lg)
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
}

struct PotholeCameraUnavailableView: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: DesignTokens.Space.lg) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Camera unavailable")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)

                Text("RoadSense lost the photo location context before the camera opened. Close this and try again.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                Button("Close", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Palette.signal)
            }
            .padding(DesignTokens.Space.xl)
        }
    }
}

private enum CameraStartupState: Equatable {
    case idle
    case starting
    case running
    case failed(String)
}

private final class CameraCaptureModel: NSObject, ObservableObject {
    @Published var authorizationState: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var startupState: CameraStartupState = .idle

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "ca.roadsense.camera.session")
    private let output = AVCapturePhotoOutput()
    private var continuation: ((Data) -> Void)?
    private var isConfigured = false
    private var sessionGeneration = 0

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

        startSessionIfNeeded()
    }

    @MainActor
    func stop() {
        sessionGeneration += 1
        startupState = .idle
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    @MainActor
    func capturePhoto(onCapture: @escaping (Data) -> Void) {
        guard startupState == .running else {
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

    @MainActor
    private func startSessionIfNeeded() {
        switch startupState {
        case .starting, .running:
            return
        case .idle, .failed:
            break
        }

        startupState = .starting
        sessionGeneration += 1
        let generation = sessionGeneration

        sessionQueue.async { [weak self] in
            guard let self else { return }

            if let failureMessage = self.configureSessionIfNeeded() {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    self.startupState = .failed(failureMessage)
                }
                return
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            let didStart = self.session.isRunning
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.startupState = didStart
                    ? .running
                    : .failed("iOS did not return an active camera preview. Close and try again.")
            }
        }
    }

    private func configureSessionIfNeeded() -> String? {
        guard !isConfigured else {
            return nil
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return "No back camera is available on this device."
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return "iOS could not open the back camera: \(error.localizedDescription)"
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            return "The camera input could not be added to the capture session."
        }

        guard session.canAddOutput(output) else {
            return "The photo output could not be added to the capture session."
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

        isConfigured = true
        return nil
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
