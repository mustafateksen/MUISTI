// VoiceOrb.metal — SwiftUI .colorEffect shader (iOS 17+ / macOS 14+)
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]]
half4 voiceOrb(float2 pos, half4 color, float2 size, float time, float level, float bass) {
    float2 uv = (pos - size * 0.5) / min(size.x, size.y);   // merkez 0, ~[-0.5, 0.5]
    float r = length(uv);
    float a = atan2(uv.y, uv.x);

    // Kenar dalgalanması: bas -> büyük dalga, genel seviye -> amplitüd
    float wob = 0.030 * sin(a * 3.0 + time * 1.7)
              + 0.020 * sin(a * 5.0 - time * 2.3)
              + 0.012 * sin(a * 9.0 + time * 3.9);
    float radius = 0.26 + level * 0.07 + bass * 0.04 + wob * (0.5 + level * 2.5);

    float d = r - radius;
    float core = smoothstep(0.008, -0.008, d);              // anti-aliased kenar
    float glow = exp(-max(d, 0.0) * (22.0 - level * 10.0)) * (0.35 + level * 0.9);

    // Akan renk
    float3 c1 = float3(0.20, 0.45, 1.00);
    float3 c2 = float3(0.85, 0.30, 1.00);
    float3 c3 = float3(0.15, 0.95, 0.90);
    float m1 = 0.5 + 0.5 * sin(a * 2.0 + time * 0.9 + r * 9.0);
    float m2 = 0.5 + 0.5 * sin(time * 0.6 - r * 12.0);
    float3 col = mix(mix(c1, c2, m1), c3, m2 * 0.6);

    float inner = 1.0 - 0.55 * smoothstep(0.0, radius, r);   // içi parlak, kenara doğru koyu
    float alpha = clamp(core + glow, 0.0, 1.0);
    float3 rgb = col * clamp(core * inner + glow, 0.0, 1.0); // premultiplied

    return half4(half3(rgb), half(alpha));
}
