import Foundation
import UIKit
import Metal
import MetalKit

/// Presents validated BGRA/RGBA-sized frames on Metal.
/// Until a guest framebuffer is connected, the view clears to a stable dark screen
/// instead of drawing a synthetic test pattern that can look like corrupted guest output.
final class MetalGPUBackend: NSObject, GPUBackend {
    private final class FramebufferSlot {
        let texture: MTLTexture
        var readers = 0
        var isUploading = false
        init(texture: MTLTexture) { self.texture = texture }
    }

    private struct PendingFrame {
        let data: Data
        let width: Int
        let height: Int
        let sequence: UInt64
        let generation: UInt64
        let sessionGeneration: UInt64
    }

    let name = "VirtIO GPU • Metal"
    let isHardwareAccelerated = MTLCreateSystemDefaultDevice() != nil
    let width: Int
    let height: Int
    let view: MTKView

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let textureLock = NSLock()
    private var displayUpdateScheduled = false
    private var framebufferSlots: [FramebufferSlot] = []
    private var framebuffer: FramebufferSlot?
    private var drawableWidth: Int
    private var drawableHeight: Int
    private var framebufferWidth: Int
    private var framebufferHeight: Int
    private var framebufferGeneration: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    private var nextFrameSequence: UInt64 = 0
    private var publishedFrameSequence: UInt64 = 0
    private var pendingFullFrame: PendingFrame?
    private var requiresFullFrameUpload = false
    private var pendingFrameDrainScheduled = false
    private let targetFrameRate: Int
    private let maxFramebufferBytes = 64 * 1024 * 1024
    private let maxFramebufferPoolBytes = 128 * 1024 * 1024
    private let maxFramebufferSlots = 3

