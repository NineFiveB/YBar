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
    float  fadeStart;
    float  fadeEnd;
    uint   _pad2;
};

struct Uniforms {
    float2 viewportSize;
    uint   holeCount;
    uint   _pad;
    float2 pointer;
};

struct Hole {
    float2 origin;
    float2 size;
    float  radius;
    float3 _pad;
};

constant uint kQuadFlagGradient = 1u << 0;
constant uint kQuadFlagGlass    = 1u << 1;
constant uint kQuadFlagArc      = 1u << 2;
constant uint kQuadFlagHoles    = 1u << 3;
constant uint kQuadFlagShadow   = 1u << 4;
constant uint kQuadFlagSheen    = 1u << 5;
constant uint kQuadFlagHot      = 1u << 6;
constant uint kQuadFlagNativeGlass = 1u << 7;
constant uint kGlyphFlagColor   = 1u << 0;
constant uint kGlyphFlagGrey    = 1u << 1;
constant uint kGlyphFlagFade    = 1u << 2;

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

fragment float4 quad_fragment(
    QuadVOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    const device Hole *holes [[buffer(2)]]
) {
    float d = sd_rounded_box(in.local, in.halfSize, in.radii);
    float aa = max(fwidth(d), 1e-4);
    // background.clip cutouts: multiply coverage by "outside every hole".
    float holeMask = 1.0;
    if (in.flags & kQuadFlagHoles) {
        for (uint i = 0; i < uniforms.holeCount; i++) {
            Hole hole = holes[i];
            float2 center = hole.origin + hole.size * 0.5;
            float hd = sd_rounded_box(in.position.xy - center, hole.size * 0.5,
                                      float4(hole.radius));
            holeMask = min(holeMask, smoothstep(-aa, aa, hd));
        }
    }

    // Soft falloff (drop shadow, or a glow when fill is light). The quad was
    // grown by the blur radius on the CPU side, so the SDF here must use the
    // TRUE shape half size from fill2.xy rather than the grown in.halfSize.
    // `aa` is reused deliberately: it is computed before any branch, and the
    // screen-space derivative of the two distances differs only by a constant
    // shape offset, so taking fwidth() inside this branch would risk divergent
    // derivatives for no accuracy gained.
    if (in.flags & kQuadFlagShadow) {
        float sd = sd_rounded_box(in.local, in.fill2.xy, in.radii);
        float blur = max(in.gradientDir.x, aa);
        float cov = clamp(1.0 - smoothstep(-blur, blur, sd), 0.0, 1.0);
        cov *= cov; // a squared ramp sits much closer to a gaussian than linear
        return float4(in.fill.rgb * in.fill.a * cov, in.fill.a * cov) * holeMask;
    }

    if (in.flags & kQuadFlagArc) {
        // Speedometer gauge: a 270-degree ring open at the bottom, filling
        // clockwise from the lower-left. The quad is a circle (radius =
        // halfSize); ring band = borderWidth; progress (0..1) rides in
        // gradientDir.x; borderColor = progress arc, fill = track.
        float ringOuter = 1.0 - smoothstep(-aa, aa, d);
        float ringInner = 1.0 - smoothstep(-aa, aa, d + in.borderWidth);
        float ring = max(ringOuter - ringInner, 0.0);

        float deg = atan2(-in.local.y, in.local.x) * 57.29577951;
        float a = (deg <= -135.0) ? deg + 360.0 : deg;   // (-135, 225]
        float t = (225.0 - a) / 270.0;                    // 0 at start, 1 at end
        if (t < 0.0 || t > 1.0) {
            return float4(0.0);                           // bottom gap
        }
        float4 c = (t <= in.gradientDir.x) ? in.borderColor : in.fill;
        return float4(c.rgb * c.a * ring, c.a * ring);
    }

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
        // Dispersion: the shell is sampled at a slightly different distance
        // per channel, so red rides a touch outside the edge and blue a touch
        // inside. Where the three agree the fringe cancels and the rim stays
        // white; only the boundary splits, which is what the eye reads as a
        // lens rather than a lit outline. Under a point the separation is
        // well under a pixel, so it colours the edge without tinting the pill.
        const float dispersion = 0.75;                        // device px
        float3 shell = float3(smoothstep(-3.0, -0.8, d + dispersion),
                              band / max(outer, 1e-5),
                              smoothstep(-3.0, -0.8, d - dispersion)) * outer;
        float3 rimLight = shell * 0.30 * keySpec;

        // Thickness: a whisper of glow just inside the rim.
        float innerGlow = max((smoothstep(-10.0, -2.5, d) - band), 0.0) * 0.03 * outer;

        // Gentle top-lit sheen across the body, in composed space so it
        // reads even at near-clear fills.
        float sheen = max((0.5 - in.uv.y) * 0.025, 0.0) * outer;
        // Glass presence follows the fill: a transparent pill (hover fade-out,
        // invisible-until-hover items) must show no rim/backdrop ghost.
        float presence = smoothstep(0.0, 0.06, fill.a);
        float3 light = (rimLight + innerGlow + sheen) * presence;
        rgb = clamp(rgb + light, 0.0, 1.0);
        // Alpha follows the achromatic part: the fringe colours the edge, it
        // does not make it more opaque on one side than the other.
        alpha = clamp(alpha + dot(light, float3(1.0 / 3.0)) * 0.85, 0.0, 1.0);
    }

    // Per-pill depth on top of (possibly inactive) system glass: top lip,
    // bottom shade, and a specular only while the pointer is inside this
    // capsule — never a light shared across neighboring pills.
    if (in.flags & kQuadFlagSheen) {
        float2 size = max(in.halfSize * 2.0, float2(1.0));
        float2 origin = in.position.xy - in.uv * size;
        float2 puv = (uniforms.pointer - origin) / size;
        bool over = puv.x >= 0.0 && puv.x <= 1.0 && puv.y >= 0.0 && puv.y <= 1.0;
        bool hot = over || (in.flags & kQuadFlagHot) != 0u;
        // Near-clear fills (inactive-glass compensation) still need a floor
        // so lip/shade read as depth without a dark Metal slab.
        float presence = max(smoothstep(0.0, 0.06, max(fill.a, alpha)), 0.75);

        // With the system material underneath, the body is already modelled:
        // paint the edge and nothing else. The bottom shade especially has to
        // go — under a real glass capsule it reads as a drop shadow, which
        // Liquid Glass does not cast inside itself.
        bool bodyIsOurs = (in.flags & kQuadFlagNativeGlass) == 0u;
        float topLip = bodyIsOurs
            ? smoothstep(0.28, 0.0, in.uv.y) * outer * 0.42 * presence
            : smoothstep(0.20, 0.0, in.uv.y) * outer * 0.16 * presence;
        float bottomShade = bodyIsOurs
            ? smoothstep(0.62, 1.0, in.uv.y) * outer * 0.32 * presence
            : 0.0;
        float2 grad = float2(dfdx(d), dfdy(d));
        float2 n = normalize(grad + float2(1e-5, 1e-5));
        float topFacing = pow(max(dot(n, float2(0.0, -1.0)), 0.0), 1.6);
        float edge = smoothstep(2.4, 0.15, abs(d)) * outer;
        float rim = edge * (0.12 + 0.62 * topFacing) * presence;

        rgb = clamp(rgb + float3(topLip + rim) - float3(bottomShade), 0.0, 1.0);
        alpha = clamp(alpha + (topLip + rim) * 0.55, 0.0, 1.0);

        if (hot) {
            float2 delta = (in.uv - puv) * float2(1.2, 0.62);
            float radial = 1.0 - smoothstep(0.02, 0.48, length(delta));
            float spec = radial * 0.7 * outer * presence;
            rgb = clamp(rgb + float3(spec), 0.0, 1.0);
            alpha = clamp(alpha + spec * 0.45, 0.0, 1.0);
        }
    }
    return float4(rgb * holeMask, alpha * holeMask);
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
    /// Trailing-fade multiplier, 1 at the start of the ramp and 0 at its
    /// end. The ramp is linear in device x and the quad is axis-aligned, so
    /// interpolating it across the quad is exact, and a glyph outside the
    /// ramp carries a constant 1.
    float  fade;
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
    out.fade = 1.0;
    if (g.flags & kGlyphFlagFade) {
        float span = g.fadeEnd - g.fadeStart;
        out.fade = span > 0.0 ? saturate((g.fadeEnd - pixel.x) / span) : 1.0;
    }
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
        texel *= in.color.a * in.fade;
        if (in.flags & kGlyphFlagGrey) {
            // Rec. 709 luma. Valid on PREMULTIPLIED colour: alpha scales all
            // three channels equally, so the weighted sum stays premultiplied
            // and needs no un-premultiply/re-premultiply round trip.
            float luma = dot(texel.rgb, float3(0.2126, 0.7152, 0.0722));
            texel.rgb = float3(luma);
        }
        return texel;
    }
    float coverage = maskAtlas.sample(atlasSampler, in.uv).r;
    float alpha = coverage * in.color.a * in.fade;
    return float4(in.color.rgb * alpha, alpha);
}
