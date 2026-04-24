import AVFoundation
import SwiftUI
import UIKit

struct PotholeCameraFlowView: View {
    let coordinateLabel: String
    let onCancel: () -> Void
    let onSubmit: (Data) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraCaptureModel()
    @State private var capturedData: Data?

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
                    .overlay(alignment: .bottom) {
                        VStack(spacing: DesignTokens.Space.md) {
                            Text("Slow down or pull over first. Daylight works best.")
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

private final class CameraCaptureModel: NSObject, ObservableObject {
    @Published var authorizationState: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

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

        configureSessionIfNeeded()
        session.startRunning()
    }

    @MainActor
    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func capturePhoto(onCapture: @escaping (Data) -> Void) {
        continuation = onCapture
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = .off
        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = output.maxPhotoDimensions
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    private func configureSessionIfNeeded() {
        guard session.inputs.isEmpty else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output) else {
            authorizationState = .denied
            return
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
