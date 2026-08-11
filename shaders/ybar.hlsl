// ybar pipeline shaders — HLSL translation of the YBar reference shader
// (Sources/YBarKit/Render/Shaders/YBar.metal). Compiled at runtime with
// D3DCompile (vs_5_0 / ps_5_0); no build-time shader toolchain.
//
// Contract notes (docs/WINDOWS-PORT.md, section 7.3):
//  - Structs are byte-identical with src/render/instances.h and the Metal
//    originals: QuadInstance 112 B, GlyphInstance 64 B, ShapeVertex 32 B,
//    Hole 32 B. StructuredBuffers are tightly packed; the scalar pads below
//    are part of the ABI, not HLSL padding.
//  - Rasterizer state must be CULL_NONE (unit-quad strip winding is mixed).
//  - Blend state: SrcBlend = ONE, DestBlend = INV_SRC_ALPHA on color and
//    alpha (premultiplied compositing; instance colors are straight-alpha
//    sRGB and are premultiplied here in the pixel shaders).
//  - SV_Position.xy in a pixel shader yields top-left-origin pixel-center
//    coordinates, matching Metal [[position]] — the hole cutout relies on it.
//  - Registers: VS t0 = instance/vertex buffer; b1 = Uniforms (both stages);
//    PS quads t2 = holes; PS glyphs t0 = mask atlas, t1 = color atlas, s0 =
//    linear-clamp sampler.

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
    uint3  _pad;
};

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float4 color;
    uint   flags;
    uint3  _pad;
};

struct ShapeVertexIn {
    float2 position;
    float2 _pad;
    float4 color;        // straight-alpha linear
};

struct Hole {
    float2 origin;
    float2 size;
    float  radius;
    float3 _pad;
};

cbuffer Uniforms : register(b1) {
    float2 viewportSize;
    uint   holeCount;
    uint   _uPad;
};

static const uint kQuadFlagGradient = 1u << 0;
static const uint kQuadFlagGlass    = 1u << 1;
static const uint kQuadFlagArc      = 1u << 2;
static const uint kQuadFlagHoles    = 1u << 3;
static const uint kGlyphFlagColor   = 1u << 0;

// Vertex-pulled unit quad: vid 0..3 as a triangle strip.
float2 unit_corner(uint vid) {
    return float2(float(vid & 1u), float((vid >> 1u) & 1u));
}

float4 to_clip(float2 pixel, float2 viewport) {
    // Top-left-origin pixels -> NDC (y flipped).
    float2 ndc = pixel / viewport * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

// ---------------------------------------------------------------- quads

StructuredBuffer<QuadInstance> quadInstances : register(t0);
StructuredBuffer<Hole>         holes         : register(t2);

struct QuadVOut {
    float4 position    : SV_Position;
    float2 local       : TEXCOORD0;   // pixel coords centered on the quad
    float2 halfSize    : TEXCOORD1;
    float2 uv          : TEXCOORD2;   // 0..1 across the quad
    float4 radii       : TEXCOORD3;
    float4 fill        : COLOR0;
    float4 fill2       : COLOR1;
    float2 gradientDir : TEXCOORD4;
    float  borderWidth : TEXCOORD5;
    float4 borderColor : COLOR2;
    nointerpolation uint flags : TEXCOORD6;
};

QuadVOut quad_vertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    QuadInstance q = quadInstances[iid];
    float2 corner = unit_corner(vid);
    float2 pixel = q.origin + corner * q.size;

    QuadVOut o;
    o.position = to_clip(pixel, viewportSize);
    o.local = (corner - 0.5) * q.size;
    o.halfSize = q.size * 0.5;
    o.uv = corner;
    o.radii = q.radii;
    o.fill = q.fill;
    o.fill2 = q.fill2;
    o.gradientDir = q.gradientDir;
    o.borderWidth = q.borderWidth;
    o.borderColor = q.borderColor;
    o.flags = q.flags;
    return o;
}

