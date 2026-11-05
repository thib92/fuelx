import AVFoundation
import ConvexMobile
import SwiftUI
import VisionKit

/// Scan a product and hand its food to `onFound`.
struct ScanView: View {
    let onFound: (FoodResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var phase: Phase = .preparing
    /// Set by a scan, which starts the lookup.
    @State private var barcode: String?

    private enum Phase {
        case preparing, scanning, lookingUp
        case unsupported, cameraDenied
        case failed(title: LocalizedStringKey, message: String)
    }

    var body: some View {
        content
            .navigationTitle("Scan a Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .task { await prepareCamera() }
            .task(id: barcode) {
                if let barcode { await lookUp(barcode) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            ProgressView()
        case .scanning:
            BarcodeScannerView { scanned in
                guard barcode == nil else { return }
                phase = .lookingUp
                barcode = scanned
            }
            .ignoresSafeArea()
        case .lookingUp:
            ProgressView("Looking up this product")
        case .unsupported:
            ContentUnavailableView(
                "Scanning Isn't Available",
                systemImage: "barcode.viewfinder",
                description: Text("This device can't scan barcodes. You can search instead."))
        case .cameraDenied:
            ContentUnavailableView {
                Label("Camera Access Needed", systemImage: "camera")
            } description: {
                Text("Allow camera access in Settings to scan barcodes.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .failed(let title, let message):
            ContentUnavailableView {
                Label(title, systemImage: "barcode")
            } description: {
                Text(message)
            } actions: {
                Button("Scan Again", action: scanAgain)
                    .buttonStyle(.borderedProminent)
                Button("Search Instead") { dismiss() }
            }
        }
    }

    private func prepareCamera() async {
        guard DataScannerViewController.isSupported else {
            phase = .unsupported
            return
        }
        let isAllowed = await AVCaptureDevice.requestAccess(for: .video)
        phase = isAllowed && DataScannerViewController.isAvailable ? .scanning : .cameraDenied
    }

    private func scanAgain() {
        barcode = nil
        phase = .scanning
    }

    private func lookUp(_ barcode: String) async {
        do {
            try await ConnectionMonitor.shared.ensureConnected()
            let result: BarcodeLookup = try await convex.action(
                "foods:lookupBarcode", with: ["barcode": barcode])
            guard !Task.isCancelled else { return }
            switch (result.status, result.food) {
            case (.found, let food?):
                onFound(food)
            case (.unavailable, _):
                phase = .failed(
                    title: "Couldn't Check This Product",
                    message: String(
                        localized: "The product database isn't responding. Try again, or search instead."))
            default:
                phase = .failed(
                    title: "Product Not Found",
                    message: String(localized: "We don't have this product. Try searching for it instead."))
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(title: "Couldn't Check This Product", message: error.convexMessage)
        }
    }
}
