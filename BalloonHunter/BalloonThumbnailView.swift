import SwiftUI

struct BalloonThumbnailView: View {
    var body: some View {
        ZStack {
            // Sky background
            LinearGradient(gradient: Gradient(colors: [Color(red: 0.6, green: 0.85, blue: 1.0), Color(red: 0.8, green: 0.95, blue: 1.0)]), startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            // Balloon shadow
            Ellipse()
                .fill(Color.black.opacity(0.12))
                .frame(width: 80, height: 18)
                .offset(y: 64)
            
            // Balloon
            VStack(spacing: 0) {
                ZStack {
                    Ellipse()
                        .fill(LinearGradient(gradient: Gradient(colors: [Color.red, Color.orange]), startPoint: .top, endPoint: .bottom))
                        .frame(width: 90, height: 120)
                        .overlay(
                            Ellipse()
                                .stroke(Color.white.opacity(0.9), lineWidth: 4)
                        )
                    // Balloon highlight
                    Ellipse()
                        .fill(Color.white.opacity(0.23))
                        .frame(width: 32, height: 44)
                        .offset(x: -18, y: -25)
                }
                // Knot
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 16, height: 10)
                    .cornerRadius(4)
                    .offset(y: -4)
                // String
                Path { path in
                    path.move(to: CGPoint(x: 45, y: 0))
                    path.addCurve(to: CGPoint(x: 45, y: 38), control1: CGPoint(x: 10, y: 10), control2: CGPoint(x: 80, y: 28))
                }
                .stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 90, height: 40)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview {
    BalloonThumbnailView()
}
