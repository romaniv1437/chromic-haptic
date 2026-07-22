#include <flutter/runtime_effect.glsl>

precision highp float;

uniform sampler2D uInput;
uniform vec2 uResolution;
uniform float uSigma;
uniform float uStrength;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;
    vec2 texel = 1.0 / uResolution;

    int r = int(ceil(3.0 * uSigma));
    if (r < 1) r = 1;
    if (r > 20) r = 20;

    vec4 accum = vec4(0.0);
    float wSum = 0.0;

    for (int x = -20; x <= 20; x++) {
        if (x < -r || x > r) continue;
        float wx = exp(-0.5 * float(x * x) / (uSigma * uSigma));
        for (int y = -20; y <= 20; y++) {
            if (y < -r || y > r) continue;
            float wy = exp(-0.5 * float(y * y) / (uSigma * uSigma));
            float w = wx * wy;
            accum += texture(uInput, uv + vec2(float(x) * texel.x, float(y) * texel.y)) * w;
            wSum += w;
        }
    }

    vec3 blur = wSum > 0.0 ? accum.rgb / wSum : vec3(0.0);
    blur *= uStrength;

    // BlendMode.plus adds src to dst — alpha irrelevant, dark areas add 0
    fragColor = vec4(blur, 1.0);
}
