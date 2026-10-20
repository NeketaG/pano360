import ARKit
import SceneKit
import SwiftUI
import UIKit

struct CaptureView: View {
    let onFinished: (URL) -> Void

    @StateObject private var capture = CaptureSession()
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirm = false

    private let guideHalfFOVDeg: Float = 30
    private let panelAngularWidthDeg: Float = 28
    private let panelAngularHeightDeg: Float = 38

    var body: some View {
        ZStack {
            ARViewRepresentable(session: capture.session)
                .ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    ForEach(capture.gridPoints) { point in
                        if let offset = screenOffset(for: point, in: geo.size) {
                            if point.captured, let thumbnail = capture.capturedThumbnails[point.id] {
                                let panel = panelSize(in: geo.size)
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: panel.width, height: panel.height)
                                    .clipped()
                                    .overlay(Rectangle().stroke(Color.green, lineWidth: 2))
                                    .position(x: geo.size.width / 2 + offset.x, y: geo.size.height / 2 + offset.y)
                            } else {
                                MarkerView(isAligned: capture.alignedPointID == point.id)
                                    .position(x: geo.size.width / 2 + offset.x, y: geo.size.height / 2 + offset.y)
                            }
                        }
                    }

                    if let arrow = nearestOffscreenDirection(in: geo.size) {
                        Image(systemName: "location.north.fill")
                            .font(.title)
                            .foregroundStyle(.yellow)
                            .rotationEffect(.radians(Double(arrow.angle)))
                            .position(x: geo.size.width / 2 + arrow.point.x, y: geo.size.height / 2 + arrow.point.y)
                    }

                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }

            VStack {
                Text(capture.statusText)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 12)

                Spacer()

                HStack(spacing: 20) {
                    Button {
                        capture.undoLastCapture()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .opacity(capture.canUndo ? 1 : 0.3)
                    .disabled(!capture.canUndo)

                    Button {
                        showResetConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .opacity(capture.canUndo ? 1 : 0.3)
                    .disabled(!capture.canUndo)

                    Spacer()

                    Button {
                        capture.toggleTorch()
                    } label: {
                        Image(systemName: capture.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.title2)
                            .foregroundStyle(capture.isTorchOn ? .yellow : .white)
                            .padding(14)
                            .background(.black.opacity(0.5), in: Circle())
                    }

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            capture.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            capture.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: capture.isFinished) { _, finished in
            if finished { onFinished(capture.outputDirectory) }
        }
        .alert("Начать съёмку заново?", isPresented: $showResetConfirm) {
            Button("Сбросить", role: .destructive) { capture.resetAll() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все снятые кадры в этой съёмке будут удалены.")
        }
    }

    private func yawDelta(to point: GridPoint) -> Float {
        point.ignoresYaw ? 0 : angularDifference(point.yaw, capture.currentYaw)
    }

    private func screenOffset(for point: GridPoint, in size: CGSize) -> CGPoint? {
        let dYaw = yawDelta(to: point)
        let dPitch = point.pitch - capture.currentPitch
        let halfFOV = guideHalfFOVDeg * .pi / 180
        guard abs(dYaw) < halfFOV, abs(dPitch) < halfFOV else { return nil }
        let x = CGFloat(dYaw / halfFOV) * (size.width / 2)
        let y = CGFloat(-dPitch / halfFOV) * (size.height / 2)
        return CGPoint(x: x, y: y)
    }

    private func panelSize(in size: CGSize) -> CGSize {
        let halfFOV = guideHalfFOVDeg * .pi / 180
        let widthRad = panelAngularWidthDeg * .pi / 180
        let heightRad = panelAngularHeightDeg * .pi / 180
        let w = CGFloat(widthRad / halfFOV) * (size.width / 2)
        let h = CGFloat(heightRad / halfFOV) * (size.height / 2)
        return CGSize(width: w, height: h)
    }

    private func nearestOffscreenDirection(in size: CGSize) -> (point: CGPoint, angle: Float)? {
        let remaining = capture.gridPoints.filter { !$0.captured }
        guard let target = remaining.min(by: {
            squaredDistance(from: $0) < squaredDistance(from: $1)
        }) else { return nil }

        let dYaw = yawDelta(to: target)
        let dPitch = target.pitch - capture.currentPitch
        let halfFOV = guideHalfFOVDeg * .pi / 180
        if abs(dYaw) < halfFOV, abs(dPitch) < halfFOV { return nil }

        let angle = atan2(dYaw, dPitch)
        let radius = min(size.width, size.height) / 2 - 40
        let point = CGPoint(x: CGFloat(sin(angle)) * radius, y: CGFloat(-cos(angle)) * radius)
        return (point, angle)
    }

    private func squaredDistance(from point: GridPoint) -> Float {
        let dYaw = yawDelta(to: point)
        let dPitch = point.pitch - capture.currentPitch
        return dYaw * dYaw + dPitch * dPitch
    }
}

private struct MarkerView: View {
    let isAligned: Bool

    var body: some View {
        let size: CGFloat = isAligned ? 46 : 36
        Circle()
            .strokeBorder(isAligned ? Color.yellow : Color.white, lineWidth: isAligned ? 4 : 2)
            .frame(width: size, height: size)
    }
}

private struct ARViewRepresentable: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
