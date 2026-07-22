#include <flutter/runtime_effect.glsl>

precision highp float;

uniform float uTime;
uniform vec2 uResolution;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;
    
    // Pulsing green gradient — dead simple, works on any GLES version
    float pulse = 0.5 + 0.5 * sin(uTime * 3.0 + uv.x * 6.28);
    float vignette = 1.0 - length(uv - 0.5) * 1.2;
    
    vec3 green = vec3(0.2, 0.9 + 0.1 * pulse, 0.3);
    float alpha = clamp(vignette, 0.0, 1.0) * (0.6 + 0.4 * pulse);
    
    fragColor = vec4(green * alpha, alpha);
}
