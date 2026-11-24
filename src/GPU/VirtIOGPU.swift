import Foundation

enum VirtIOGPUCommand {
    case reset
    case updateFramebuffer(Data, width: Int, height: Int, dirtyRegion: GPUFrameRegion?, sessionGeneration: UInt64)
    case present
}

final class VirtIOGPU {
    private let backend: GPUBackend
    private let generationLock = NSLock()
    private var sessionGeneration: UInt64 = 0
    private(set) var frameCount = 0

    init(backend: GPUBackend) {
        self.backend = backend
    }

    func start() {
        backend.start()
    }

    func stop() {
        backend.stop()
    }

    func setSessionGeneration(_ generation: UInt64) {
        generationLock.lock()
        guard generation >= sessionGeneration else {
            generationLock.unlock()
            return
        }
        let changed = generation != sessionGeneration
        sessionGeneration = generation
        generationLock.unlock()
        if changed { backend.setSessionGeneration(generation) }
    }

    func submit(_ command: VirtIOGPUCommand) {
        switch command {
        case .reset:
            frameCount = 0
        case let .updateFramebuffer(data, width, height, dirtyRegion, generation):
            generationLock.lock()
            let isCurrent = generation == sessionGeneration
            generationLock.unlock()
            guard isCurrent else { return }
            backend.submit(frame: data, width: width, height: height,
                           dirtyRegion: dirtyRegion, sessionGeneration: generation)
            frameCount += 1
        case .present:
            break
        }
    }
}
