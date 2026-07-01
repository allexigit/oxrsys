// SPDX-License-Identifier: MPL-2.0

//
//  Shaders.metal
//  OXRSys visionOS
//
//  Created by Yannick Comte on 21/03/2026.
//

#include <metal_stdlib>

using namespace metal;

// Per-eye asynchronous timewarp. The streamed frame was rendered for the head pose the server
// reports with it; every vsync we reproject it into the live head pose by rotating each output
// ray into the render-eye frame and resampling. This keeps the world locked to the head as it
// rotates (the same idea Quest Link / Virtual Desktop / ALVR use), with no tuning constants —
// only the eye's real FOV tangents and the rotation between the two head poses.
struct ReprojData {
    float3x3 rot;     // maps a current-eye ray direction into render-eye space (R_render^-1 * R_current)
    float4 tangents;  // (left, right, up, down) positive tangent magnitudes for this eye
};

struct VideoColorParams {
    float4 range; // luma offset, luma scale, chroma center, chroma scale
};

// Foveated-encoding (AADT) parameters. `enabled == 0` is an exact passthrough, so this is inert
// unless the server is actually sending a foveated stream.
struct FoveationParams {
    uint enabled;
    uint _pad;
    float2 centerSize;
    float2 centerShift;
    float2 edgeRatio;
    float2 eyeSizeRatio; // foveated content fraction of the encoded eye region per axis
};

// ALVR axis-aligned foveated-encoding inverse mapping (MIT licensed). `compressAxis` maps an
// encoded (foveated) eye-UV to the displayed eye-UV the server warped it from; `decompressAxis`
// inverts it by bisection so each output pixel fetches the correct encoded texel. Matches the
// Quest client's AADT transform so the un-warp lines up with the server's encoded layout.
static float compressAxis(float eyeUv, float centerSize, float centerShift, float edgeRatio) {
    float c0 = (1.0 - centerSize) * 0.5;
    float c1 = (edgeRatio - 1.0) * c0 * (centerShift + 1.0) / edgeRatio;
    float c2 = (edgeRatio - 1.0) * centerSize + 1.0;
    float loBound = c0 * (centerShift + 1.0) / c2;
    float hiBound = c0 * (centerShift - 1.0) / c2 + 1.0;
    float center = eyeUv * c2 / edgeRatio + c1;
    float d2 = eyeUv * c2;
    float d3 = (eyeUv - 1.0) * c2 + 1.0;
    float g1 = loBound > 0.0 ? eyeUv / loBound : 1.0;
    float g2 = (1.0 - hiBound) > 0.0 ? (1.0 - eyeUv) / (1.0 - hiBound) : 1.0;
    float leftEdge = g1 * center + (1.0 - g1) * d2;
    float rightEdge = g2 * center + (1.0 - g2) * d3;
    if (eyeUv < loBound) { return leftEdge; }
    if (eyeUv > hiBound) { return rightEdge; }
    return center;
}

static float decompressAxis(float targetUv, float centerSize, float centerShift, float edgeRatio) {
    float lo = 0.0;
    float hi = 1.0;
    for (int i = 0; i < 10; ++i) {
        float mid = (lo + hi) * 0.5;
        float mapped = compressAxis(mid, centerSize, centerShift, edgeRatio);
        if (mapped < targetUv) { lo = mid; } else { hi = mid; }
    }
    return (lo + hi) * 0.5;
}

struct StereoVertexOut {
    float4 position [[position]];
    float2 texCoord; // output-view screen position in [0,1] for this eye
    float eyeIndex;
};

vertex StereoVertexOut stereoImmersiveVertex(uint vertexID [[vertex_id]],
                                             ushort amp_id [[amplification_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };

    StereoVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    out.eyeIndex = float(amp_id);
    return out;
}

fragment float4 stereoImmersiveFragment(
    StereoVertexOut in [[stage_in]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]],
    constant ReprojData *reproj [[buffer(0)]],
    constant VideoColorParams &colorParams [[buffer(1)]],
    constant FoveationParams &fov [[buffer(2)]]
) {
    constexpr sampler textureSampler(address::clamp_to_edge,
                                     mag_filter::linear,
                                     min_filter::linear);

    if (!lumaTexture.get_width() || !chromaTexture.get_width()) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    ReprojData rd = reproj[uint(in.eyeIndex)];
    float left = rd.tangents.x;
    float right = rd.tangents.y;
    float up = rd.tangents.z;
    float down = rd.tangents.w;

    // Ray for this output fragment in the current eye's frustum, at the z = -1 plane.
    // texCoord.y = 0 is the top of the view (+up), texCoord.y = 1 the bottom (-down).
    float x = mix(-left, right, in.texCoord.x);
    float y = mix(up, -down, in.texCoord.y);
    float3 dirCurrent = float3(x, y, -1.0);

    // Rotate into the pose the server rendered this frame for, then reproject through the same
    // per-eye frustum to find the source texel. rot == identity → eyeUV == texCoord (exact
    // passthrough when the head has not moved since the frame was rendered).
    float3 dirRender = rd.rot * dirCurrent;
    float2 eyeUV = in.texCoord;
    if (dirRender.z < 0.0) {
        float zf = -dirRender.z;
        float xPlane = dirRender.x / zf;
        float yPlane = dirRender.y / zf;
        eyeUV = float2((xPlane + left) / (left + right),
                       (up - yPlane) / (up + down));
    }

    // Undo the server's foveated-encoding warp (passthrough when fov.enabled == 0): map this
    // displayed eye-UV back to the encoded texel it came from, then scale by the foveated
    // content's fraction of the encoded eye region.
    float2 sourceUV = eyeUV;
    if (fov.enabled != 0) {
        float2 t = clamp(eyeUV, 0.0, 1.0);
        sourceUV.x = decompressAxis(t.x, fov.centerSize.x, fov.centerShift.x, fov.edgeRatio.x)
            * fov.eyeSizeRatio.x;
        sourceUV.y = decompressAxis(t.y, fov.centerSize.y, fov.centerShift.y, fov.edgeRatio.y)
            * fov.eyeSizeRatio.y;
        sourceUV = clamp(sourceUV, 0.0, 1.0);
    }

    float eyeOffset = in.eyeIndex * 0.5;
    float2 stereoUV = float2(sourceUV.x * 0.5 + eyeOffset, sourceUV.y);

    float yLuma = lumaTexture.sample(textureSampler, stereoUV).r;
    float2 cbcr = chromaTexture.sample(textureSampler, stereoUV).rg;

    // The streaming contract is limited/video-range BT.709 SDR. Expand luma and chroma using
    // bit-depth-specific normalized code values supplied by the renderer, then convert to RGB.
    float luma = (yLuma - colorParams.range.x) * colorParams.range.y;
    float cb = (cbcr.x - colorParams.range.z) * colorParams.range.w;
    float cr = (cbcr.y - colorParams.range.z) * colorParams.range.w;
    float3 rgb = float3(luma + 1.5748 * cr,
                        luma - 0.1873 * cb - 0.4681 * cr,
                        luma + 1.8556 * cb);
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}
