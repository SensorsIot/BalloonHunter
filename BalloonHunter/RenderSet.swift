// RenderSet.swift
// Phase 5: Render Set Pipeline
// Transforms domain state → RenderSets with proper z-ordering

import Foundation
import CoreLocation
import MapKit
import SwiftUI

// MARK: - RenderSet Protocol

protocol RenderSet {
    var id: String { get }
    var zOrder: Int { get }
    var isVisible: Bool { get }
    var overlays: [RenderOverlay] { get }
    var annotations: [RenderAnnotation] { get }
}

// MARK: - Render Components

struct RenderOverlay {
    let id: String
    let polyline: MKPolyline
    let style: OverlayStyle
    let zOrder: Int
}

struct RenderAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let style: AnnotationStyle
    let zOrder: Int
}

// MARK: - Styling

struct OverlayStyle {
    let color: Color
    let lineWidth: CGFloat
    let pattern: LinePattern
    let opacity: Double
    
    enum LinePattern {
        case solid
        case dashed
        case dotted
    }
}

struct AnnotationStyle {
    let icon: String  // SF Symbol name
    let color: Color
    let size: CGFloat
    let text: String?
    let halo: HaloStyle?
    
    struct HaloStyle {
        let colors: [Color]  // For dual rings: [blue, green]
        let thickness: CGFloat
        let opacity: Double
    }
}

// MARK: - Concrete RenderSets (Z-Order: 1-8)

// Z-Order 2: Prediction Group
struct PredictionRenderSet: RenderSet {
    let id = "prediction_group"
    let zOrder = 2
    let isVisible: Bool
    let overlays: [RenderOverlay]
    let annotations: [RenderAnnotation]
    
    init(from domainModel: DomainModel) {
        self.isVisible = domainModel.prediction.visible
        
        var renderOverlays: [RenderOverlay] = []
        var renderAnnotations: [RenderAnnotation] = []
        
        // Prediction path overlay (thick blue polyline)
        if !domainModel.prediction.path.isEmpty {
            let coordinates = domainModel.prediction.path.map { $0.coordinate }
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            
            let overlay = RenderOverlay(
                id: "prediction_path",
                polyline: polyline,
                style: OverlayStyle(
                    color: .blue,
                    lineWidth: 4,
                    pattern: .solid,
                    opacity: 1.0
                ),
                zOrder: 2
            )
            renderOverlays.append(overlay)
        }
        
        self.overlays = renderOverlays
        self.annotations = renderAnnotations
    }
}

// Z-Order 3: Track Group
struct TrackRenderSet: RenderSet {
    let id = "track_group"
    let zOrder = 3
    let isVisible = true  // Always visible when data exists
    let overlays: [RenderOverlay]
    let annotations: [RenderAnnotation]
    
    init(from domainModel: DomainModel) {
        var renderOverlays: [RenderOverlay] = []
        
        // Balloon track overlay (thin red polyline)
        let allTrackPoints = domainModel.getAllTrackPoints()
        if !allTrackPoints.isEmpty {
            let coordinates = allTrackPoints.map { $0.coordinate }
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            
            let overlay = RenderOverlay(
                id: "balloon_track",
                polyline: polyline,
                style: OverlayStyle(
                    color: .red,
                    lineWidth: 2,
                    pattern: .solid,
                    opacity: 1.0
                ),
                zOrder: 3
            )
            renderOverlays.append(overlay)
        }
        
        self.overlays = renderOverlays
        self.annotations = []
    }
}

// Z-Order 4: Route Group
struct RouteRenderSet: RenderSet {
    let id = "route_group"
    let zOrder = 4
    let isVisible: Bool
    let overlays: [RenderOverlay]
    let annotations: [RenderAnnotation]
    
    init(from domainModel: DomainModel) {
        // Visibility based on route availability and distance rules
        self.isVisible = domainModel.routing.route != nil
        
        var renderOverlays: [RenderOverlay] = []
        
        // Route path overlay (green polyline)
        if let route = domainModel.routing.route {
            let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
            
            let overlay = RenderOverlay(
                id: "user_route",
                polyline: polyline,
                style: OverlayStyle(
                    color: .green,
                    lineWidth: 3,
                    pattern: .solid,
                    opacity: 1.0
                ),
                zOrder: 4
            )
            renderOverlays.append(overlay)
        }
        
        self.overlays = renderOverlays
        self.annotations = []
    }
}

// Z-Order 5: Burst Marker
struct BurstRenderSet: RenderSet {
    let id = "burst_marker"
    let zOrder = 5
    let isVisible: Bool
    let overlays: [RenderOverlay] = []
    let annotations: [RenderAnnotation]
    
    init(from domainModel: DomainModel) {
        // Only visible when balloon is ascending and burst point exists
        self.isVisible = domainModel.balloon.isAscending && domainModel.prediction.burst != nil
        
        var renderAnnotations: [RenderAnnotation] = []
        
        if let burstPoint = domainModel.prediction.burst, isVisible {
            let annotation = RenderAnnotation(
                id: "burst_point",
                coordinate: burstPoint,
                style: AnnotationStyle(
                    icon: "star.fill",  // Explosion/star symbol
                    color: .orange,
                    size: 24,
                    text: nil,
                    halo: nil
                ),
                zOrder: 5
            )
            renderAnnotations.append(annotation)
        }
        
        self.annotations = renderAnnotations
    }
}

// Z-Order 6: Landing Feature (Single Shared Pin/Flag)
struct LandingRenderSet: RenderSet {
    let id = "landing_feature"
    let zOrder = 6
    let isVisible: Bool
    let overlays: [RenderOverlay] = []
    let annotations: [RenderAnnotation]
    