    init(width: Int, height: Int, frameRate: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.drawableWidth = max(1, width)
        self.drawableHeight = max(1, height)
        self.framebufferWidth = max(1, width)
        self.framebufferHeight = max(1, height)
        self.targetFrameRate = max(1, frameRate)
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        view = MTKView(frame: .zero, device: device)
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: self.width, height: self.height)
        view.contentMode = .scaleAspectFit
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
        view.preferredFramesPerSecond = min(self.targetFrameRate, DisplayCapabilities.maximumFramesPerSecond)
        view.delegate = self
    }

    func start() {
        scheduleDisplayUpdate()
    }

    func stop() {
        textureLock.lock()
        framebufferGeneration &+= 1
        framebuffer = nil
        framebufferSlots.removeAll(keepingCapacity: false)
        pendingFullFrame = nil
        requiresFullFrameUpload = false
        textureLock.unlock()
        scheduleDisplayUpdate()
    }

    func setSessionGeneration(_ generation: UInt64) {
        textureLock.lock()
        guard generation >= sessionGeneration else {
            textureLock.unlock()
            return
        }
        guard generation != sessionGeneration else {
            textureLock.unlock()
            return
        }
        sessionGeneration = generation
        framebufferGeneration &+= 1
        framebuffer = nil
        framebufferSlots.removeAll(keepingCapacity: false)
        nextFrameSequence = 0
        publishedFrameSequence = 0
        pendingFullFrame = nil
        requiresFullFrameUpload = true
        textureLock.unlock()
        scheduleDisplayUpdate()
    }

    private func scheduleDisplayUpdate() {
        textureLock.lock()
        let shouldSchedule = !displayUpdateScheduled
        if shouldSchedule { displayUpdateScheduled = true }
        textureLock.unlock()
        guard shouldSchedule else { return }
        enqueueDisplayUpdate()
    }

    private func enqueueDisplayUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textureLock.lock()
            let width = self.drawableWidth
            let height = self.drawableHeight
            self.displayUpdateScheduled = false
            self.textureLock.unlock()

            let drawableSize = CGSize(width: width, height: height)
            if self.view.drawableSize != drawableSize { self.view.drawableSize = drawableSize }
            self.view.setNeedsDisplay()
        }
    }

    func submit(frame: Data, width frameWidth: Int, height frameHeight: Int,
                dirtyRegion: GPUFrameRegion?, sessionGeneration frameSessionGeneration: UInt64) {
        guard frameWidth > 0, frameHeight > 0,
              frameWidth <= 8192, frameHeight <= 8192,
              frameWidth <= maxFramebufferBytes / frameHeight / 4,
              frame.count >= frameWidth * frameHeight * 4,
              let device
        else {
            EmulationLog.shared.write("Metal framebuffer ignored: invalid dimensions or byte count")
            return
        }

        let fullRegion = GPUFrameRegion(x: 0, y: 0, width: frameWidth, height: frameHeight)
        let requestedRegion: GPUFrameRegion
        if let dirtyRegion,
           dirtyRegion.x >= 0, dirtyRegion.y >= 0,
           dirtyRegion.width > 0, dirtyRegion.height > 0,
           dirtyRegion.width <= frameWidth, dirtyRegion.height <= frameHeight,
           dirtyRegion.x <= frameWidth - dirtyRegion.width,
           dirtyRegion.y <= frameHeight - dirtyRegion.height {
            requestedRegion = dirtyRegion
        } else {
            requestedRegion = fullRegion
        }

        textureLock.lock()
        guard frameSessionGeneration == sessionGeneration else {
            textureLock.unlock()
            return
        }
        if framebufferWidth != frameWidth || framebufferHeight != frameHeight {
            framebufferGeneration &+= 1
            framebufferSlots.removeAll(keepingCapacity: true)
            framebuffer = nil
            nextFrameSequence = 0
            publishedFrameSequence = 0
            pendingFullFrame = nil
            requiresFullFrameUpload = true
            framebufferWidth = frameWidth
            framebufferHeight = frameHeight
        }

        let frameByteCount = frameWidth * frameHeight * 4
        let slotLimit = max(2, min(maxFramebufferSlots, maxFramebufferPoolBytes / frameByteCount))
        nextFrameSequence &+= 1
        let sequence = nextFrameSequence
        let generation = framebufferGeneration
        let slot: FramebufferSlot
        let updatesPublishedSlot: Bool
        if let current = framebuffer, current.readers == 0, !current.isUploading {
            slot = current
            updatesPublishedSlot = true
        } else if let reusable = framebufferSlots.first(where: {
            $0 !== framebuffer && $0.readers == 0 && !$0.isUploading
        }) {
            slot = reusable
            updatesPublishedSlot = false
        } else if framebufferSlots.count < slotLimit,
                  let texture = makeTexture(device: device, width: frameWidth, height: frameHeight) {
            slot = FramebufferSlot(texture: texture)
            framebufferSlots.append(slot)
            updatesPublishedSlot = false
        } else {
            // Keep only the newest complete snapshot while every texture is busy.
            pendingFullFrame = PendingFrame(data: frame, width: frameWidth, height: frameHeight,
                                            sequence: sequence, generation: generation,
                                            sessionGeneration: frameSessionGeneration)
            requiresFullFrameUpload = true
            textureLock.unlock()
            return
        }
        let requiresFullUpload = requiresFullFrameUpload || pendingFullFrame != nil || !updatesPublishedSlot
        pendingFullFrame = nil
        slot.isUploading = true
        textureLock.unlock()

        // Any dropped update invalidates partial-copy assumptions until a full
        // snapshot has been published again.
        let uploadRegion = requiresFullUpload ? fullRegion : requestedRegion
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let byteOffset = uploadRegion.y * frameWidth * 4 + uploadRegion.x * 4
            slot.texture.replace(
                region: MTLRegionMake2D(uploadRegion.x, uploadRegion.y,
                                        uploadRegion.width, uploadRegion.height),
                mipmapLevel: 0,
                withBytes: base.advanced(by: byteOffset),
                bytesPerRow: frameWidth * 4
            )
        }

        textureLock.lock()
        slot.isUploading = false
        let publish = generation == framebufferGeneration
            && frameSessionGeneration == sessionGeneration
            && sequence >= publishedFrameSequence
            && framebufferSlots.contains(where: { $0 === slot })
        if publish {
            framebuffer = slot
            publishedFrameSequence = sequence
            drawableWidth = frameWidth
            drawableHeight = frameHeight
            if sequence == nextFrameSequence && pendingFullFrame == nil {
                requiresFullFrameUpload = false
            }
        }
        let shouldSchedule = publish && !displayUpdateScheduled
        if shouldSchedule { displayUpdateScheduled = true }
        let shouldDrainPending = pendingFullFrame != nil
        textureLock.unlock()

        if shouldSchedule { enqueueDisplayUpdate() }
        if shouldDrainPending { schedulePendingFrameDrain() }
    }

    private func release(_ slot: FramebufferSlot) {
        textureLock.lock()
        slot.readers = max(0, slot.readers - 1)
        let shouldDrainPending = pendingFullFrame != nil
        textureLock.unlock()
        if shouldDrainPending { schedulePendingFrameDrain() }
    }

    private func schedulePendingFrameDrain() {
        textureLock.lock()
        guard pendingFullFrame != nil, !pendingFrameDrainScheduled else {
            textureLock.unlock()
            return
        }
        pendingFrameDrainScheduled = true
        textureLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.drainPendingFrame()
        }
    }

    private func drainPendingFrame() {
        guard let device else {
            textureLock.lock()
            pendingFrameDrainScheduled = false
            textureLock.unlock()
            return
        }

        textureLock.lock()
        guard let pending = pendingFullFrame else {
            pendingFrameDrainScheduled = false
            textureLock.unlock()
            return
        }
        guard pending.generation == framebufferGeneration,
              pending.sessionGeneration == sessionGeneration,
              pending.width == framebufferWidth,
              pending.height == framebufferHeight else {
            pendingFullFrame = nil
            pendingFrameDrainScheduled = false
            textureLock.unlock()
            return
        }

        let frameByteCount = pending.width * pending.height * 4
        let slotLimit = max(2, min(maxFramebufferSlots, maxFramebufferPoolBytes / frameByteCount))
        let slot: FramebufferSlot
        if let current = framebuffer, current.readers == 0, !current.isUploading {
            slot = current
        } else if let reusable = framebufferSlots.first(where: {
            $0 !== framebuffer && $0.readers == 0 && !$0.isUploading
        }) {
            slot = reusable
        } else if framebufferSlots.count < slotLimit,
                  let texture = makeTexture(device: device, width: pending.width, height: pending.height) {
            slot = FramebufferSlot(texture: texture)
            framebufferSlots.append(slot)
        } else {
            pendingFrameDrainScheduled = false
            textureLock.unlock()
            return
        }

        pendingFullFrame = nil
        slot.isUploading = true
        textureLock.unlock()

        let fullRegion = GPUFrameRegion(x: 0, y: 0, width: pending.width, height: pending.height)
        pending.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            slot.texture.replace(
                region: MTLRegionMake2D(0, 0, fullRegion.width, fullRegion.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: pending.width * 4
            )
        }

        textureLock.lock()
        slot.isUploading = false
        let publish = pending.generation == framebufferGeneration
            && pending.sessionGeneration == sessionGeneration
            && pending.sequence >= publishedFrameSequence
            && framebufferSlots.contains(where: { $0 === slot })
        if publish {
            framebuffer = slot
            publishedFrameSequence = pending.sequence
            drawableWidth = pending.width
            drawableHeight = pending.height
            if pending.sequence == nextFrameSequence && pendingFullFrame == nil {
                requiresFullFrameUpload = false
            }
        }
        let shouldSchedule = publish && !displayUpdateScheduled
        if shouldSchedule { displayUpdateScheduled = true }
        let shouldDrainPending = pendingFullFrame != nil
        pendingFrameDrainScheduled = false
        textureLock.unlock()

        if shouldSchedule { enqueueDisplayUpdate() }
        if shouldDrainPending { schedulePendingFrameDrain() }
    }

    private func makeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }
}

