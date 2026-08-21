//
//  Shaders.metal
//
//  Three pipelines:
//    1. cameraBackground* — draws the wide-camera feed behind the point cloud.
//    2. unprojectKernel   — LiDAR depth map -> colourised world-space points.
//    3. pointCloud*       — renders accumulated points as round sprites.
//
//  Measurement lines, labels and photo pins are *not* drawn here; they are
//  projected to screen space and drawn by SwiftUI so that they stay crisp and
//  hit-testable.
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

// ARKit delivers full-range YCbCr (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange).
constant float4x4 kYCbCrToRGB = float4x4(
    float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
    float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
    float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
    float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));

static inline float3 ycbcrToRGB(texture2d<float> yTex,
                                texture2d<float> cbcrTex,
                                float2 uv) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 ycbcr = float4(yTex.sample(s, uv).r, cbcrTex.sample(s, uv).rg, 1.0);
    return saturate((kYCbCrToRGB * ycbcr).rgb);
}

// MARK: - Camera background

typedef struct {
    float4 position [[position]];
    float2 uv;
} BackgroundOut;

// Fullscreen triangle-strip quad. `uv` is pre-transformed on the CPU with
// ARFrame.displayTransform so the feed matches the interface orientation.
vertex BackgroundOut cameraBackgroundVertex(uint vid [[vertex_id]],
                                            constant float2 *uvs [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1.0, -1.0), float2(1.0, -1.0),
                                float2(-1.0,  1.0), float2(1.0,  1.0) };
    BackgroundOut out;
    out.position = float4(corners[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 cameraBackgroundFragment(BackgroundOut in [[stage_in]],
                                         texture2d<float> yTex [[texture(GSTextureIndexY)]],
                                         texture2d<float> cbcrTex [[texture(GSTextureIndexCbCr)]]) {
    return float4(ycbcrToRGB(yTex, cbcrTex, in.uv), 1.0);
}

// MARK: - Unprojection

// One thread per depth pixel. Reads the LiDAR depth map, rejects samples that
// fail the confidence/range gate, unprojects through the (depth-resolution)
// camera intrinsics and samples colour from the wide camera at the matching
// normalised coordinate — the depth map and the captured image share a field of
// view and aspect ratio, so normalised coordinates are directly comparable.
kernel void unprojectKernel(uint2 gid [[thread_position_in_grid]],
                            constant GSUnprojectUniforms &u [[buffer(GSBufferIndexUnprojectUniforms)]],
                            device GSPoint *points [[buffer(GSBufferIndexPoints)]],
                            device atomic_uint *pointCount [[buffer(GSBufferIndexPointCount)]],
                            texture2d<float, access::read> depthTex [[texture(GSTextureIndexDepth)]],
                            texture2d<uint, access::read> confidenceTex [[texture(GSTextureIndexConfidence)]],
                            texture2d<float> yTex [[texture(GSTextureIndexY)]],
                            texture2d<float> cbcrTex [[texture(GSTextureIndexCbCr)]]) {
    if (gid.x >= (uint)u.depthResolution.x || gid.y >= (uint)u.depthResolution.y) { return; }
    if ((gid.x % u.sampleStride) != 0 || (gid.y % u.sampleStride) != 0) { return; }

    const float depth = depthTex.read(gid).r;
    if (!isfinite(depth) || depth < u.minRange || depth > u.maxRange) { return; }

    const uint confidence = confidenceTex.read(gid).r;
    if (confidence < u.minConfidence) { return; }

    // Pinhole unprojection: +x right, +y down, +z forward (image convention).
    const float3 pixel = float3(float(gid.x) + 0.5, float(gid.y) + 0.5, 1.0);
    const float3 imageSpace = (u.depthIntrinsicsInverse * pixel) * depth;

    // ARKit camera space is +x right, +y up, -z forward. localToWorld already
    // carries the diag(1, -1, -1, 1) flip, so pass the image-space point through.
    const float4 world = u.localToWorld * float4(imageSpace, 1.0);

    const float2 uv = (float2(gid) + 0.5) / u.depthResolution;
    const float3 rgb = ycbcrToRGB(yTex, cbcrTex, uv);

    const uint index = atomic_fetch_add_explicit(pointCount, 1, memory_order_relaxed);
    if (index >= u.capacity) {
        // Buffer is full. Leave the counter saturated; the CPU notices and
        // either compacts the cloud with a voxel filter or stops accumulating.
        return;
    }

    device GSPoint &p = points[index];
    p.x = world.x;
    p.y = world.y;
    p.z = world.z;
    p.r = (unsigned char)(rgb.r * 255.0);
    p.g = (unsigned char)(rgb.g * 255.0);
    p.b = (unsigned char)(rgb.b * 255.0);
    p.confidence = (unsigned char)confidence;
}

// MARK: - Point cloud rendering

typedef struct {
    float4 position [[position]];
    float  pointSize [[point_size]];
    half3  color;
    half   alpha;
} PointOut;

static inline half3 confidenceRamp(uint c) {
    if (c >= 2) { return half3(0.20h, 0.85h, 0.40h); }
    if (c == 1) { return half3(0.98h, 0.75h, 0.20h); }
    return half3(0.90h, 0.28h, 0.28h);
}

// Blue -> cyan -> yellow -> red elevation ramp.
static inline half3 heightRamp(float t) {
    t = saturate(t);
    const float3 c0 = float3(0.16, 0.28, 0.72);
    const float3 c1 = float3(0.15, 0.75, 0.75);
    const float3 c2 = float3(0.95, 0.85, 0.25);
    const float3 c3 = float3(0.85, 0.22, 0.20);
    float3 rgb = (t < 0.333) ? mix(c0, c1, t / 0.333)
               : (t < 0.666) ? mix(c1, c2, (t - 0.333) / 0.333)
                             : mix(c2, c3, (t - 0.666) / 0.334);
    return half3(rgb);
}

vertex PointOut pointCloudVertex(uint vid [[vertex_id]],
                                 const device GSPoint *points [[buffer(GSBufferIndexPoints)]],
                                 constant GSRenderUniforms &u [[buffer(GSBufferIndexRenderUniforms)]]) {
    const GSPoint p = points[vid];
    PointOut out;

    if ((float)p.confidence < u.minConfidence) {
        // Cull by collapsing the sprite; cheaper than a second compaction pass.
        out.position = float4(0.0, 0.0, -10.0, 1.0);
        out.pointSize = 0.0;
        out.color = half3(0.0h);
        out.alpha = 0.0h;
        return out;
    }

    const float3 world = float3(p.x, p.y, p.z);
    out.position = u.viewProjection * float4(world, 1.0);

    // Keep sprites roughly constant in world size: shrink with distance, but
    // clamp so that far-field structure stays visible.
    const float distance = max(length(world - u.cameraPosition), 0.05);
    out.pointSize = clamp(u.pointSize / distance, 1.5, 32.0);

    const uint mode = (uint)u.colorMode;
    const half3 rgb = half3(half(p.r) / 255.0h, half(p.g) / 255.0h, half(p.b) / 255.0h);
    if (mode == GSColorModeConfidence) {
        out.color = confidenceRamp(p.confidence);
    } else if (mode == GSColorModeHeight) {
        const float span = max(u.heightMax - u.heightMin, 0.001);
        out.color = heightRamp((world.y - u.heightMin) / span);
    } else if (mode == GSColorModeIntensity) {
        const half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
        out.color = half3(luma);
    } else {
        out.color = rgb;
    }
    out.alpha = 1.0h;
    return out;
}

fragment half4 pointCloudFragment(PointOut in [[stage_in]],
                                  float2 coord [[point_coord]]) {
    // Round sprite with a soft edge; square points read as noise at density.
    const float d = length(coord - float2(0.5));
    if (d > 0.5) { discard_fragment(); }
    const half edge = half(smoothstep(0.5, 0.36, d));
    return half4(in.color, in.alpha * edge);
}
