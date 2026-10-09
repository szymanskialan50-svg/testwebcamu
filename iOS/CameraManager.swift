import AVFoundation
import UIKit
import Network
import ImageIO

/// Captures video from the iPhone camera and serves JPEG frames over TCP port 9999.
/// The PC host reaches this port through the USB cable (usbmuxd), no Wi-Fi needed.
/// Wire format: [4 bytes big-endian length][JPEG bytes] repeated.
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Phase { case starting, denied, noCamera, running }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var pcConnected = false
    @Published private(set) var resolution = "-"
    @Published private(set) var fps = 0
    @Published private(set) var usingFrontCamera = false

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "usc.session")
    private let frameQueue = DispatchQueue(label: "usc.frames", qos: .userInteractive)
    private let netQueue = DispatchQueue(label: "usc.net")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let output = AVCaptureVideoDataOutput()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var configured = false

    private let lock = NSLock()
    private var inFlight = 0
    private var frameCounter = 0
    private var lastFpsTick = CACurrentMediaTime()

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        startListener()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                ok ? self?.configureAndRun() : self?.setPhase(.denied)
            }
        default:
            setPhase(.denied)
        }
    }

    func flipCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let front = !self.usingFrontCamera
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if self.addInput(front: front) {
                DispatchQueue.main.async { self.usingFrontCamera = front }
            } else {
                _ = self.addInput(front: !front)
            }
            self.applyPreset()
            self.session.commitConfiguration()
            self.updateResolutionLabel()
        }
    }

    // MARK: Camera

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                guard self.addInput(front: false) else {
                    self.session.commitConfiguration()
                    self.setPhase(.noCamera)
                    return
                }
                self.applyPreset()

                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                // Hardware JPEG encoder: far faster than converting every 4K frame on the CPU.
                // (Must be set after the output joined the session so the codec list is valid.)
                if self.output.availableVideoCodecTypes.contains(.jpeg) {
                    self.output.videoSettings = [
                        AVVideoCodecKey: AVVideoCodecType.jpeg,
                        AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.9]
                    ]
                }
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.updateResolutionLabel()
            self.setPhase(.running)
        }
    }

    @discardableResult
    private func addInput(front: Bool) -> Bool {
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        return true
    }

    private func applyPreset() {
        for preset in [AVCaptureSession.Preset.hd4K3840x2160, .hd1920x1080, .high] where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
    }

    private func updateResolutionLabel() {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        DispatchQueue.main.async { self.resolution = "\(d.width)x\(d.height)" }
    }

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p }
    }

    // MARK: Network (USB tunnel endpoint)

    private func startListener() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: 9999)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.netQueue.asyncAfter(deadline: .now() + 1) { self?.startListener() }
                }
            }
            l.start(queue: netQueue)
            listener = l
        } catch {
            netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startListener() }
        }
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        lock.lock(); inFlight = 0; lock.unlock()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            switch state {
            case .ready: DispatchQueue.main.async { self.pcConnected = true }
            case .failed, .cancelled: DispatchQueue.main.async { self.pcConnected = false }
            default: break
            }
        }
        conn.start(queue: netQueue)
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let conn = self.connection, conn.state == .ready else { return }

        lock.lock()
        let busy = inFlight >= 2          // PC/USB can't keep up -> drop frame, keep latency low
        lock.unlock()
        if busy { return }

        guard let jpeg = jpegData(from: sampleBuffer) else { return }

        var length = UInt32(jpeg.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(jpeg)

        lock.lock(); inFlight += 1; lock.unlock()
        conn.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.lock.lock(); self?.inFlight -= 1; self?.lock.unlock()
        })
        tickFps()
    }

    private func jpegData(from sampleBuffer: CMSampleBuffer) -> Data? {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Fallback path (raw pixels): encode with Core Image.
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            return ciContext.jpegRepresentation(of: image, colorSpace: space,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let p = pointer, length > 0 else { return nil }
        return Data(bytes: p, count: length)
    }

    private func tickFps() {
        frameCounter += 1
        let now = CACurrentMediaTime()
        if now - lastFpsTick >= 1 {
            let value = Int((Double(frameCounter) / (now - lastFpsTick)).rounded())
            frameCounter = 0
            lastFpsTick = now
            DispatchQueue.main.async { self.fps = value }
        }
    }
}