extension MetalGPUBackend: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue else { return }

        textureLock.lock()
        let source: FramebufferSlot?
        let isUploading = framebuffer?.isUploading ?? false
        let drawSessionGeneration = sessionGeneration
        let drawFramebufferGeneration = framebufferGeneration
        if let current = framebuffer, !isUploading {
            current.readers += 1
            source = current
        } else {
            source = nil
        }
        textureLock.unlock()
        if isUploading { return }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else {
            if let source { release(source) }
            return
        }

        if let source {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                release(source)
                return
            }
            guard source.texture.width == drawable.texture.width,
                  source.texture.height == drawable.texture.height else {
                blit.endEncoding()
                release(source)
                return
            }
            blit.copy(from: source.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: source.texture.width, height: source.texture.height, depth: 1),
                to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            commandBuffer.addCompletedHandler { [weak self, source] _ in self?.release(source) }
        } else {
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.endEncoding()
        }

        if let source {
            // Recheck at the final consumer, after encoding but immediately before
            // enqueueing presentation. Session replacement invalidates queued work.
            textureLock.lock()
            let isCurrent = drawSessionGeneration == sessionGeneration
                && drawFramebufferGeneration == framebufferGeneration
                && framebuffer === source
            if isCurrent {
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
            textureLock.unlock()
            if !isCurrent {
                release(source)
                return
            }
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
