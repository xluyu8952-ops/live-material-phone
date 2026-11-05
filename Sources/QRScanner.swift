import SwiftUI
import AVFoundation

struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeUIViewController(context: Context) -> ScanController { let controller = ScanController(); controller.found = found; return controller }
    func updateUIViewController(_ controller: ScanController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScanController, coordinator: ()) { controller.stop() }
}

final class ScanController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var found: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "LiveMaterial.QRScanner")
    private var layer: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private var stopped = false
    private let hint = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        hint.text = "将电脑上的二维码放入画面"; hint.textColor = .white; hint.textAlignment = .center
        hint.numberOfLines = 0; hint.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(hint)
        NSLayoutConstraint.activate([hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            if allowed { self.queue.async { self.configure() } }
            else { DispatchQueue.main.async { self.hint.text = "未允许相机访问。关闭此页后，可直接粘贴电脑连接地址。" } }
        }
    }
    private func configure() {
        guard !stopped else { return }
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else { throw ClientError.message("相机不可用") }
            let input = try AVCaptureDeviceInput(device: camera); let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); return }
            session.addInput(input); session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]; session.commitConfiguration()
            DispatchQueue.main.async {
                let preview = AVCaptureVideoPreviewLayer(session: self.session); preview.videoGravity = .resizeAspectFill
                preview.frame = self.view.bounds; self.view.layer.insertSublayer(preview, at: 0); self.layer = preview
            }
            session.startRunning()
        } catch { DispatchQueue.main.async { self.hint.text = "相机无法使用，请粘贴电脑连接地址。" } }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layer?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        delivered = true; stop(); found?(value)
    }
    func stop() { queue.async { self.stopped = true; if self.session.isRunning { self.session.stopRunning() } } }
}