    init(from domainModel: DomainModel) {
        // Shown whenever a valid landing exists (independent of prediction toggle)
        self.isVisible = domainModel.landingPoint != nil
        
        var renderAnnotations: [RenderAnnotation] = []
        
        if let landingPoint = domainModel.landingPoint {
            // Contextual halos based on what's visible
            var haloColors: [Color] = []
            if domainModel.prediction.visible {
                haloColors.append(.blue)
            }
            if domainModel.routing.route != nil {
                haloColors.append(.green)
            }
            
            let haloStyle = haloColors.isEmpty ? nil : AnnotationStyle.HaloStyle(
                colors: haloColors,
                thickness: 3.0,
                opacity: 0.7
            )
            
            let annotation = RenderAnnotation(
                id: "landing_point",
                coordinate: landingPoint.coordinate,
                style: AnnotationStyle(
                    icon: "flag.fill",
                    color: .primary,
                    size: 28,
                    text: nil,
                    halo: haloStyle
                ),
                zOrder: 6
            )
            renderAnnotations.append(annotation)
        }
        
        self.annotations = renderAnnotations
    }
}

// Z-Order 7: Balloon Feature
struct BalloonRenderSet: RenderSet {
    let id = "balloon_feature"
    let zOrder = 7
    let isVisible: Bool
    let overlays: [RenderOverlay] = []
    let annotations: [RenderAnnotation]
    
    init(from domainModel: DomainModel) {
        self.isVisible = domainModel.balloon.coordinate != nil
        
        var renderAnnotations: [RenderAnnotation] = []
        
        if let coordinate = domainModel.balloon.coordinate {
            // Color: green while ascending, red while descending
            let balloonColor: Color = domainModel.balloon.isAscending ? .green : .red
            
            // Altitude text inside balloon
            let altitudeText: String? = if let altitude = domainModel.balloon.altitude {
                "\(Int(altitude))m"
            } else {
                nil
            }
            
            let annotation = RenderAnnotation(
                id: "balloon_position",
                coordinate: coordinate,
                style: AnnotationStyle(
                    icon: "balloon.fill",
                    color: balloonColor,
                    size: 32,
                    text: altitudeText,
                    halo: nil
                ),
                zOrder: 7
            )
            renderAnnotations.append(annotation)
        }
        
        self.annotations = renderAnnotations
    }
}

// Z-Order 8: User Feature
struct UserRenderSet: RenderSet {
    let id = "user_feature"
    let zOrder = 8
    let isVisible: Bool
    let overlays: [RenderOverlay] = []
    let annotations: [RenderAnnotation]
    
    init(from domainModel: DomainModel) {
        self.isVisible = domainModel.userLocation != nil
        
        var renderAnnotations: [RenderAnnotation] = []
        
        if let userLocation = domainModel.userLocation {
            let annotation = RenderAnnotation(
                id: "user_position",
                coordinate: userLocation.coordinate,
                style: AnnotationStyle(
                    icon: "figure.walk",
                    color: .blue,
                    size: 24,
                    text: nil,
                    halo: nil
                ),
                zOrder: 8
            )
            renderAnnotations.append(annotation)
        }
        
        self.annotations = renderAnnotations
    }
}

// MARK: - RenderSet Coordinator

struct RenderSetCoordinator {
    /// Transforms domain state → RenderSets with proper z-ordering
    static func createRenderSets(from domainModel: DomainModel) -> [RenderSet] {
        let renderSets: [RenderSet] = [
            PredictionRenderSet(from: domainModel),
            TrackRenderSet(from: domainModel),
            RouteRenderSet(from: domainModel),
            BurstRenderSet(from: domainModel),
            LandingRenderSet(from: domainModel),
            BalloonRenderSet(from: domainModel),
            UserRenderSet(from: domainModel)
        ]
        
        // Return sorted by z-order (though they're already in order)
        return renderSets.sorted { $0.zOrder < $1.zOrder }
    }
    
    /// Get all overlays from visible RenderSets, sorted by z-order
    static func getAllOverlays(from renderSets: [RenderSet]) -> [RenderOverlay] {
        return renderSets
            .filter { $0.isVisible }
            .flatMap { $0.overlays }
            .sorted { $0.zOrder < $1.zOrder }
    }
    
    /// Get all annotations from visible RenderSets, sorted by z-order
    static func getAllAnnotations(from renderSets: [RenderSet]) -> [RenderAnnotation] {
        return renderSets
            .filter { $0.isVisible }
            .flatMap { $0.annotations }
            .sorted { $0.zOrder < $1.zOrder }
    }
}

// MARK: - SwiftUI Integration

extension RenderAnnotation {
    /// Creates SwiftUI view for this annotation
    @ViewBuilder
    func createAnnotationView() -> some View {
        ZStack {
            // Halo rings (bottom layer)
            if let halo = style.halo {
                ForEach(Array(halo.colors.enumerated()), id: \.offset) { index, color in
                    Circle()
                        .stroke(color, lineWidth: halo.thickness)
                        .frame(width: style.size + CGFloat(index + 1) * halo.thickness * 2)
                        .opacity(halo.opacity)
                }
            }
            
            // Main icon
            Image(systemName: style.icon)
                .foregroundColor(style.color)
                .font(.system(size: style.size))
            
            // Text overlay (if any)
            if let text = style.text {
                Text(text)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .shadow(radius: 1)
            }
        }
    }
}

extension RenderOverlay {
    /// Creates MapKit polyline with style information
    func createStyledPolyline() -> MKPolyline {
        polyline.title = id  // Store ID for styling
        return polyline
    }
}