// Analytic per-corner rounded-box SDF. p is centered, y-down.
float sd_rounded_box(float2 p, float2 halfSize, float4 radii) {
    // radii = (topLeft, topRight, bottomRight, bottomLeft); top = negative y.
    float r = p.x > 0.0
        ? (p.y > 0.0 ? radii.z : radii.y)
        : (p.y > 0.0 ? radii.w : radii.x);
    r = min(r, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

float4 quad_fragment(QuadVOut i) : SV_Target {
    float d = sd_rounded_box(i.local, i.halfSize, i.radii);
    float aa = max(fwidth(d), 1e-4);

    // background.clip cutouts: multiply coverage by "outside every hole".
    float holeMask = 1.0;
    if (i.flags & kQuadFlagHoles) {
        for (uint h = 0; h < holeCount; h++) {
            Hole hole = holes[h];
            float2 center = hole.origin + hole.size * 0.5;
            float hd = sd_rounded_box(i.position.xy - center, hole.size * 0.5,
                                      float4(hole.radius, hole.radius, hole.radius, hole.radius));
            holeMask = min(holeMask, smoothstep(-aa, aa, hd));
        }
    }

    if (i.flags & kQuadFlagArc) {
        // Speedometer gauge: a 270-degree ring open at the bottom, filling
        // clockwise from the lower-left. The quad is a circle (radius =
        // halfSize); ring band = borderWidth; progress (0..1) rides in
        // gradientDir.x; borderColor = progress arc, fill = track.
        float ringOuter = 1.0 - smoothstep(-aa, aa, d);
        float ringInner = 1.0 - smoothstep(-aa, aa, d + i.borderWidth);
        float ring = max(ringOuter - ringInner, 0.0);

        float deg = atan2(-i.local.y, i.local.x) * 57.29577951;
        float a = (deg <= -135.0) ? deg + 360.0 : deg;   // (-135, 225]
        float t = (225.0 - a) / 270.0;                    // 0 at start, 1 at end
        if (t < 0.0 || t > 1.0) {
            return float4(0.0, 0.0, 0.0, 0.0);            // bottom gap
        }
        float4 c = (t <= i.gradientDir.x) ? i.borderColor : i.fill;
        return float4(c.rgb * c.a * ring, c.a * ring);
    }

    float outer = 1.0 - smoothstep(-aa, aa, d);
    float inner = (i.borderWidth > 0.0)
        ? 1.0 - smoothstep(-aa, aa, d + i.borderWidth)
        : outer;

    float4 fill = i.fill;
    if (i.flags & kQuadFlagGradient) {
        float t = clamp(dot(i.uv - 0.5, i.gradientDir) + 0.5, 0.0, 1.0);
        fill = lerp(i.fill, i.fill2, t);
    }

    // Premultiplied compositing: fill inside the border ring, border on the ring.
    float3 rgb = fill.rgb * fill.a * inner + i.borderColor.rgb * i.borderColor.a * (outer - inner);
    float alpha = fill.a * inner + i.borderColor.a * (outer - inner);

    if (i.flags & kQuadFlagGlass) {
        // Liquid-glass rim: the SDF's screen-space gradient is the surface
        // normal, so speculars wrap around corners like light bending through
        // curved glass instead of a flat top band.
        float2 grad = float2(ddx(d), ddy(d));
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
        float sheen = max((0.5 - i.uv.y) * 0.025, 0.0) * outer;
        // Glass presence follows the fill: a transparent pill (hover fade-out,
        // invisible-until-hover items) must show no rim/backdrop ghost.
        float presence = smoothstep(0.0, 0.06, fill.a);
        float light = (rimLight + innerGlow + sheen) * presence;
        rgb = clamp(rgb + float3(light, light, light), 0.0, 1.0);
        alpha = clamp(alpha + light * 0.85, 0.0, 1.0);
    }
    return float4(rgb * holeMask, alpha * holeMask);
}

// ---------------------------------------------------------------- shapes

// Raw CPU-tessellated triangles (graph fills and polylines), vertex-pulled.
StructuredBuffer<ShapeVertexIn> shapeVertices : register(t0);

struct ShapeVOut {
    float4 position : SV_Position;
    float4 color    : COLOR0;
};

ShapeVOut shape_vertex(uint vid : SV_VertexID) {
    ShapeVertexIn v = shapeVertices[vid];
    ShapeVOut o;
    o.position = to_clip(v.position, viewportSize);
    o.color = v.color;
    return o;
}

float4 shape_fragment(ShapeVOut i) : SV_Target {
    return float4(i.color.rgb * i.color.a, i.color.a);
}

// ---------------------------------------------------------------- glyphs

StructuredBuffer<GlyphInstance> glyphInstances : register(t0);
Texture2D<float4> maskAtlas  : register(t0);
Texture2D<float4> colorAtlas : register(t1);
SamplerState atlasSampler    : register(s0);   // linear min/mag, clamp

struct GlyphVOut {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
    float4 color    : COLOR0;
    nointerpolation uint flags : TEXCOORD1;
};

GlyphVOut glyph_vertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    GlyphInstance g = glyphInstances[iid];
    float2 corner = unit_corner(vid);
    float2 pixel = g.origin + corner * g.size;

    GlyphVOut o;
    o.position = to_clip(pixel, viewportSize);
    o.uv = g.uvOrigin + corner * g.uvSize;
    o.color = g.color;
    o.flags = g.flags;
    return o;
}

float4 glyph_fragment(GlyphVOut i) : SV_Target {
    if (i.flags & kGlyphFlagColor) {
        // Color page stores premultiplied BGRA (emoji, multicolor symbols).
        float4 texel = colorAtlas.Sample(atlasSampler, i.uv);
        return texel * i.color.a;
    }
    float coverage = maskAtlas.Sample(atlasSampler, i.uv).r;
    float alpha = coverage * i.color.a;
    return float4(i.color.rgb * alpha, alpha);
}
