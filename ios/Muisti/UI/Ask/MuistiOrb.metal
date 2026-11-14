// The Muisti voice orb: a lit, glassy sphere with slowly flowing colour, for SwiftUI
// `.colorEffect` (iOS 17+).
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// - size: view size in points; time: phase-weighted clock (seconds)
/// - level: loudness 0…1; bass / treble: low / high band energy 0…1
/// - thinking: 0…1, fades in a comet circling the orb
/// - c0, c1, c2: palette (deep, bright, accent)
/// Output is premultiplied: the sphere plus a soft glow that fades out before the view's edge.
[[ stitchable ]]
half4 muistiOrb(float2 pos, half4 color, float2 size, float time, float level, float bass, float treble,
                float thinking, half4 c0, half4 c1, half4 c2) {
    float s = min(size.x, size.y);
    float2 uv = (pos - size * 0.5) / s;          // centre 0, about -0.5…0.5
    float r = length(uv);
    float a = atan2(uv.y, uv.x);

    // Size breathes with loudness; the outline only bends when there is sound.
    float base = 0.27 + 0.06 * level + 0.02 * bass;
    float wave = sin(a * 3.0 + time * 1.3) * 0.6 + sin(a * 5.0 - time * 1.7) * 0.4;
    float shimmer = sin(a * 9.0 + time * 3.1) * 0.5 + sin(a * 13.0 - time * 4.3) * 0.5;
    float radius = base * (1.0 + wave * (0.006 + 0.075 * bass + 0.035 * level) + shimmer * (0.026 * treble));

    float d = r - radius;
    float aa = 1.2 / s;
    float core = 1.0 - smoothstep(-aa, aa, d);

    // Sphere geometry: a normal for lighting.
    float2 p = uv / max(radius, 0.001);          // -1…1 across the disc
    float z = sqrt(max(0.0, 1.0 - dot(p, p)));
    float3 n = normalize(float3(p, z + 0.0001));
    float3 light = normalize(float3(-0.45, -0.55, 0.75));
    float diffuse = max(dot(n, light), 0.0);
    float fresnel = pow(1.0 - z, 2.2);
    float3 h = normalize(light + float3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(n, h), 0.0), 28.0);

    // Flowing colour, warped across the curved surface.
    float2 q = n.xy * 1.4;
    q += 0.45 * float2(sin(q.y * 1.7 + time * 0.55), cos(q.x * 1.5 - time * 0.5));
    q += 0.30 * float2(sin(q.y * 2.3 - time * 0.8 + bass * 1.5), cos(q.x * 2.1 + time * 0.7));
    float m1 = 0.5 + 0.5 * sin(q.x * 1.3 + time * 0.4);
    float m2 = 0.5 + 0.5 * sin(q.y * 1.6 - time * 0.45 + 2.0);
    float3 deep = float3(c0.rgb), bright = float3(c1.rgb), accent = float3(c2.rgb);
    float3 col = mix(deep, bright, m1 * m1 * (3.0 - 2.0 * m1));
    col = mix(col, accent, 0.65 * m2 * m2 * (3.0 - 2.0 * m2));

    // Light it: soft shading, a bright rim, a small glossy highlight, inner glow when loud.
    col *= 0.62 + 0.48 * diffuse;
    col += fresnel * mix(bright, float3(1.0), 0.35) * (0.55 + 0.35 * level);
    col += spec * 0.32;
    col += (1.0 - length(p)) * bright * 0.25 * level;
    col = min(col, float3(1.0));

    // Glow, faded to nothing well before the view's edge (no visible box).
    float outside = max(d, 0.0);
    float edgeFade = 1.0 - smoothstep(0.36, 0.49, r);
    float glow = exp(-outside * (16.0 - 7.0 * level)) * (0.16 + 0.5 * level) * (1.0 - core) * edgeFade;
    float3 glowCol = mix(deep, accent, 0.5 + 0.5 * sin(a + time * 0.4));

    // Thinking: a comet on a perfect circle just outside the orb.
    float orbit = abs(r - (base + 0.055));
    float head = fract((a + time * 2.2) / 6.2831853);
    float comet = (1.0 - smoothstep(0.0, 0.007, orbit)) * pow(head, 5.0) * thinking * edgeFade;

    float3 rgb = col * core + glowCol * glow + mix(bright, float3(1.0), 0.5) * comet;
    float alpha = clamp(core + glow + comet, 0.0, 1.0);
    return half4(half3(rgb), half(alpha));
}
