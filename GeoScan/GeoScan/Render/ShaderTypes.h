//
//  ShaderTypes.h
//  Types shared between Swift, C and the Metal shading language.
//
//  Every struct in here is laid out with explicit scalars or SIMD types whose
//  size/alignment rules are identical in C and MSL, so the same memory can be
//  written by Swift and read by a shader without a translation step.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// MARK: - Buffer / texture indices

typedef enum GSBufferIndex {
    GSBufferIndexPoints          = 0,
    GSBufferIndexUnprojectUniforms = 1,
    GSBufferIndexRenderUniforms  = 2,
    GSBufferIndexPointCount      = 3
} GSBufferIndex;

typedef enum GSTextureIndex {
    GSTextureIndexY          = 0,
    GSTextureIndexCbCr       = 1,
    GSTextureIndexDepth      = 2,
    GSTextureIndexConfidence = 3
} GSTextureIndex;

typedef enum GSColorMode {
    GSColorModeRGB        = 0,   // photographic colour from the wide camera
    GSColorModeConfidence = 1,   // LiDAR confidence heat map
    GSColorModeHeight     = 2,   // elevation ramp (metres, ENU up axis)
    GSColorModeIntensity  = 3    // luma only, for geometry inspection
} GSColorMode;

// MARK: - Point record
//
// 16 bytes. Deliberately built from plain scalars rather than a float3 so that
// the layout is identical in C, Swift and MSL, and so that a 10M point cloud
// costs 160 MB rather than the 480 MB a naive {float3, float3, float} costs.
//
// Position is in *AR world space* (metres, gravity aligned, +Y up). The
// conversion to ENU / geodetic coordinates happens at export time using the
// GeoSolution, so a scan can be re-georeferenced after the fact.
typedef struct {
    float x;
    float y;
    float z;
    unsigned char r;
    unsigned char g;
    unsigned char b;
    unsigned char confidence;   // 0 = low, 1 = medium, 2 = high (ARConfidenceLevel)
} GSPoint;

// MARK: - Uniforms

typedef struct {
    matrix_float4x4 localToWorld;          // camera.transform * diag(1, -1, -1, 1)
    matrix_float3x3 depthIntrinsicsInverse; // inverse intrinsics at depth-map resolution
    vector_float2   depthResolution;
    float           minRange;
    float           maxRange;
    unsigned int    minConfidence;
    unsigned int    capacity;
    unsigned int    sampleStride;          // 1 = every depth pixel, 2 = every other, ...
    float           _pad;
} GSUnprojectUniforms;

typedef struct {
    matrix_float4x4 viewProjection;
    vector_float3   cameraPosition;
    float           pointSize;             // in points, at 1 m distance
    float           minConfidence;
    float           colorMode;             // GSColorMode as a float
    float           heightMin;
    float           heightMax;
} GSRenderUniforms;

#endif /* ShaderTypes_h */
