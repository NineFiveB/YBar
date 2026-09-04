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
    float2 pointer;   // device px on this surface; negative = pointer is away
    float2 _uPad2;
};

static const uint kQuadFlagGradient = 1u << 0;
static const uint kQuadFlagGlass    = 1u << 1;
static const uint kQuadFlagArc      = 1u << 2;
static const uint kQuadFlagHoles    = 1u << 3;
static const uint kQuadFlagShadow   = 1u << 4;
static const uint kGlyphFlagColor   = 1u << 0;
static const uint kGlyphFlagGrey    = 1u << 1;

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
    // The SDF's screen-space gradient, taken once at top level: derivatives in
    // divergent control flow are undefined, and both the AA width and the
    // bevel normal below need it.
    float2 gradD = float2(ddx(d), ddy(d));
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

    // Soft falloff (drop shadow, or a glow when fill is light). The quad was
    // grown by the blur radius on the CPU side, so the SDF here must use the
    // TRUE shape half size from fill2.xy rather than the grown i.halfSize.
    // `aa` is reused deliberately: it is computed before any branch, and the
    // screen-space derivative of the two distances differs only by a constant
    // shape offset, so taking fwidth() inside this branch would risk divergent
    // derivatives for no accuracy gained.
    if (i.flags & kQuadFlagShadow) {
        float sd = sd_rounded_box(i.local, i.fill2.xy, i.radii);
        float blur = max(i.gradientDir.x, aa);
        float cov = saturate(1.0 - smoothstep(-blur, blur, sd));
        cov *= cov; // a squared ramp sits much closer to a gaussian than linear
        return float4(i.fill.rgb * i.fill.a * cov, i.fill.a * cov) * holeMask;
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
        // A REAL surface normal, not a screen-space direction.
        //
        // This branch used to take normalize(float2(ddx(d), ddy(d))) as its
        // "normal". That is a unit 2D direction with no height component at
        // all, so it cannot light a surface: every pixel on the rim reported
        // the same tilt magnitude and only the direction varied, which is why
        // the result read as a painted-on glint rather than a lit object — and
        // a glint on the top arc specifically is the 2007 glossy-button
        // signature.
        //
        // Instead treat the pill as a slab with a quarter-round bevel of width
        // BEVEL_PX. t runs 0 at the outer edge to 1 where the face goes flat,
        // and the normal of a quarter circle at that parameter is exactly
        // (outward * sqrt(1 - t^2), t) — straight out at the edge, straight up
        // on the face.
        const float BEVEL_PX = 5.0;
        float t = saturate(-d / BEVEL_PX);
        float2 n2 = normalize(gradD + float2(1e-6, 1e-6));
        float3 N = normalize(float3(n2 * sqrt(saturate(1.0 - t * t)), max(t, 1e-3)));

        // Screen y is DOWN, so a light with negative y sits ABOVE the bar.
        //
        // The key light's AZIMUTH swings toward the pointer at a FIXED
        // elevation, so the highlight travels around the bevel as the cursor
        // crosses a pill and the pill reads as tilting to follow it. This is
        // the whole pseudo-3D hover: nothing moves geometrically, so the 2D
        // hit rect still matches the pixels exactly and the instance ABI is
        // untouched.
        //
        // Holding the elevation fixed is the load-bearing part. Leaning the
        // whole vector (the obvious way) also drops L.z, and since the flat
        // face is referenced against saturate(L.z) below, the reference moves
        // WITH the light and cancels almost all of the effect — measured at
        // 1-2 levels out of 255, which is nothing. With L.z pinned the face
        // stays exactly as authored and the full swing lands on the rim.
        const float ELEV = 0.72;                  // cos of the light's elevation
        float2 az = float2(-0.35, -0.80);
        if (pointer.x >= 0.0) {
            // 160 px is a little under one pill, so a pill's own highlight
            // tracks the cursor across it while neighbours still react.
            az += clamp((pointer - i.position.xy) / 160.0, -1.2, 1.2);
        }
        az = normalize(az + float2(1e-6, 1e-6));
        float3 L = float3(az * sqrt(1.0 - ELEV * ELEV), ELEV); // already unit
        float3 H = normalize(L + float3(0.0, 0.0, 1.0)); // orthographic view
        float ndl = saturate(dot(N, L));

        // Diffuse as a DIFFERENCE from the flat face, so the middle of the
        // pill stays exactly as authored and only the bevel moves: the top
        // edge lifts, the bottom edge sinks. This sign change is the whole
        // trick — a bevel that only ever brightens reads as a glow, while one
        // that also darkens reads as geometry.
        //
        // The coefficients are small because the render target is sRGB and the
        // theme is near-black: the shader writes LINEAR light, so against a
        // base of 26/255 (linear 0.010) an addition of 0.05 lands at 67/255
        // once encoded — a fivefold jump from what reads as a "subtle" number.
        // Anything tuned by eye in 0..1 sRGB terms will blow out the rim.
        // 0.050 is chosen so the natural range lands INSIDE the clamp below
        // rather than against it. At 0.090 the top edge computed 0.020 and the
        // sides -0.006, both outside (-0.004, +0.014) — so every bevel pixel
        // saturated, the shading went binary, and the pointer-tracked light
        // below could not modulate anything because there was no headroom left
        // to modulate into.
        // Range is now 0 .. ~0.21 of this coefficient, so 0.067 puts the peak
        // right at the clamp without pinning everything below it.
        float diffuse = (ndl - saturate(L.z)) * 0.067;
        float spec = pow(saturate(dot(N, H)), 42.0) * 0.040;
        float fres = pow(1.0 - saturate(N.z), 4.0) * 0.008;

        // Glass presence follows the fill: a transparent pill (hover fade-out,
        // invisible-until-hover items) must show no rim/backdrop ghost.
        float presence = smoothstep(0.0, 0.06, fill.a);
        // Bounds are LINEAR light, and they are this tight for a reason: the
        // theme's resting pill is 26/255, which is linear 0.010. A negative of
        // -0.016 is larger than the entire value beneath it, so it does not
        // "darken the lower bevel", it punches the plate to pure black. The
        // usable range under this fill is roughly (-0.004, +0.014); measured
        // on a resting pill that lands at 22/255 and 40/255 respectively.
        float light = clamp(diffuse + spec + fres, -0.004, 0.014) * presence * outer;
        // rgb is premultiplied, so the light has to be scaled by alpha to stay
        // consistent with it; alpha only ever gains, never loses, or a dark
        // bevel would eat holes in the plate.
        rgb = clamp(rgb + float3(light, light, light) * alpha, 0.0, 1.0);
        alpha = clamp(alpha + max(light, 0.0) * 0.5, 0.0, 1.0);
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
        texel *= i.color.a;
        if (i.flags & kGlyphFlagGrey) {
            // Rec. 709 luma. Valid on PREMULTIPLIED colour: alpha scales all
            // three channels equally, so the weighted sum stays premultiplied
            // and needs no un-premultiply/re-premultiply round trip.
            float luma = dot(texel.rgb, float3(0.2126, 0.7152, 0.0722));
            texel.rgb = float3(luma, luma, luma);
        }
        return texel;
    }
    float coverage = maskAtlas.Sample(atlasSampler, i.uv).r;
    float alpha = coverage * i.color.a;
    return float4(i.color.rgb * alpha, alpha);
}
