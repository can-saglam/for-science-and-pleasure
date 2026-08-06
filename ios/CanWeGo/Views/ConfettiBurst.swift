import SwiftUI

/// One second of joy: a small burst of the item's accent color, then gone.
struct ConfettiBurst: View {
    let color: Color
    @Binding var fire: Bool
    @State private var expanded = false

    var body: some View {
        Group {
            if fire {
                ZStack {
                    ForEach(0..<18, id: \.self) { i in
                        let angle = Double(i) / 18 * 2 * .pi
                        let distance: CGFloat = expanded ? CGFloat(64 + (i % 4) * 24) : 0
                        Circle()
                            .fill(color.opacity(i % 3 == 0 ? 0.7 : 1))
                            .frame(width: CGFloat(5 + (i % 3) * 3))
                            .offset(
                                x: cos(angle) * distance,
                                y: sin(angle) * distance - (expanded ? 12 : 0)
                            )
                            .opacity(expanded ? 0 : 1)
                            .scaleEffect(expanded ? 0.4 : 1)
                    }
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 0.65)) { expanded = true }
                    Task {
                        try? await Task.sleep(for: .seconds(0.7))
                        fire = false
                        expanded = false
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
