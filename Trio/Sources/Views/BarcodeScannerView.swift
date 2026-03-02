import AVFoundation
import SwiftUI
import UIKit

struct BarcodeScannerView: UIViewControllerRepresentable {
    @Binding var scannedCode: String?
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> BarcodeScannerViewController {
        let controller = BarcodeScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_: BarcodeScannerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, BarcodeScannerDelegate {
        let parent: BarcodeScannerView

        init(_ parent: BarcodeScannerView) {
            self.parent = parent
        }

        func didScanBarcode(_ code: String) {
            parent.scannedCode = code
            parent.isPresented = false
        }

        func didFailWithError(_ error: Error) {
            print("Barcode scanning failed: \(error.localizedDescription)")
            parent.isPresented = false
        }
    }
}

protocol BarcodeScannerDelegate: AnyObject {
    func didScanBarcode(_ code: String)
    func didFailWithError(_ error: Error)
}

class BarcodeScannerViewController: UIViewController {
    weak var delegate: BarcodeScannerDelegate?

    private var captureSession: AVCaptureSession!
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var scanningView: UIView!
    private var instructionLabel: UILabel!
    private var scanLine: UIView!
    private var scanLineTopConstraint: NSLayoutConstraint?
    private var cornerBrackets: [UIView] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        prepareCamera()
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startScanAnimation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if captureSession != nil, !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if captureSession != nil, captureSession.isRunning {
            captureSession.stopRunning()
        }
        previewLayer?.removeFromSuperlayer()
    }

    deinit {
        if captureSession != nil, captureSession.isRunning {
            captureSession.stopRunning()
        }
        previewLayer = nil
        captureSession = nil
    }

