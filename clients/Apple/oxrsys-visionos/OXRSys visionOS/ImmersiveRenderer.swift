// SPDX-License-Identifier: MPL-2.0

import ARKit
import CompositorServices
import CoreVideo
import Metal
import os
import simd

nonisolated private enum ImmersiveRendererConstants {
    // 2, not 3: the CompositorServices frame clock is the real pacer, so a third in-flight buffer
    // only lets the CPU drift an extra frame ahead — pure added latency (~1 frame, ~11 ms @ 90 Hz)
    // with no throughput gain for a video blit. Drop to 2 to shave that frame.
    static let maxBuffersInFlight = 2
}

extension LayerRenderer.Clock.Instant {
    nonisolated var timeInterval: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

final class ImmersiveRendererTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "oxr.visionos.immersive-render", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }

    static let shared = ImmersiveRendererTaskExecutor()
}

actor ImmersiveRenderer {
    private let layerRenderer: LayerRenderer
    private unowned let appModel: AppModel
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let worldTracking: WorldTrackingProvider
    private let textureCache: CVMetalTextureCache
    private let pipelineState: MTLRenderPipelineState
    private let endFrameEvent: MTLSharedEvent

    private var committedFrameIndex: UInt64 = UInt64(ImmersiveRendererConstants.maxBuffersInFlight)
    private var didLogProjection = false

    /// Per-eye reprojection data for the fragment shader: the rotation from the current-eye frame
    /// into the render-eye frame, plus that eye's frustum tangents.
    struct ReprojData {
        var rot: simd_float3x3       // current-eye → render-eye rotation (R_render⁻¹ · R_current)
        var tangents: SIMD4<Float>   // (left, right, up, down) positive tangent magnitudes
    }

    /// Normalized video-range conversion constants consumed by the Metal shader:
    /// (luma offset, luma scale, chroma center, chroma scale).
    struct VideoColorParams {
        var range: SIMD4<Float>
    }

    /// Display-space post-processing parameters (sharpening). Layout matches Metal `PostFXParams`.
    struct PostFXParams {
        var invResolution: SIMD2<Float> = .zero // 1 / per-eye output pixels
        var sharpen: Float = 0                  // 0 = off
        var pad: Float = 0
    }

    init(layerRenderer: LayerRenderer, appModel: AppModel, worldTracking: WorldTrackingProvider) {
        self.layerRenderer = layerRenderer
        self.appModel = appModel
        self.worldTracking = worldTracking
        self.device = layerRenderer.device
        self.commandQueue = layerRenderer.device.makeCommandQueue()!

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache!

        let library = device.makeDefaultLibrary()!
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VisionStereoPipeline"
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "stereoImmersiveVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "stereoImmersiveFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        self.pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        self.endFrameEvent = device.makeSharedEvent()!
        self.endFrameEvent.signaledValue = committedFrameIndex
    }

    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel, worldTracking: WorldTrackingProvider) {
        Task(executorPreference: ImmersiveRendererTaskExecutor.shared) {
            let renderer = ImmersiveRenderer(layerRenderer: layerRenderer, appModel: appModel, worldTracking: worldTracking)
            await renderer.renderLoop()
        }
    }

    private func renderLoop() async {
        while true {
            if layerRenderer.state == .invalidated {
                await MainActor.run {
                    appModel.immersiveSpaceDidClose()
                }
                return
            }

            if layerRenderer.state == .paused {
                await MainActor.run {
                    appModel.immersiveSpaceState = .inTransition
                }
                layerRenderer.waitUntilRunning()
                continue
            }

            autoreleasepool {
                renderFrame()
            }
        }
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }
        guard endFrameEvent.wait(
            untilSignaledValue: committedFrameIndex - UInt64(ImmersiveRendererConstants.maxBuffersInFlight),
            timeoutMS: 10_000
        ) else {
            return
        }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        frame.startSubmission()
        for drawable in drawables {
            render(drawable: drawable, commandBuffer: commandBuffer)
        }

        committedFrameIndex += 1
        commandBuffer.encodeSignalEvent(endFrameEvent, value: committedFrameIndex)
        commandBuffer.commit()
        frame.endSubmission()
    }

    private func render(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        let presentationTime = drawable.frameTiming.presentationTime.timeInterval
        let currentAnchor = worldTracking.queryDeviceAnchor(atTimestamp: presentationTime)
        drawable.deviceAnchor = currentAnchor

        publishEyeProjection(drawable)

        // Pair the displayed frame with the render pose it was drawn for, and reproject it into
        // the live head pose. The compositor still does its small predicted→actual pass via
        // deviceAnchor; this handles the larger render-pose→now rotation.
        let frame = appModel.currentFrame()
        let currentOrientation = currentAnchor.map { headOrientation(from: $0) }
        let renderOrientation = appModel.renderOrientation(forPresentationTimeNs: frame.presentationTimeNs)
        var reprojData = reprojectionData(drawable: drawable,
                                          currentOrientation: currentOrientation,
                                          renderOrientation: renderOrientation)

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // visionOS reprojects each presented frame using the depth buffer; with no valid depth
        // the device drops every frame (black) while the simulator does not. Clear the depth to
        // a fixed head-locked distance so the compositor has a real surface to reproject.
        let clip = drawable.computeProjection(viewIndex: 0) * SIMD4<Float>(0, 0, -2.0, 1)
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = clip.w != 0 ? Double(clip.z / clip.w) : 0
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.label = "Vision Stereo Encoder"
        encoder.setRenderPipelineState(pipelineState)

        let viewports = drawable.views.map { $0.textureMap.viewport }
        encoder.setViewports(viewports)

        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            encoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        encoder.setFragmentBytes(&reprojData, length: MemoryLayout<ReprojData>.stride * reprojData.count, index: 0)

        // Bind color params unconditionally (default 8-bit) so the fragment shader never reads an
        // unbound buffer(1) on frames that draw before the first decoded pixel buffer arrives.
        var colorParams = VideoColorParams(range: SIMD4<Float>(16.0 / 255.0, 255.0 / 219.0,
                                                               128.0 / 255.0, 255.0 / 224.0))
        if let pixelBuffer = frame.pixelBuffer {
            let is10Bit = CVPixelBufferGetPixelFormatType(pixelBuffer) ==
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            if is10Bit {
                // 10-bit bi-planar samples occupy the high 10 bits of each 16-bit Metal channel.
                // Use their exact normalized code values instead of approximating them as 8-bit.
                colorParams.range = SIMD4<Float>(4096.0 / 65535.0, 65535.0 / 56064.0,
                                                 32768.0 / 65535.0, 65535.0 / 57344.0)
            }
            let lumaFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
            let chromaFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm
            if let luma = makeTexture(from: pixelBuffer, plane: 0, format: lumaFormat),
               let chroma = makeTexture(from: pixelBuffer, plane: 1, format: chromaFormat) {
                encoder.setFragmentTexture(luma, index: 0)
                encoder.setFragmentTexture(chroma, index: 1)
            }
        }
        encoder.setFragmentBytes(&colorParams,
                                 length: MemoryLayout<VideoColorParams>.stride,
                                 index: 1)

        // Foveation inverse-warp params (passthrough unless the server is foveating). Static per
        // connection; bound every frame so the shader's buffer(2) is always populated.
        var fovParams = appModel.foveationParams()
        encoder.setFragmentBytes(&fovParams,
                                 length: MemoryLayout<FoveationShaderParams>.stride,
                                 index: 2)

        // Post-process (contrast-adaptive sharpening). invResolution is the per-eye output texel
        // size so the shader can sample neighbours in display space; sharpen == 0 is a passthrough.
        let invResolution = viewports.first.map {
            SIMD2<Float>(1.0 / Float(max($0.width, 1)), 1.0 / Float(max($0.height, 1)))
        } ?? SIMD2<Float>(0, 0)
        var postfx = PostFXParams(invResolution: invResolution, sharpen: appModel.sharpenStrength())
        encoder.setFragmentBytes(&postfx,
                                 length: MemoryLayout<PostFXParams>.stride,
                                 index: 3)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        drawable.encodePresent(commandBuffer: commandBuffer)
    }

    /// Builds per-eye reprojection data: the rotation mapping a current-eye ray into the render
    /// pose's eye frame, plus that eye's frustum tangents. Identity rotation (no render pose yet,
    /// or no head motion since the frame was rendered) is an exact passthrough.
    private func reprojectionData(drawable: LayerRenderer.Drawable,
                                  currentOrientation: simd_quatf?,
                                  renderOrientation: simd_quatf?) -> [ReprojData] {
        let viewCount = max(drawable.views.count, 1)
        var data: [ReprojData] = (0..<viewCount).map { index in
            let tangents = index < drawable.views.count
                ? drawable.views[index].tangents
                : SIMD4<Float>(1, 1, 1, 1)
            return ReprojData(rot: matrix_identity_float3x3, tangents: tangents)
        }

        guard let currentOrientation, let renderOrientation else {
            return data
        }

        // dir_render = (R_render⁻¹ · R_current) · dir_current, so the shader finds which texel of
        // the server-rendered frame each live output ray maps to.
        let rot = simd_float3x3(simd_normalize(renderOrientation.inverse * currentOrientation))
        for index in data.indices {
            data[index].rot = rot
        }
        return data
    }

    /// Head orientation (world-from-head) from a device anchor's transform.
    private func headOrientation(from anchor: DeviceAnchor) -> simd_quatf {
        let m = anchor.originFromAnchorTransform
        return simd_quatf(simd_float3x3(
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        ))
    }

    /// Sends the device's real per-eye FOV (radians, OpenXR signed angles) and IPD so the
    /// runtime renders the matching frustum instead of its symmetric fallback FOV. visionOS
    /// view tangents are positive magnitudes in (left, right, up, down) order, so negate the
    /// left and down components to produce OpenXR's signed XrFovf angles.
    private func publishEyeProjection(_ drawable: LayerRenderer.Drawable) {
        guard let leftView = drawable.views.first else { return }
        let t = leftView.tangents
        let fovAngles = SIMD4<Float>(-atan(t.x), atan(t.y), atan(t.z), -atan(t.w))

        let leftEye = leftView.transform.columns.3
        let rightEye = (drawable.views.count > 1 ? drawable.views[1] : leftView).transform.columns.3
        let dx = rightEye.x - leftEye.x, dy = rightEye.y - leftEye.y, dz = rightEye.z - leftEye.z
        let ipd = (dx * dx + dy * dy + dz * dz).squareRoot()

        if !didLogProjection {
            didLogProjection = true
            print("[ProjDiag] L.tangents=(\(t.x), \(t.y), \(t.z), \(t.w))")
            if drawable.views.count > 1 {
                let rt = drawable.views[1].tangents
                print("[ProjDiag] R.tangents=(\(rt.x), \(rt.y), \(rt.z), \(rt.w))")
            }
            print("[ProjDiag] fovAngles(rad)=(\(fovAngles.x), \(fovAngles.y), \(fovAngles.z), \(fovAngles.w)) ipd=\(ipd)")
        }

        appModel.updateEyeProjection(fovAngles: fovAngles, ipd: ipd)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            plane,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
