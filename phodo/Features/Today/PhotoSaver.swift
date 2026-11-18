import Photos
import UIKit

/// Saves pics taken in phodo's camera to the phone's Photos (like the Camera app would).
/// Asks for "add only" access: phodo can put photos in, but can't see your library.
enum PhotoSaver {
    /// Settings toggle. On unless you turn it off.
    static let settingKey = "saveShotsToPhone"
    static var isOn: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    static func save(_ image: UIImage) {
        guard isOn else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            } catch {
                print("[phodo] saving to Photos failed: \(error)")
            }
        }
    }
}
