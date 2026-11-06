// Picture in Picture for the one playback engine (TunaTV target only).
// Native routes: AVPictureInPictureController(playerLayer: engine.nativePlayerLayer).
// Software route: engine.softwarePiPSource?.makePictureInPictureController().
// The controller is rebuilt whenever the engine swaps its PiP source or its video route, and
// `engine.pictureInPictureActive` is kept in sync from the controller callbacks.

#if TUNA_ENGINE
import AVFoundation
import AVKit
import Combine
import AetherEngine

@MainActor
final class TunaPictureInPicture: NSObject {
    private let engine: AetherEngine
    private var controller: AVPictureInPictureController?
    private var controllerKey: ObjectIdentifier?
    private var bag = Set<AnyCancellable>()
    private(set) var isActive = false

    /// Called on the main actor whenever the PiP window opens or closes.
    var onActiveChange: ((Bool) -> Void)?

    init(engine: AetherEngine) {
        self.engine = engine
        super.init()
        // @Published fires in willSet: hop to the next main-queue turn so the new values are readable.
        engine.$softwarePiPSource
            .map { _ in () }
            .merge(with: engine.$videoRoute.removeDuplicates().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &bag)
    }

    var isPossible: Bool {
        if controller == nil { rebuild() }
        return controller?.isPictureInPicturePossible ?? false
    }

    func toggle() {
        if controller == nil { rebuild() }
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    private func rebuild() {
        let key: ObjectIdentifier?
        if let source = engine.softwarePiPSource {
            key = ObjectIdentifier(source)
        } else if let layer = engine.nativePlayerLayer {
            key = ObjectIdentifier(layer)
        } else {
            key = nil
        }
        guard key != controllerKey || controller == nil else { return }

        controller?.delegate = nil
        controller = nil
        controllerKey = key
        if let source = engine.softwarePiPSource {
            controller = source.makePictureInPictureController()
        } else if let layer = engine.nativePlayerLayer, AVPictureInPictureController.isPictureInPictureSupported() {
            controller = AVPictureInPictureController(playerLayer: layer)
        }
        controller?.delegate = self
        if controller == nil, isActive { setActive(false) }
    }

    fileprivate func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        engine.pictureInPictureActive = active
        onActiveChange?(active)
    }
}

extension TunaPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated { self.setActive(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated { self.setActive(false) }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { self.setActive(false) }
    }
}
#endif
