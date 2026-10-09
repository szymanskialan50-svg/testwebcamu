import SwiftUI

@main
struct USCCamApp: App {
    @StateObject private var camera = CameraManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .preferredColorScheme(.dark)
                .onAppear { camera.start() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var camera: CameraManager
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = 0.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "camera.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 120, height: 120)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                VStack(spacing: 6) {
                    Text("USC-CAM")
                        .font(.system(size: 30, weight: .bold))
                        .tracking(4)
                    Text("USB WEBCAM")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(3)
                        .foregroundColor(.gray)
                }

                statusPill

                VStack(spacing: 0) {
                    row("Resolution", camera.resolution)
                    Divider().background(Color.white.opacity(0.1))
                    row("Frame rate", camera.pcConnected ? "\(camera.fps) fps" : "-")
                    Divider().background(Color.white.opacity(0.1))
                    row("Camera", camera.usingFrontCamera ? "Front" : "Back")
                }
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 32)

                HStack(spacing: 14) {
                    button("Flip camera", "arrow.triangle.2.circlepath.camera") { camera.flipCamera() }
                    button("Dim screen", "moon.fill") { setDimmed(true) }
                }
                .padding(.horizontal, 32)

                Spacer()

                Text("Keep this app open. iOS pauses the camera when the app is in the background.")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
            }
            .foregroundColor(.white)

            if dimmed {
                Color.black.ignoresSafeArea()
                    .overlay(Text("Tap to wake").font(.footnote).foregroundColor(Color.white.opacity(0.25)))
                    .onTapGesture { setDimmed(false) }
            }
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch camera.phase {
            case .denied:   return ("Camera access denied - enable it in Settings", .red)
            case .noCamera: return ("No camera available", .red)
            case .starting: return ("Starting...", .orange)
            case .running:  return camera.pcConnected ? ("Streaming to PC", .green)
                                                      : ("Ready - waiting for PC", .orange)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.gray)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func button(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func setDimmed(_ on: Bool) {
        if on { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = on ? 0.0 : savedBrightness
        dimmed = on
    }
}