    private func prepareCamera() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.setupCamera()
                    } else {
                        self.presentPermissionAlert()
                    }
                }
            }
        case .denied,
             .restricted:
            presentPermissionAlert()
        @unknown default:
            delegate?.didFailWithError(BarcodeScannerError.cameraNotAvailable)
        }
    }

    private func setupCamera() {
        captureSession = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            delegate?.didFailWithError(BarcodeScannerError.cameraNotAvailable)
            return
        }

        let videoInput: AVCaptureDeviceInput

        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            delegate?.didFailWithError(error)
            return
        }

        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            delegate?.didFailWithError(BarcodeScannerError.cannotAddInput)
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()

        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)

            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [
                .ean8, .ean13, .pdf417, .qr, .code128, .code39, .code93,
                .upce, .aztec, .dataMatrix, .interleaved2of5, .itf14
            ]
        } else {
            delegate?.didFailWithError(BarcodeScannerError.cannotAddOutput)
            return
        }

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    private func setupUI() {
        view.backgroundColor = UIColor.black

        // Add semi-transparent overlay with cut-out for scanning area
        let overlayView = UIView()
        overlayView.backgroundColor = UIColor.clear
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)

        // Create scanning area with modern design
        scanningView = UIView()
        scanningView.backgroundColor = UIColor.clear
        scanningView.layer.cornerRadius = 20
        scanningView.translatesAutoresizingMaskIntoConstraints = false
        scanningView.accessibilityLabel = NSLocalizedString(
            "Barcode scanning area",
            comment: "Accessibility label for the barcode scanning frame"
        )
        scanningView.accessibilityHint = NSLocalizedString(
            "Position the barcode within this frame to scan",
            comment: "Accessibility hint for the barcode scanning frame"
        )
        view.addSubview(scanningView)

        // Add corner brackets for visual guidance
        addCornerBrackets()

        // Add animated scanning line
        addScanLine()

        // Create instruction label with modern styling
        instructionLabel = UILabel()
        instructionLabel.text = NSLocalizedString(
            "Align barcode in the frame",
            comment: "Instruction label in the barcode scanner view"
        )
        instructionLabel.textColor = UIColor.white
        instructionLabel.textAlignment = .center
        instructionLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        instructionLabel.numberOfLines = 0
        instructionLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.85)
        instructionLabel.layer.cornerRadius = 14
        instructionLabel.layer.masksToBounds = true
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.layer.shadowColor = UIColor.black.cgColor
        instructionLabel.layer.shadowOffset = CGSize(width: 0, height: 2)
        instructionLabel.layer.shadowOpacity = 0.3
        instructionLabel.layer.shadowRadius = 4
        view.addSubview(instructionLabel)

        // Create modern close button with SF Symbol
        let closeButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        let closeImage = UIImage(systemName: "xmark.circle.fill", withConfiguration: config)
        closeButton.setImage(closeImage, for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 22
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = NSLocalizedString(
            "Close barcode scanner",
            comment: "Accessibility label for the close button in the barcode scanner"
        )
        closeButton.accessibilityHint = NSLocalizedString(
            "Dismiss the barcode scanning interface",
            comment: "Accessibility hint for the close button in the barcode scanner"
        )

        // Add shadow to close button
        closeButton.layer.shadowColor = UIColor.black.cgColor
        closeButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        closeButton.layer.shadowOpacity = 0.3
        closeButton.layer.shadowRadius = 4
        view.addSubview(closeButton)

        // Setup constraints
        NSLayoutConstraint.activate([
            // Overlay
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Scanning area
            scanningView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanningView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            scanningView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
            scanningView.heightAnchor.constraint(equalTo: scanningView.widthAnchor, multiplier: 0.6),

            // Instruction label
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.topAnchor.constraint(equalTo: scanningView.bottomAnchor, constant: 32),
            instructionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            instructionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            instructionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),

            // Close button
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Add pulsing animation to instruction label
        addPulsingAnimation(to: instructionLabel)
    }

    private func addCornerBrackets() {
        let bracketLength: CGFloat = 30
        let bracketWidth: CGFloat = 4
        let bracketColor = UIColor.systemGreen

        // Top-left
        let topLeft = createBracket(length: bracketLength, width: bracketWidth, color: bracketColor)
        scanningView.addSubview(topLeft)
        NSLayoutConstraint.activate([
            topLeft.topAnchor.constraint(equalTo: scanningView.topAnchor),
            topLeft.leadingAnchor.constraint(equalTo: scanningView.leadingAnchor)
        ])

        // Top-right
        let topRight = createBracket(length: bracketLength, width: bracketWidth, color: bracketColor)
        topRight.transform = CGAffineTransform(scaleX: -1, y: 1)
        scanningView.addSubview(topRight)
        NSLayoutConstraint.activate([
            topRight.topAnchor.constraint(equalTo: scanningView.topAnchor),
            topRight.trailingAnchor.constraint(equalTo: scanningView.trailingAnchor)
        ])

        // Bottom-left
        let bottomLeft = createBracket(length: bracketLength, width: bracketWidth, color: bracketColor)
        bottomLeft.transform = CGAffineTransform(scaleX: 1, y: -1)
        scanningView.addSubview(bottomLeft)
        NSLayoutConstraint.activate([
            bottomLeft.bottomAnchor.constraint(equalTo: scanningView.bottomAnchor),
            bottomLeft.leadingAnchor.constraint(equalTo: scanningView.leadingAnchor)
        ])

        // Bottom-right
        let bottomRight = createBracket(length: bracketLength, width: bracketWidth, color: bracketColor)
        bottomRight.transform = CGAffineTransform(scaleX: -1, y: -1)
        scanningView.addSubview(bottomRight)
        NSLayoutConstraint.activate([
            bottomRight.bottomAnchor.constraint(equalTo: scanningView.bottomAnchor),
            bottomRight.trailingAnchor.constraint(equalTo: scanningView.trailingAnchor)
        ])
    }

    private func createBracket(length: CGFloat, width: CGFloat, color: UIColor) -> UIView {
        let bracket = UIView()
        bracket.translatesAutoresizingMaskIntoConstraints = false

        let horizontal = UIView()
        horizontal.backgroundColor = color
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        bracket.addSubview(horizontal)

        let vertical = UIView()
        vertical.backgroundColor = color
        vertical.translatesAutoresizingMaskIntoConstraints = false
        bracket.addSubview(vertical)

        NSLayoutConstraint.activate([
            horizontal.topAnchor.constraint(equalTo: bracket.topAnchor),
            horizontal.leadingAnchor.constraint(equalTo: bracket.leadingAnchor),
            horizontal.widthAnchor.constraint(equalToConstant: length),
            horizontal.heightAnchor.constraint(equalToConstant: width),

            vertical.topAnchor.constraint(equalTo: bracket.topAnchor),
            vertical.leadingAnchor.constraint(equalTo: bracket.leadingAnchor),
            vertical.widthAnchor.constraint(equalToConstant: width),
            vertical.heightAnchor.constraint(equalToConstant: length)
        ])

        return bracket
    }

    private func addScanLine() {
        scanLine = UIView()
        scanLine.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.7)
        scanLine.translatesAutoresizingMaskIntoConstraints = false
        scanningView.addSubview(scanLine)

        let topConstraint = scanLine.topAnchor.constraint(equalTo: scanningView.topAnchor)
        scanLineTopConstraint = topConstraint
        NSLayoutConstraint.activate([
            scanLine.leadingAnchor.constraint(equalTo: scanningView.leadingAnchor),
            scanLine.trailingAnchor.constraint(equalTo: scanningView.trailingAnchor),
            scanLine.heightAnchor.constraint(equalToConstant: 2),
            topConstraint
        ])
    }

    private func startScanAnimation() {
        guard scanLine != nil, let topConstraint = scanLineTopConstraint else { return }
        topConstraint.constant = 0
        scanningView.layoutIfNeeded()

        UIView.animate(withDuration: 2.0, delay: 0, options: [.repeat, .autoreverse, .curveEaseInOut], animations: {
            topConstraint.constant = self.scanningView.bounds.height - 2
            self.scanningView.layoutIfNeeded()
        }, completion: nil)
    }

    private func addPulsingAnimation(to view: UIView) {
        UIView.animate(withDuration: 1.5, delay: 0, options: [.repeat, .autoreverse, .curveEaseInOut], animations: {
            view.alpha = 0.7
        }, completion: nil)
    }

    @objc private func closeButtonTapped() {
        delegate?.didFailWithError(BarcodeScannerError.userCancelled)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    private func presentPermissionAlert() {
        let alert = UIAlertController(
            title: NSLocalizedString("Camera Access Needed", comment: "Camera permission alert title"),
            message: NSLocalizedString(
                "Enable camera access in Settings to scan barcodes.",
                comment: "Camera permission alert message"
            ),
            preferredStyle: .alert
        )

        alert
            .addAction(UIAlertAction(
                title: NSLocalizedString("Open Settings", comment: "Button to open iOS Settings"),
                style: .default
            ) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString),
                   UIApplication.shared.canOpenURL(url)
                {
                    UIApplication.shared.open(url)
                }
                self.delegate?.didFailWithError(BarcodeScannerError.permissionDenied)
            })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.delegate?.didFailWithError(BarcodeScannerError.permissionDenied)
        })

        present(alert, animated: true)
    }
}

extension BarcodeScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from _: AVCaptureConnection) {
        captureSession.stopRunning()

        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue else { return }

            // Provide haptic feedback with success animation
            playHapticFeedback()
            showSuccessAnimation()
            delegate?.didScanBarcode(stringValue)
        }
    }

    private func playHapticFeedback() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
    }

    private func showSuccessAnimation() {
        scanningView.layer.borderColor = UIColor.systemGreen.cgColor
        scanningView.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.2)

        UIView.animate(withDuration: 0.3, animations: {
            self.scanningView.alpha = 0.7
        }) { _ in
            UIView.animate(withDuration: 0.2) {
                self.scanningView.alpha = 1.0
            }
        }
    }
}

enum BarcodeScannerError: LocalizedError {
    case cameraNotAvailable
    case cannotAddInput
    case cannotAddOutput
    case userCancelled
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .cameraNotAvailable:
            return "Camera not available"
        case .cannotAddInput:
            return "Cannot add camera input"
        case .cannotAddOutput:
            return "Cannot add metadata output"
        case .userCancelled:
            return "User cancelled scanning"
        case .permissionDenied:
            return "Camera permission denied"
        }
    }
}
