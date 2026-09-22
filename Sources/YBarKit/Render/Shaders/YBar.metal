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
    uint   holeCount;
    float  time;
    float2 pointer;
};

struct Hole {
    float2 origin;
    float2 size;
    float  radius;
    float3 _pad;
};

constant uint kQuadFlagGradient   = 1u << 0;
constant uint kQuadFlagGlass      = 1u << 1;
constant uint kQuadFlagArc        = 1u << 2;
constant uint kQuadFlagHoles      = 1u << 3;
constant uint kQuadFlagShadow     = 1u << 4;
constant uint kQuadFlagSheen      = 1u << 5;
constant uint kQuadFlagLens       = 1u << 6;
constant uint kQuadFlagLensSample = 1u << 7;
constant uint kGlyphFlagColor     = 1u << 0;
constant uint kGlyphFlagGrey      = 1u << 1;

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

// Webpage liquid-glass-js: capsule SDF refraction of a backdrop, rim,
// ripple, 9x9 blur, and a slight vertical tint.
static inline float pill_distance(float2 coord, float2 size, float radius) {
    float2 pixelCoord = coord * size;
    float2 center = size * 0.5;
    float2 capsuleStart = float2(radius, center.y);
    float2 capsuleEnd = float2(size.x - radius, center.y);
    float2 axis = capsuleEnd - capsuleStart;
    float len2 = dot(axis, axis);
    if (len2 > 0.0) {
        float t = clamp(dot(pixelCoord - capsuleStart, axis) / len2, 0.0, 1.0);
        return length(pixelCoord - (capsuleStart + t * axis)) - radius;
    }
    return length(pixelCoord - center) - radius;
}

static inline float4 liquid_lens(
    float2 uv,
    float2 fragPx,
    float2 size,
    bool hot,
    texture2d<float, access::sample> backdrop
) {
    float radius = min(size.x, size.y) * 0.5;
    float distFromEdgeShape = max(-pill_distance(uv, size, radius), 0.0);
    float2 pixelCoord = uv * size;
    float2 capsuleStart = float2(radius, size.y * 0.5);
    float2 capsuleEnd = float2(size.x - radius, size.y * 0.5);
    float2 capsuleAxis = capsuleEnd - capsuleStart;
    float2 shapeNormal = float2(0.0, 1.0);
    float axisLen2 = dot(capsuleAxis, capsuleAxis);
    if (axisLen2 > 0.0) {
        float t = clamp(dot(pixelCoord - capsuleStart, capsuleAxis) / axisLen2, 0.0, 1.0);
        float2 normalDir = pixelCoord - (capsuleStart + t * capsuleAxis);
        if (length(normalDir) > 0.0) shapeNormal = normalize(normalDir);
    } else {
        shapeNormal = normalize(uv - 0.5);
    }
    float baseI = 1.0 - exp(-distFromEdgeShape * 0.1);
    float edgeI = exp(-distFromEdgeShape * 0.15);
    float rimI = exp(-distFromEdgeShape * 0.8);
    float rimK = hot ? 0.1 : 0.05;
    float edgeK = hot ? 0.02 : 0.01;
    float total = baseI * 0.01 + edgeI * edgeK + rimI * rimK;
    float2 baseRefraction = shapeNormal * total;
    float cornerNorm = max(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)) * min(size.x, size.y);
    float2 cornerRefraction = shapeNormal * exp(-cornerNorm * 0.3) * 0.02;
    float2 perpendicular = float2(-shapeNormal.y, shapeNormal.x);
    float distNorm = distFromEdgeShape / max(min(size.x, size.y), 1.0);
    float2 ripple = perpendicular * sin(distNorm * 25.0) * 0.1 * rimI;
    float2 refraction = (baseRefraction + cornerRefraction + ripple) * 2.5;

    float2 texSize = float2(backdrop.get_width(), backdrop.get_height());
    float2 sampleUV = fragPx / max(texSize, float2(1.0)) + refraction;
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float4 color = float4(0.0);
    float2 texel = 1.0 / max(texSize, float2(1.0));
    // Same 9x9 kernel as liquid-glass-js, but a tighter sigma so window
    // edges survive instead of smearing into a flat tint.
    float sigma = 2.0;
    float2 blurStep = texel * sigma;
    float totalWeight = 0.0;
    for (int j = -4; j <= 4; j++) {
        for (int i = -4; i <= 4; i++) {
            float dist = length(float2(float(i), float(j)));
            if (dist > 4.0) continue;
            float weight = exp(-(dist * dist) / (2.0 * sigma * sigma));
            color += backdrop.sample(smp, sampleUV + float2(float(i), float(j)) * blurStep) * weight;
            totalWeight += weight;
        }
    }
    color /= max(totalWeight, 1e-4);
    float3 tint = mix(float3(1.0), float3(0.78), uv.y);
    float tintK = hot ? 0.04 : 0.08;
    color.rgb = mix(color.rgb, tint, tintK);
    // Depth is object-local: a lip on the top of this capsule, a shade on
    // the bottom. Not a ring, and not a light shared with the next pill.
    float topFacing = max(-shapeNormal.y, 0.0);
    float bottomFacing = max(shapeNormal.y, 0.0);
    float edge = exp(-distFromEdgeShape * 0.55);
    color.rgb = clamp(color.rgb + float3(edge * mix(0.04, 0.5, topFacing))
                      - float3(edge * bottomFacing * 0.35), 0.0, 1.0);
    color.a = 1.0;
    return color;
}

fragment float4 quad_fragment(
    QuadVOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    const device Hole *holes [[buffer(2)]],
    texture2d<float, access::sample> backdrop [[texture(0)]]
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

    // Webpage liquid lens replaces the pill fill. System glass is hidden
    // while this texture is live, so the painted rim stays off.
    if ((in.flags & kQuadFlagLensSample) && backdrop.get_width() > 1u) {
        float2 size = max(in.halfSize * 2.0, float2(1.0));
        float2 origin = in.position.xy - in.uv * size;
        float2 puv = (uniforms.pointer - origin) / size;
        bool over = puv.x >= 0.0 && puv.x <= 1.0 && puv.y >= 0.0 && puv.y <= 1.0;
        bool hot = over || (in.flags & kQuadFlagLens) != 0u;
        float4 lens = liquid_lens(in.uv, in.position.xy, size, hot, backdrop);
        rgb = lens.rgb * outer;
        alpha = outer;
    } else if (in.flags & kQuadFlagGlass) {
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

    // Per-pill depth on top of (possibly inactive) system glass: top lip,
    // bottom shade, and a specular only while the pointer is inside this
    // capsule — never a light shared across neighboring pills.
    if (in.flags & kQuadFlagSheen) {
        float2 size = max(in.halfSize * 2.0, float2(1.0));
        float2 origin = in.position.xy - in.uv * size;
        float2 puv = (uniforms.pointer - origin) / size;
        bool over = puv.x >= 0.0 && puv.x <= 1.0 && puv.y >= 0.0 && puv.y <= 1.0;
        bool hot = over || (in.flags & kQuadFlagLens) != 0u;
        // Near-clear fills (inactive-glass compensation) still need a floor
        // so lip/shade read as depth without a dark Metal slab.
        float presence = max(smoothstep(0.0, 0.06, max(fill.a, alpha)), 0.75);

        float topLip = smoothstep(0.28, 0.0, in.uv.y) * outer * 0.42 * presence;
        float bottomShade = smoothstep(0.62, 1.0, in.uv.y) * outer * 0.32 * presence;
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
        texel *= in.color.a;
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
    float alpha = coverage * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}
