#include <metal_stdlib>
using namespace metal;

// Keep these structs byte-identical with Render/Instances.swift.

struct QuadInstance {
    float2 origin;
    float2 size;
    float4 radii;        // (topLeft, topRight, bottomRight, bottomLeft)
    float4 fill;         // straight-alpha sRGB
    float4 fill2;
    float2 gradientDir;
    float  borderWidth;
    float  cornerExponent;
    float4 borderColor;
    uint   flags;
    uint   _pad0;
    uint   _pad1;
    uint   _pad2;
};

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float4 color;
    uint   flags;
    uint   _pad0;
    uint   _pad1;
    uint   _pad2;
};

struct Uniforms {
    float2 viewportSize;
};

constant uint kQuadFlagGradient   = 1u << 0;
constant uint kQuadFlagGlass      = 1u << 1;
constant uint kGlyphFlagColor     = 1u << 0;

// Vertex-pulled unit quad: vid 0..3 as a triangle strip.
static inline float2 unit_corner(uint vid) {
    return float2(float(vid & 1u), float((vid >> 1u) & 1u));
}

static inline float4 to_clip(float2 pixel, float2 viewport) {
    // Top-left-origin pixels -> NDC (y flipped).
    float2 ndc = pixel / viewport * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

// ---------------------------------------------------------------- quads

struct QuadVOut {
    float4 position [[position]];
    float2 local;        // pixel coords centered on the quad
    float2 halfSize;
    float2 uv;           // 0..1 across the quad
    float4 radii;
    float4 fill;
    float4 fill2;
    float2 gradientDir;
    float  borderWidth;
    float4 borderColor;
    uint   flags;
};

vertex QuadVOut quad_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device QuadInstance *instances [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    QuadInstance q = instances[iid];
    float2 corner = unit_corner(vid);
    float2 pixel = q.origin + corner * q.size;

    QuadVOut out;
    out.position = to_clip(pixel, uniforms.viewportSize);
    out.local = (corner - 0.5) * q.size;
    out.halfSize = q.size * 0.5;
    out.uv = corner;
    out.radii = q.radii;
    out.fill = q.fill;
    out.fill2 = q.fill2;
    out.gradientDir = q.gradientDir;
    out.borderWidth = q.borderWidth;
    out.borderColor = q.borderColor;
    out.flags = q.flags;
    return out;
}

// Analytic per-corner rounded-box SDF. p is centered, y-down.
static inline float sd_rounded_box(float2 p, float2 halfSize, float4 radii) {
    // radii = (topLeft, topRight, bottomRight, bottomLeft); top = negative y.
    float r = p.x > 0.0
        ? (p.y > 0.0 ? radii.z : radii.y)
        : (p.y > 0.0 ? radii.w : radii.x);
    r = min(r, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

fragment float4 quad_fragment(QuadVOut in [[stage_in]]) {
    float d = sd_rounded_box(in.local, in.halfSize, in.radii);
    float aa = max(fwidth(d), 1e-4);

    float outer = 1.0 - smoothstep(-aa, aa, d);
    float inner = (in.borderWidth > 0.0)
        ? 1.0 - smoothstep(-aa, aa, d + in.borderWidth)
        : outer;

    float4 fill = in.fill;
    if (in.flags & kQuadFlagGradient) {
        float t = clamp(dot(in.uv - 0.5, in.gradientDir) + 0.5, 0.0, 1.0);
        fill = mix(in.fill, in.fill2, t);
    }

    // Premultiplied compositing: fill inside the border ring, border on the ring.
    float3 rgb = fill.rgb * fill.a * inner + in.borderColor.rgb * in.borderColor.a * (outer - inner);
    float alpha = fill.a * inner + in.borderColor.a * (outer - inner);

    if (in.flags & kQuadFlagGlass) {
        // Liquid-glass rim: the SDF's screen-space gradient is the surface
        // normal, so speculars wrap around corners like light bending through
        // curved glass (Tahoe's signature) instead of a flat top band.
        float2 grad = float2(dfdx(d), dfdy(d));
        float2 n = normalize(grad + float2(1e-5, 1e-5));

        float band = smoothstep(-3.0, -0.8, d) * outer;      // rim shell (~1.5pt)
        // Purely directional key light: a glint on the top arc that dies out
        // along the sides — a full-perimeter ring reads as an outline, not glass.
        float keySpec = pow(max(dot(n, normalize(float2(-0.25, -1.0))), 0.0), 3.0);
        float rimLight = band * 0.30 * keySpec;

        // Thickness: a whisper of glow just inside the rim.
        float innerGlow = max((smoothstep(-10.0, -2.5, d) - band), 0.0) * 0.03 * outer;

        // Gentle top-lit sheen across the body, in composed space so it
        // reads even at near-clear fills.
        float sheen = max((0.5 - in.uv.y) * 0.025, 0.0) * outer;
        // Glass presence follows the fill: a transparent pill (hover fade-out,
        // invisible-until-hover items) must show no rim/backdrop ghost.
        float presence = smoothstep(0.0, 0.06, fill.a);
        float light = (rimLight + innerGlow + sheen) * presence;
        rgb = clamp(rgb + float3(light), 0.0, 1.0);
        alpha = clamp(alpha + light * 0.85, 0.0, 1.0);
    }
    return float4(rgb, alpha);
}

// ---------------------------------------------------------------- shapes

// Raw CPU-tessellated triangles (graph fills and polylines).
struct ShapeVertexIn {
    float2 position;
    float2 _pad;
    float4 color;      // straight-alpha linear
};

struct ShapeVOut {
    float4 position [[position]];
    float4 color;
};

vertex ShapeVOut shape_vertex(
    uint vid [[vertex_id]],
    const device ShapeVertexIn *vertices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    ShapeVertexIn v = vertices[vid];
    ShapeVOut out;
    out.position = to_clip(v.position, uniforms.viewportSize);
    out.color = v.color;
    return out;
}

fragment float4 shape_fragment(ShapeVOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

// ---------------------------------------------------------------- glyphs

struct GlyphVOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint   flags;
};

vertex GlyphVOut glyph_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device GlyphInstance *instances [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    GlyphInstance g = instances[iid];
    float2 corner = unit_corner(vid);
    float2 pixel = g.origin + corner * g.size;

    GlyphVOut out;
    out.position = to_clip(pixel, uniforms.viewportSize);
    out.uv = g.uvOrigin + corner * g.uvSize;
    out.color = g.color;
    out.flags = g.flags;
    return out;
}

fragment float4 glyph_fragment(
    GlyphVOut in [[stage_in]],
    texture2d<float> maskAtlas [[texture(0)]],
    texture2d<float> colorAtlas [[texture(1)]]
) {
    constexpr sampler atlasSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    if (in.flags & kGlyphFlagColor) {
        // Color page stores premultiplied BGRA (emoji, multicolor symbols).
        float4 texel = colorAtlas.sample(atlasSampler, in.uv);
        return texel * in.color.a;
    }
    float coverage = maskAtlas.sample(atlasSampler, in.uv).r;
    float alpha = coverage * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}
