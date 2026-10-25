import SwiftUI
import SceneKit
import UIKit

/// Vue SceneKit interactive pour afficher l'album courant en 3D (CD / Cassette / Boîtier PS5).
struct Shelf3DView: UIViewRepresentable {
    let album: AlbumInfo
    let format: AlbumFormat
    let badges: [AlbumBadge]
    let isPlaying: Bool
    let discOut: Bool
    
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    
    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.configureForShelf()
        
        let scene = SCNScene()
        Studio.addLights(to: scene, withFloor: false)
        scnView.scene = scene
        
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 2.5)
        scene.rootNode.addChildNode(cameraNode)
        
        context.coordinator.setupNode(in: scene, album: album, format: format, badges: badges, library: library, settings: settings)
        return scnView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(album: album, format: format, badges: badges, isPlaying: isPlaying, discOut: discOut, library: library, settings: settings)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator {
        var albumNode: AlbumNode?
        
        func setupNode(in scene: SCNScene, album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], library: Library, settings: AppSettings) {
            let builder = AlbumNodeBuilder(library: library, settings: settings)
            let node = builder.make(album, format: format, badges: badges, extras: true)
            scene.rootNode.addChildNode(node.root)
            self.albumNode = node
        }
        
        func update(album: AlbumInfo, format: AlbumFormat, badges: [AlbumBadge], isPlaying: Bool, discOut: Bool, library: Library, settings: AppSettings) {
            guard let node = albumNode else { return }
            if node.albumID != album.id || node.format != format {
                node.root.removeFromParentNode()
                if let scene = node.root.scene {
                    setupNode(in: scene, album: album, format: format, badges: badges, library: library, settings: settings)
                }
                return
            }
            node.setSpinning(isPlaying)
            node.setDiscOut(discOut, animated: true)
        }
    }
}
