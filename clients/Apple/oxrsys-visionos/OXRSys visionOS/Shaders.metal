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
    constant VideoColorParams &colorParams [[buffer(1)]]
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

    float eyeOffset = in.eyeIndex * 0.5;
    float2 stereoUV = float2(eyeUV.x * 0.5 + eyeOffset, eyeUV.y);

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
