// Overlay.swift
// Reusable map overlay components and types (stubs)
import Foundation
import SwiftUI

struct MapAnnotationItem: Identifiable {
    let id = UUID()
    // Add coordinate, kind, status, view as needed
}

struct MarkerView: View {
    var body: some View {
        Circle().fill(Color.blue).frame(width: 20, height: 20)
    }
}

struct PolylineHelper {}
