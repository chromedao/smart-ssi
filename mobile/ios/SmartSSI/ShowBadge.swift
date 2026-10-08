import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

private let green = Color(red: 0, green: 1, blue: 0.255)
private let dim = Color.white.opacity(0.6)

/// Full screen, meant to be turned toward someone: the badge and a QR code they scan with their camera.
/// The code is signed by this phone's key and renewed every 30 seconds, so a screenshot of it soon stops working.
struct ShowBadge: View {
    let badge: Badge
    let link: () -> URL?
    let close: () -> Void

    private static let lifetime = 30.0
    @State private var url: URL?
    @State private var madeAt = Date()
    @State private var previousBrightness: CGFloat?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Self.lifetime - context.date.timeIntervalSince(madeAt))
            VStack(spacing: 22) {
                HStack {
                    Text("CHROME DAO · SMART-SSI").font(.caption.monospaced()).foregroundStyle(green)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.title3).foregroundStyle(dim) }
                }

                VStack(spacing: 6) {
                    Text(badge.facts.title)
                        .font(.title.monospaced().bold()).multilineTextAlignment(.center)
                    Text(badge.facts.version == 2 ? "@\(badge.facts.login) · coding since \(badge.facts.sinceYear)" : "@\(badge.facts.login) · GitHub")
                        .font(.callout.monospaced()).foregroundStyle(dim)
                    if badge.facts.version == 2, !badge.facts.languages.isEmpty {
                        Text(badge.facts.languages.filter { $0.name != "Other" }.prefix(3).map(\.name).joined(separator: " · "))
                            .font(.callout.monospaced().bold()).foregroundStyle(green)
                    }
                }

                ZStack {
                    if let url, let image = Self.qrCode(url.absoluteString) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .padding(18)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                            .id(url)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: 320)
                .overlay(Viewfinder().stroke(green, lineWidth: 4).padding(-12))
                .animation(.easeInOut(duration: 0.25), value: url)

                VStack(spacing: 8) {
                    ProgressView(value: left, total: Self.lifetime).tint(green).frame(maxWidth: 220)
                    Text("New code in \(Int(left.rounded(.up))) s").font(.caption.monospaced()).foregroundStyle(dim)
                }

                Text("Ask them to scan it with their phone camera. Their browser checks your badge on Solana and says yes or no. No app needed.")
                    .font(.callout).foregroundStyle(dim).multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(24)
            .onChange(of: left == 0) { _, expired in if expired { renew() } }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            renew()
            // Scanners read a bright screen better.
            previousBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
        }
        .onDisappear {
            if let previousBrightness { UIScreen.main.brightness = previousBrightness }
        }
    }

    private func renew() {
        url = link()
        madeAt = Date()
    }

    private static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Corner ticks around the code, like a camera viewfinder (the app icon's motif).
private struct Viewfinder: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.16
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}
