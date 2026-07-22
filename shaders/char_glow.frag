#include <flutter/runtime_effect.glsl>

precision highp float;

// Character fill rect in canvas coordinates (pixels)
uniform vec4 uCharRect;   // xy = top-left, zw = bottom-right
uniform float uSigma;      // blur radius in pixels
uniform float uStrength;   // glow intensity (0-1)

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy;
    
    // Signed distance to character rect
    vec2 dmin = uv - uCharRect.xy;
    vec2 dmax = uCharRect.zw - uv;
    
    // Outside distance: how far from nearest edge
    vec2 outside = max(vec2(0.0), -dmin) + max(vec2(0.0), -dmax);
    float distOutside = length(outside);
    
    // Inside: 1.0 when inside the rect, 0.0 outside
    float insideDist = max(max(-dmin.x, -dmin.y), max(-dmax.x, -dmax.y));
    float inside = insideDist > 0.0 ? 0.0 : 1.0;
    
    // Gaussian falloff from edges outward
    float glow = exp(-distOutside * distOutside / (2.0 * uSigma * uSigma));
    
    // Core at full brightness, glow fading outside
    float alpha = mix(glow, 1.0, inside) * uStrength;
    
    fragColor = vec4(1.0, 1.0, 1.0, alpha);
}
