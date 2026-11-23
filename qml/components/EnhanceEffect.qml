// FastShot - SPDX-License-Identifier: GPL-3.0-or-later
// The photo enhancement as a GPU shader, with the formulas of enhance.py:
//  - tone curve per channel: white-balance gain, black/white point, gamma, shadows, highlights
//  - local contrast and sharpening on the brightness only
//  - colour saturation
//  - noise reduction, approximated: colour taken from a softened copy, a little brightness smoothing
// The numbers come from Python (enhance.gpu_params), measured on the photo itself.
// The source must be mipmapped (Image { mipmap: true } or ShaderEffectSource { mipmap: true }):
// the large blur for local contrast is a lower mipmap level.
import QtQuick 2.6

ShaderEffect {
    id: fx

    property variant src
    property var params: ({})

    function num(key, fallback) {
        return params && params[key] !== undefined && params[key] !== null ? Number(params[key]) : fallback
    }

    property vector3d gains: params && params.gains
                             ? Qt.vector3d(params.gains[0], params.gains[1], params.gains[2])
                             : Qt.vector3d(1, 1, 1)
    property real lo: num("lo", 0)
    property real span: Math.max(1, num("hi", 255) - num("lo", 0))
    property real gamma: Math.max(0.05, num("gamma", 1))
    property real shadows: num("shadows", 0)
    property real highlights: num("highlights", 0)
    property real local: num("local", 0)
    property real color: num("color", 0)
    property real denoise: num("denoise", 0)
    property real sharpen: num("sharpen", 0)
    // 1 = edge-preserving noise reduction (5x5 bilateral filter, for saved photos);
    // 0 = the cheap version (for the live preview, which runs 30 times a second)
    property real fullDenoise: 1
    property point texel: Qt.point(1 / Math.max(1, width), 1 / Math.max(1, height))
    // mipmap level of the big blur: about 4 % of the picture, as in enhance._local_contrast
    property real blurBias: Math.max(1, Math.log(Math.max(width, height) * 0.04) / Math.LN2)

    fragmentShader: "
        #ifdef GL_ES
        precision highp float;
        #endif
        varying vec2 qt_TexCoord0;
        uniform sampler2D src;
        uniform float qt_Opacity;
        uniform vec3 gains;
        uniform float lo;
        uniform float span;
        uniform float gamma;
        uniform float shadows;
        uniform float highlights;
        uniform float local;
        uniform float color;
        uniform float denoise;
        uniform float sharpen;
        uniform vec2 texel;
        uniform float blurBias;
        uniform float fullDenoise;

        vec3 tone(vec3 c) {
            vec3 x = clamp((c * 255.0 * gains - vec3(lo)) / span, 0.0, 1.0);
            x = pow(max(x, vec3(0.000001)), vec3(gamma));
            x += shadows * 0.8 * x * (1.0 - x) * (1.0 - x);
            x -= highlights * 0.8 * x * x * (1.0 - x);
            return clamp(x, 0.0, 1.0);
        }

        float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

        // Bilateral filter: averages neighbours that are similar in brightness (noise) and leaves
        // out those that differ a lot (edges), so edges stay sharp while grain disappears.
        vec3 bilateral(vec2 uv, vec3 c) {
            float sigma = 0.02 + 0.08 * denoise;          // brightness differences still taken as noise
            float yc = luma(c);
            vec3 sum = c;
            float wsum = 1.0;
            for (int i = -2; i <= 2; ++i) {
                for (int j = -2; j <= 2; ++j) {
                    if (i == 0 && j == 0) continue;
                    vec2 o = vec2(float(i), float(j)) * texel * (1.0 + denoise);
                    vec3 s = texture2D(src, uv + o).rgb;
                    float d = luma(s) - yc;
                    float w = exp(-(d * d) / (2.0 * sigma * sigma)) * exp(-float(i * i + j * j) / 4.5);
                    sum += s * w;
                    wsum += w;
                }
            }
            return sum / wsum;
        }

        // Colour dots (red/green high-ISO noise): the colour of a pixel is limited to the range of
        // its 4 neighbours' colours, so a single odd pixel loses its colour; brightness is kept.
        vec3 undot(vec2 uv, vec3 c) {
            vec3 n1 = texture2D(src, uv + vec2(texel.x, 0.0)).rgb;
            vec3 n2 = texture2D(src, uv - vec2(texel.x, 0.0)).rgb;
            vec3 n3 = texture2D(src, uv + vec2(0.0, texel.y)).rgb;
            vec3 n4 = texture2D(src, uv - vec2(0.0, texel.y)).rgb;
            vec3 k1 = n1 - vec3(luma(n1)), k2 = n2 - vec3(luma(n2));
            vec3 k3 = n3 - vec3(luma(n3)), k4 = n4 - vec3(luma(n4));
            vec3 lo3 = min(min(k1, k2), min(k3, k4));
            vec3 hi3 = max(max(k1, k2), max(k3, k4));
            float y = luma(c);
            return vec3(y) + clamp(c - vec3(y), lo3, hi3);
        }

        void main() {
            vec2 uv = qt_TexCoord0;
            vec3 c = texture2D(src, uv).rgb;
            if (denoise > 0.0 && fullDenoise > 0.5) {
                // as enhance._denoise: 1. colour dots, 2. colour blotches from a much smaller
                // (mipmap) copy, 3. less colour in the deep shadows
                c = undot(uv, c);
                vec3 b = bilateral(uv, c);
                vec3 soft = texture2D(src, uv, 1.0 + 3.0 * denoise).rgb;
                float yb = luma(b);
                vec3 chroma = mix(b - vec3(yb), soft - vec3(luma(soft)), min(1.0, 0.3 + 0.9 * denoise));
                chroma *= 1.0 - 0.7 * denoise * clamp((0.25 - yb) / 0.17, 0.0, 1.0);
                // coarse grain (as enhance._smooth_flat): the phone leaves brightness blotches
                // of 8-15 px at night; where the picture is no busier than that, take the
                // brightness from the 1/4 size mipmap level, edges (big differences) stay
                if (denoise > 0.4) {
                    float yq = luma(texture2D(src, uv, 2.0).rgb);
                    float dq = yb - yq;
                    float sq = 0.03 + 0.05 * denoise;
                    float wq = 0.85 * clamp((denoise - 0.4) / 0.4, 0.0, 1.0) * exp(-(dq * dq) / (2.0 * sq * sq));
                    yb = mix(yb, yq, wq);
                }
                c = vec3(yb) + chroma;
            } else if (denoise > 0.0) {
                c = undot(uv, c);
                float spread = 1.0 + denoise;
                vec3 soft = texture2D(src, uv, 1.0 + 3.0 * denoise).rgb;
                vec3 n = 0.25 * (texture2D(src, uv + vec2(texel.x * spread, 0.0)).rgb
                               + texture2D(src, uv - vec2(texel.x * spread, 0.0)).rgb
                               + texture2D(src, uv + vec2(0.0, texel.y * spread)).rgb
                               + texture2D(src, uv - vec2(0.0, texel.y * spread)).rgb);
                float y = luma(c);
                float yn = mix(y, luma(n), 0.5 * denoise);
                vec3 chroma = mix(c - vec3(y), soft - vec3(luma(soft)), min(1.0, 0.3 + 0.9 * denoise));
                chroma *= 1.0 - 0.7 * denoise * clamp((0.25 - y) / 0.17, 0.0, 1.0);
                if (denoise > 0.4) {
                    float yq = luma(texture2D(src, uv, 2.0).rgb);
                    float dq = yn - yq;
                    float sq = 0.03 + 0.05 * denoise;
                    float wq = 0.85 * clamp((denoise - 0.4) / 0.4, 0.0, 1.0) * exp(-(dq * dq) / (2.0 * sq * sq));
                    yn = mix(yn, yq, wq);
                }
                c = vec3(yn) + chroma;
            }
            if (fullDenoise > 0.5) {
                c = tone(c);
                float y0 = luma(c);
                float y = y0;
                if (local > 0.0) {
                    float yb = luma(tone(texture2D(src, uv, blurBias).rgb));
                    y += 0.6 * local * (y0 - yb);
                }
                if (sharpen > 0.0) {
                    float ya = 0.25 * (luma(tone(texture2D(src, uv + vec2(texel.x, 0.0)).rgb))
                                     + luma(tone(texture2D(src, uv - vec2(texel.x, 0.0)).rgb))
                                     + luma(tone(texture2D(src, uv + vec2(0.0, texel.y)).rgb))
                                     + luma(tone(texture2D(src, uv - vec2(0.0, texel.y)).rgb)));
                    float d = y0 - ya;
                    if (abs(d) > 2.0 / 255.0) y += (0.2 + 1.3 * sharpen) * d;
                }
                c += vec3(y - y0);
            } else {
                float y0 = luma(c);
                float y = y0;
                if (local > 0.0) {
                    float yb = luma(texture2D(src, uv, blurBias).rgb);
                    y += 0.6 * local * (y0 - yb);
                }
                if (sharpen > 0.0) {
                    float ya = 0.25 * (luma(texture2D(src, uv + vec2(texel.x, 0.0)).rgb)
                                     + luma(texture2D(src, uv - vec2(texel.x, 0.0)).rgb)
                                     + luma(texture2D(src, uv + vec2(0.0, texel.y)).rgb)
                                     + luma(texture2D(src, uv - vec2(0.0, texel.y)).rgb));
                    float d = y0 - ya;
                    if (abs(d) > 2.0 / 255.0) y += (0.2 + 1.3 * sharpen) * d;
                }
                c += vec3(y - y0);
                c = tone(c);
            }
            float g = luma(c);
            c = mix(vec3(g), c, 1.0 + 0.6 * color);
            gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0) * qt_Opacity;
        }
    "
}
