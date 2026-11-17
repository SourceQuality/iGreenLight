#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

// Full-screen triangle.
vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

struct YUVParams {
    float3x3 matrix;   // YCbCr -> RGB
    float3 offset;     // subtracted before the matrix
    float3 scale;      // range expansion
};

// NV12 / 420f / 420v -> RGB at source resolution.
fragment float4 nv12_fragment(VOut in [[stage_in]],
                              texture2d<float> yTex [[texture(0)]],
                              texture2d<float> uvTex [[texture(1)]],
                              constant YUVParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = yTex.sample(s, in.uv).r;
    float2 uv = uvTex.sample(s, in.uv).rg;
    float3 ycc = (float3(y, uv) - p.offset) * p.scale;
    return float4(saturate(p.matrix * ycc), 1.0);
}

// I420 (three planes) fallback.
fragment float4 i420_fragment(VOut in [[stage_in]],
                              texture2d<float> yTex [[texture(0)]],
                              texture2d<float> uTex [[texture(1)]],
                              texture2d<float> vTex [[texture(2)]],
                              constant YUVParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 ycc = (float3(yTex.sample(s, in.uv).r, uTex.sample(s, in.uv).r, vTex.sample(s, in.uv).r) - p.offset) * p.scale;
    return float4(saturate(p.matrix * ycc), 1.0);
}

struct PresentParams {
    float2 uvScale;    // maps drawable uv -> content uv
    float2 uvOffset;
};

// Draw the (upscaled) frame into the drawable with letterbox / zoom / stretch.
fragment float4 present_fragment(VOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant PresentParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float2 uv = in.uv * p.uvScale + p.uvOffset;
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);
    return float4(tex.sample(s, uv).rgb, 1.0);
}
