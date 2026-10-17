// Aurora and pane optics ported from the supplied Tallyapp-Beautiful reference.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Noise

static float auroraHash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float auroraValueNoise(
    float2 p,
    texture2d<half> noiseTexture
) {
    // The cached image stores one random value at every lattice point. Sampling
    // it with hardware bilinear filtering after applying the same cubic easing
    // reproduces smooth value noise with one texture lookup instead of four
    // per-pixel hash evaluations. Repeat addressing makes the cache seamless.
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float2 textureSize = float2(
        float(max(noiseTexture.get_width(), 1u)),
        float(max(noiseTexture.get_height(), 1u))
    );
    float2 samplePosition = (i + u + 0.5) / textureSize;

    constexpr sampler noiseSampler(
        coord::normalized,
        address::repeat,
        filter::linear
    );
    return float(noiseTexture.sample(noiseSampler, samplePosition).r);
}

static float2 auroraRotate(float2 p, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static float auroraFBM(float2 p, texture2d<half> noiseTexture) {
    float value = 0.0;
    float amplitude = 0.5;

    for (int octave = 0; octave < 5; ++octave) {
        value += amplitude * auroraValueNoise(p, noiseTexture);
        p = auroraRotate(p, 0.54) * 1.93 + float2(17.17, 9.31);
        amplitude *= 0.5;
    }

    return value / 0.96875;
}

static float auroraFBM4(float2 p, texture2d<half> noiseTexture) {
    float value = 0.0;
    float amplitude = 0.5;

    for (int octave = 0; octave < 4; ++octave) {
        value += amplitude * auroraValueNoise(p, noiseTexture);
        p = auroraRotate(p, 0.49) * 1.91 + float2(13.71, 6.83);
        amplitude *= 0.5;
    }

    return value / 0.9375;
}

static float3 auroraScreen(float3 base, float3 light) {
    return 1.0 - (1.0 - base) * (1.0 - clamp(light, 0.0, 1.0));
}

// The 128-bit Swift identity arrives as eight exact UInt16-sized Float values.
// Reassemble those chunks into four UInt32 words before hashing so no identity
// bits are lost to floating-point precision on the SwiftUI -> Metal boundary.
static uint4 auroraMasterWords(float4 seedA, float4 seedB) {
    return uint4(
        uint(seedA.x) | (uint(seedA.y) << 16),
        uint(seedA.z) | (uint(seedA.w) << 16),
        uint(seedB.x) | (uint(seedB.y) << 16),
        uint(seedB.z) | (uint(seedB.w) << 16)
    );
}

static uint auroraAvalanche32(uint value) {
    value ^= value >> 16;
    value *= 0x7FEB352Du;
    value ^= value >> 15;
    value *= 0x846CA68Bu;
    value ^= value >> 16;
    return value;
}

static uint auroraMasterHash(float4 seedA, float4 seedB, uint stream) {
    uint4 words = auroraMasterWords(seedA, seedB);
    uint h = auroraAvalanche32(0x9E3779B9u ^ (stream * 0x85EBCA6Bu));
    h = auroraAvalanche32(h ^ words.x);
    h = auroraAvalanche32(h ^ words.y ^ 0xC2B2AE35u);
    h = auroraAvalanche32(h ^ words.z ^ 0x27D4EB2Fu);
    h = auroraAvalanche32(h ^ words.w ^ 0x165667B1u);
    return h;
}

static float auroraMasterRandom(float4 seedA, float4 seedB, uint stream) {
    // The top 24 hash bits map exactly into Float's useful random mantissa.
    return float(auroraMasterHash(seedA, seedB, stream) >> 8)
        * (1.0 / 16777216.0);
}

static float auroraStreamSeed(float4 seedA, float4 seedB, uint stream) {
    return 1.0 + auroraMasterRandom(seedA, seedB, stream) * 4095.0;
}

static float4 auroraCurtainSeedPack(float4 seedA, float4 seedB, uint index) {
    uint base = 0x1000u + index * 0x20u;
    return float4(
        auroraStreamSeed(seedA, seedB, base + 0u),  // geometry
        auroraStreamSeed(seedA, seedB, base + 1u),  // internal detail
        auroraStreamSeed(seedA, seedB, base + 2u),  // palette
        auroraStreamSeed(seedA, seedB, base + 3u)   // motion
    );
}

static float auroraRandom(float seed, float salt) {
    return auroraHash21(float2(seed * 0.173 + salt, salt * 1.731 + seed * 0.019));
}

// Random signed velocities must never collapse toward zero. A direction is
// selected independently from a magnitude with an explicit lower bound, so
// every generated curtain continues to evolve visibly.
static float auroraSignedRandom(
    float seed,
    float salt,
    float minimumMagnitude,
    float maximumMagnitude
) {
    float magnitude = mix(
        minimumMagnitude,
        maximumMagnitude,
        auroraRandom(seed, salt)
    );
    float direction = auroraRandom(seed, salt + 0.731) < 0.5 ? -1.0 : 1.0;
    return magnitude * direction;
}

// Animated noise coordinates must stay numerically compact. Adding a raw seed
// (especially a multiplied seed) to a small time increment can quantize that
// increment in 32-bit Metal floats and make a smoothly moving field appear to
// jump. These helpers convert the seed into bounded static offsets and phases,
// preserving launch randomization without sacrificing sub-frame precision.
static float auroraOffset(float seed, float salt, float scale) {
    return (auroraRandom(seed, salt) - 0.5) * scale;
}

static float2 auroraOffset2(float seed, float salt, float scale) {
    return (float2(
        auroraRandom(seed, salt),
        auroraRandom(seed, salt + 1.137)
    ) - 0.5) * scale;
}

static float auroraPhase(float seed, float salt) {
    return auroraRandom(seed, salt) * 6.28318530718;
}

// Full-spectrum color generation. The hue wraps around the complete color wheel,
// so every launch can include greens, blues, violets, pinks, reds, oranges,
// yellows, or any transition between them.
static float3 auroraHSV(float hue, float saturation, float value) {
    float3 shifted = fract(hue + float3(0.0, 2.0 / 3.0, 1.0 / 3.0));
    float3 rgb = clamp(abs(shifted * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);
    return value * mix(float3(1.0), rgb, saturation);
}

static float3 auroraPalette(
    float x,
    float signedDepth,
    float time,
    float seed,
    float hueOffset,
    float hueSpread,
    float brightness,
    texture2d<half> noiseTexture
) {
    float2 fieldAOffset = auroraOffset2(seed, 2.3, 72.0);
    float2 fieldBOffset = auroraOffset2(seed, 3.7, 72.0);
    float2 fieldCOffset = auroraOffset2(seed, 4.9, 72.0);

    float fieldA = auroraFBM4(float2(
        x * (1.05 + auroraRandom(seed, 4.1) * 1.10)
            + time * auroraSignedRandom(seed, 5.3, 0.018, 0.046)
            + fieldAOffset.x,
        signedDepth * (0.30 + auroraRandom(seed, 7.7) * 0.85)
            + fieldAOffset.y
    ), noiseTexture);

    float fieldB = auroraFBM4(float2(
        x * (0.70 + auroraRandom(seed, 8.9) * 1.45)
            + time * auroraSignedRandom(seed, 10.1, 0.020, 0.052)
            + fieldBOffset.x,
        signedDepth * (0.25 + auroraRandom(seed, 11.3) * 0.95)
            + fieldBOffset.y
            + time * 0.018
    ), noiseTexture);

    float fieldC = auroraFBM4(float2(
        x * (1.50 + auroraRandom(seed, 12.7) * 1.80)
            + signedDepth * (0.45 + auroraRandom(seed, 13.9) * 1.20)
            + fieldCOffset.x,
        time * auroraSignedRandom(seed, 15.1, 0.024, 0.068)
            + fieldCOffset.y
    ), noiseTexture);

    // Every curtain gets a genuinely independent, seed-selected palette.
    // Three separated anchors ensure that a single curtain can visibly contain
    // several colors instead of merely tinting one fixed family.
    float baseHue = fract(auroraRandom(seed, 17.3) + hueOffset);
    float direction = auroraRandom(seed, 18.7) < 0.5 ? -1.0 : 1.0;
    float spanA = mix(0.10, 0.42, auroraRandom(seed, 20.1)) * hueSpread;
    float spanB = mix(0.20, 0.72, auroraRandom(seed, 21.7)) * hueSpread;
    float slowHueDrift = sin(
        time * mix(0.018, 0.046, auroraRandom(seed, 23.3))
            + auroraPhase(seed, 23.9)
    ) * mix(0.022, 0.070, auroraRandom(seed, 24.9));
    float hueTravel = time * auroraSignedRandom(seed, 25.4, 0.0025, 0.0075);

    // Keep the palette anchors unwrapped while they are blended. Wrapping each
    // anchor independently here can create an intermittent discontinuity: one
    // anchor may cross 1.0 -> 0.0 a frame before another, causing the blended
    // hue to jump even though each underlying animation is otherwise smooth.
    // auroraHSV() performs the single final wrap after all interpolation.
    float hueA = baseHue + slowHueDrift + hueTravel;
    float hueB = baseHue + direction * spanA + slowHueDrift * 0.72 + hueTravel;

    float saturationA = mix(0.72, 1.00, auroraRandom(seed, 26.1));
    float saturationB = mix(0.74, 1.00, auroraRandom(seed, 27.7));
    float saturationC = mix(0.70, 1.00, auroraRandom(seed, 29.3));

    // Build the final color in hue space rather than blending distant RGB
    // anchors. This keeps orange/cyan, yellow/violet, and other complementary
    // combinations saturated instead of letting them average into gray.
    float laneAB = smoothstep(0.20, 0.82, fieldA);
    float laneC = smoothstep(0.30, 0.86, fieldB)
        * (0.58 + fieldC * 0.42);
    float localHue = (fieldC - 0.5)
        * mix(0.05, 0.24, auroraRandom(seed, 31.1));
    // Interpolate in continuous (unwrapped) hue space. auroraHSV() wraps this
    // value only once, which preserves smooth transitions across the red end of
    // the color wheel instead of occasionally snapping to an unrelated hue.
    float hue = mix(hueA, hueB, laneAB)
        + direction * spanB * laneC
        + localHue;
    float saturation = mix(
        mix(saturationA, saturationB, laneAB),
        saturationC,
        laneC * 0.72
    );
    float3 color = auroraHSV(hue, clamp(saturation, 0.0, 1.0), 1.0);

    // Bright cores become a pale version of their actual hue rather than the
    // old fixed mint-white, which previously pulled every palette toward green.
    float hotCore = pow(smoothstep(0.56, 0.96, brightness), 1.65) * 0.34;
    float3 luminousCore = mix(color, float3(1.0), 0.68);
    return mix(color, luminousCore, hotCore);
}

static float4 auroraCurtain(
    float2 uv,
    float time,
    float geometrySeed,
    float detailSeed,
    float paletteSeed,
    float motionSeed,
    float baseY,
    float tilt,
    float depth,
    float speed,
    float strength,
    float hueOffset,
    float hueSpread,
    texture2d<half> noiseTexture
) {
    float seed = geometrySeed;
    float speedMagnitude = max(abs(speed), 0.001);
    float streamedX = uv.x + time * speed;

    // The path itself is seed-randomized: frequency, drift direction, arc
    // placement, arc polarity, warp amplitude, and secondary bends all vary.
    float largeFrequency = mix(0.42, 1.34, auroraRandom(seed, 33.1));
    float mediumFrequency = mix(1.10, 2.85, auroraRandom(seed, 34.7));
    float largeDrift = auroraSignedRandom(seed, 36.3, 0.014, 0.050);
    float mediumDrift = auroraSignedRandom(seed, 37.9, 0.024, 0.082);

    float2 largeWarpOffset = auroraOffset2(seed, 32.1, 80.0);
    float2 mediumWarpOffset = auroraOffset2(seed, 32.9, 80.0);
    float largeWarp = auroraFBM(float2(
        streamedX * largeFrequency + largeWarpOffset.x,
        time * largeDrift + largeWarpOffset.y
    ), noiseTexture) - 0.5;
    float mediumWarp = auroraFBM4(float2(
        streamedX * mediumFrequency + mediumWarpOffset.x,
        time * mediumDrift + mediumWarpOffset.y
    ), noiseTexture) - 0.5;

    float archCenter = mix(0.02, 0.98, auroraRandom(seed, 39.1));
    float archWidth = mix(0.20, 0.70, auroraRandom(seed, 40.7));
    float archAmplitude = mix(0.025, 0.155, auroraRandom(seed, 42.3));
    float archDirection = auroraRandom(seed, 43.9) < 0.5 ? -1.0 : 1.0;
    float arch = exp(-pow((uv.x - archCenter) / archWidth, 2.0))
        * archAmplitude * archDirection;

    float secondArchCenter = mix(0.05, 0.95, auroraRandom(seed, 45.1));
    float secondArchWidth = mix(0.16, 0.48, auroraRandom(seed, 46.7));
    float secondArch = exp(-pow((uv.x - secondArchCenter) / secondArchWidth, 2.0))
        * mix(0.012, 0.070, auroraRandom(seed, 48.3))
        * (auroraRandom(seed, 49.9) < 0.5 ? -1.0 : 1.0);

    float largeAmplitude = mix(0.105, 0.285, auroraRandom(seed, 51.1));
    float mediumAmplitude = mix(0.025, 0.105, auroraRandom(seed, 52.7));
    float crestY = baseY
        + tilt * (uv.x - 0.5)
        + arch
        + secondArch
        + largeWarp * largeAmplitude
        + mediumWarp * mediumAmplitude;
    float signedDepth = uv.y - crestY;

    float topGate = smoothstep(-0.100, 0.035, signedDepth);
    float bottomGate = 1.0 - smoothstep(
        depth * 0.48,
        depth + 0.130,
        signedDepth
    );
    float envelope = topGate * bottomGate;

    float horizontalFoldScale = mix(1.15, 2.55, auroraRandom(detailSeed, 54.1));
    float verticalFoldScale = mix(1.35, 3.10, auroraRandom(detailSeed, 55.7));
    float pathShear = mix(-0.70, 0.70, auroraRandom(detailSeed, 57.3));
    float bentX = uv.x + signedDepth * pathShear;

    float2 foldOffset = auroraOffset2(detailSeed, 57.9, 84.0);
    float2 foldPoint = float2(
        bentX * horizontalFoldScale + time * speed * 4.2 + foldOffset.x,
        signedDepth * verticalFoldScale + foldOffset.y
    );
    float2 warp = float2(
        auroraFBM4(foldPoint * mix(0.48, 0.82, auroraRandom(detailSeed, 58.9)) + float2(4.7, 1.3), noiseTexture),
        auroraFBM4(foldPoint * mix(0.50, 0.86, auroraRandom(detailSeed, 60.1)) + float2(9.2, 5.8), noiseTexture)
    ) - 0.5;

    float broadFold = auroraFBM4(
        foldPoint + warp * float2(
            mix(0.75, 1.65, auroraRandom(detailSeed, 61.7)),
            mix(0.55, 1.30, auroraRandom(detailSeed, 63.3))
        )
    , noiseTexture);
    float2 detailedOffset = auroraOffset2(detailSeed, 64.1, 88.0);
    float detailedFold = auroraFBM4(float2(
        bentX * mix(2.8, 5.6, auroraRandom(detailSeed, 64.9))
            + warp.x * mix(1.7, 3.4, auroraRandom(detailSeed, 66.1))
            + time * speed * mix(3.2, 7.2, auroraRandom(detailSeed, 67.7))
            + detailedOffset.x,
        signedDepth * mix(1.55, 3.45, auroraRandom(detailSeed, 69.3))
            + warp.y * mix(1.10, 2.45, auroraRandom(detailSeed, 70.9))
            + detailedOffset.y
    ), noiseTexture);
    float2 secondaryOffset = auroraOffset2(detailSeed, 71.3, 88.0);
    float secondaryFold = auroraFBM4(float2(
        bentX * mix(4.1, 8.2, auroraRandom(detailSeed, 72.1))
            + warp.x * mix(2.2, 4.4, auroraRandom(detailSeed, 73.7))
            - time * speed * mix(2.4, 5.4, auroraRandom(detailSeed, 75.3))
            + secondaryOffset.x,
        signedDepth * mix(1.10, 2.65, auroraRandom(detailSeed, 76.9))
            + warp.y * mix(1.10, 2.35, auroraRandom(detailSeed, 78.1))
            + secondaryOffset.y
    ), noiseTexture);

    float broadBody = smoothstep(0.16, 0.80, broadFold);
    float foldedBody = smoothstep(0.28, 0.76, detailedFold)
        * (0.54 + 0.46 * smoothstep(0.26, 0.74, secondaryFold));

    float2 ribbonOffset = auroraOffset2(detailSeed, 79.1, 92.0);
    float ribbonNoise = auroraFBM4(float2(
        bentX * mix(3.3, 6.4, auroraRandom(detailSeed, 79.7))
            + warp.x * mix(2.2, 4.2, auroraRandom(detailSeed, 81.3))
            + time * speed * mix(3.4, 6.5, auroraRandom(detailSeed, 82.9))
            + ribbonOffset.x,
        signedDepth * mix(1.35, 2.85, auroraRandom(detailSeed, 84.1))
            + warp.y * mix(1.25, 2.55, auroraRandom(detailSeed, 85.7))
            - time * speed * mix(0.20, 0.85, auroraRandom(detailSeed, 87.3))
            + ribbonOffset.y
    ), noiseTexture);
    float2 ribbonOffset2 = auroraOffset2(detailSeed, 88.1, 92.0);
    float ribbonNoise2 = auroraFBM4(float2(
        bentX * mix(5.0, 9.2, auroraRandom(detailSeed, 88.9))
            + warp.x * mix(2.7, 5.0, auroraRandom(detailSeed, 90.1))
            - time * speed * mix(2.4, 5.0, auroraRandom(detailSeed, 91.7))
            + ribbonOffset2.x,
        signedDepth * mix(1.05, 2.55, auroraRandom(detailSeed, 93.3))
            + warp.y * mix(1.45, 2.85, auroraRandom(detailSeed, 94.9))
            + time * speed * mix(0.15, 0.55, auroraRandom(detailSeed, 96.1))
            + ribbonOffset2.y
    ), noiseTexture);
    float ribbonFold = smoothstep(0.25, 0.76, ribbonNoise)
        * (0.65 + 0.35 * smoothstep(0.25, 0.73, ribbonNoise2));

    float2 brightnessOffset = auroraOffset2(motionSeed, 97.1, 76.0);
    float brightnessField = auroraFBM(float2(
        bentX * mix(0.72, 1.55, auroraRandom(motionSeed, 97.7))
            - time * speed * mix(1.3, 3.6, auroraRandom(motionSeed, 99.3))
            + brightnessOffset.x,
        time * auroraSignedRandom(motionSeed, 100.9, 0.018, 0.052)
            + brightnessOffset.y
    ), noiseTexture);
    float brightnessWave = smoothstep(0.26, 0.82, brightnessField);
    float breathing = 0.75 + 0.25 * sin(
        time * (0.64 + speedMagnitude * mix(2.2, 5.2, auroraRandom(motionSeed, 102.1)))
            + auroraPhase(motionSeed, 102.9)
    );

    float crestGlow = exp(-abs(signedDepth) * mix(11.0, 20.0, auroraRandom(detailSeed, 103.7)));
    float outerGlow = exp(-abs(signedDepth) * mix(4.5, 9.2, auroraRandom(detailSeed, 105.3)))
        * smoothstep(-0.150, 0.030, signedDepth)
        * (1.0 - smoothstep(depth * 0.55, depth + 0.170, signedDepth));

    float depthSoftness = 1.0 - smoothstep(
        depth * 0.38,
        depth + 0.050,
        signedDepth
    );
    float alpha = envelope
        * (0.045
           + broadBody * 0.300
           + foldedBody * 0.380
           + ribbonFold * 0.240)
        * (0.52 + brightnessWave * 0.88)
        * (0.80 + depthSoftness * 0.20)
        * breathing;
    alpha += crestGlow
        * (0.075 + brightnessWave * 0.200)
        * (0.58 + broadBody * 0.42);
    alpha += outerGlow * (0.024 + brightnessWave * 0.042);
    alpha = clamp(alpha * strength, 0.0, 0.93);

    float3 color = auroraPalette(
        uv.x,
        signedDepth,
        time,
        paletteSeed,
        hueOffset,
        hueSpread,
        max(brightnessWave, foldedBody * 0.46 + ribbonFold * 0.22),
        noiseTexture
    );

    return float4(color, alpha);
}


static float3 auroraCompositeCurtain(
    float3 baseColor,
    float2 uv,
    float time,
    float4 seeds,
    float baseYMinimum,
    float baseYMaximum,
    float tiltMinimum,
    float tiltMaximum,
    float depthMinimum,
    float depthMaximum,
    float speedMinimum,
    float speedMaximum,
    float strengthMinimum,
    float strengthMaximum,
    float hueSpreadMinimum,
    float hueSpreadMaximum,
    float intensity,
    float globalYShift,
    float globalTiltBias,
    float globalDepthScale,
    float globalStrengthScale,
    texture2d<half> noiseTexture
) {
    float baseY = mix(
        baseYMinimum,
        baseYMaximum,
        auroraRandom(seeds.x, 1.1)
    ) + globalYShift;
    float tilt = mix(
        tiltMinimum,
        tiltMaximum,
        auroraRandom(seeds.x, 2.7)
    ) + globalTiltBias;
    float depth = mix(
        depthMinimum,
        depthMaximum,
        auroraRandom(seeds.x, 4.3)
    ) * globalDepthScale;
    float speed = auroraSignedRandom(
        seeds.w,
        5.9,
        speedMinimum,
        speedMaximum
    );
    float strength = mix(
        strengthMinimum,
        strengthMaximum,
        auroraRandom(seeds.y, 8.7)
    ) * intensity * globalStrengthScale;
    float hueOffset = auroraRandom(seeds.z, 10.3);
    float hueSpread = mix(
        hueSpreadMinimum,
        hueSpreadMaximum,
        auroraRandom(seeds.z, 11.9)
    );

    float4 layer = auroraCurtain(
        uv,
        time,
        seeds.x,
        seeds.y,
        seeds.z,
        seeds.w,
        baseY,
        tilt,
        depth,
        speed,
        strength,
        hueOffset,
        hueSpread,
        noiseTexture
    );

    float outputBoost = mix(1.20, 1.66, auroraRandom(seeds.y, 13.1));
    return auroraScreen(baseColor, layer.rgb * layer.a * outputBoost);
}

static float4 auroraCorona(
    float2 uv,
    float time,
    float geometrySeed,
    float colorSeed,
    texture2d<half> noiseTexture
) {
    float seed = geometrySeed;
    float centerX = mix(0.12, 0.88, auroraRandom(seed, 107.1));
    float centerY = mix(0.04, 0.28, auroraRandom(seed, 108.7));
    float2 delta = uv - float2(centerX, centerY);
    float radius = length(delta);
    float safeRadius = max(radius, 0.0001);
    float2 radialDirection = delta / safeRadius;

    // Sampling raw atan2 angles creates a hard -pi/+pi seam. Most of the time
    // it is hidden, but when a moving ray crosses that seam its path can appear
    // to jump and the attached color changes with it. Sampling noise around a
    // rotating unit circle is mathematically periodic, so rays can travel all
    // the way around the corona without ever encountering a wrap boundary.
    float angularPhase = time
        * auroraSignedRandom(seed, 111.9, 0.022, 0.075);
    float2 animatedDirection = auroraRotate(radialDirection, angularPhase);
    float angularScale = mix(0.72, 1.85, auroraRandom(seed, 110.3));
    float radialScale = mix(2.4, 5.1, auroraRandom(seed, 113.1));
    float radialTravel = time * mix(0.08, 0.28, auroraRandom(seed, 114.7));
    float2 angularPoint = animatedDirection * angularScale
        + float2(
            radius * radialScale - radialTravel,
            radius * radialScale * 0.57 + radialTravel * 0.41
        )
        + auroraOffset2(seed, 115.3, 64.0);
    float angularTexture = auroraFBM4(angularPoint, noiseTexture);

    float broadRays = smoothstep(0.48, 0.88, angularTexture);
    float radialFade = exp(-radius * mix(3.2, 5.8, auroraRandom(seed, 116.3)))
        * smoothstep(0.015, 0.055, radius)
        * (1.0 - smoothstep(0.30, 0.68, radius));
    float verticalDirection = auroraRandom(seed, 117.9) < 0.82 ? 1.0 : -1.0;
    float downwardBias = verticalDirection > 0.0
        ? smoothstep(-0.10, 0.16, delta.y)
        : 1.0 - smoothstep(-0.16, 0.10, delta.y);
    float brightness = broadRays * radialFade * downwardBias;

    // The color field uses the same seam-free circular mapping. It has its own
    // gentle rotation and radial scale, preserving the randomized multicolor
    // corona while ensuring that color remains attached to a continuous path.
    float colorPhase = time
        * auroraSignedRandom(colorSeed, 120.7, 0.018, 0.055);
    float2 colorDirection = auroraRotate(radialDirection, colorPhase);
    float colorAngularScale = mix(0.50, 1.10, auroraRandom(colorSeed, 119.1));
    float colorRadialScale = mix(0.25, 1.20, auroraRandom(colorSeed, 122.3));
    float2 colorPoint = colorDirection * colorAngularScale
        + float2(
            radius * colorRadialScale,
            -radius * colorRadialScale * 0.63
        )
        + auroraOffset2(colorSeed, 121.5, 64.0);
    float colorNoise = auroraFBM4(colorPoint, noiseTexture);
    float baseHue = auroraRandom(colorSeed, 123.9);
    float hueSpan = mix(0.16, 0.72, auroraRandom(colorSeed, 125.1));
    float hue = baseHue + (colorNoise - 0.5) * hueSpan
        + sin(time * 0.018 + auroraPhase(colorSeed, 124.5)) * 0.035;
    float3 color = auroraHSV(hue, mix(0.74, 1.0, colorNoise), 1.0);
    color = mix(color, float3(1.0), pow(brightness, 1.35) * 0.24);

    return float4(color, clamp(brightness * 0.50, 0.0, 0.38));
}

static float3 auroraSceneColor(
    float2 uv,
    float time,
    float4 seedA,
    float4 seedB,
    float intensity,
    texture2d<half> noiseTexture
) {
    // Separate master streams choose global composition before any individual
    // curtain is generated. This changes scene topology as well as parameter
    // values: 2-6 curtains, mirrored/non-mirrored layouts, vertical placement,
    // common tilt, depth, exposure, and zero/one/two corona structures.
    uint curtainCount = 2u + uint(floor(
        auroraMasterRandom(seedA, seedB, 0x0100u) * 5.0
    ));
    float globalYShift = mix(
        -0.075,
        0.075,
        auroraMasterRandom(seedA, seedB, 0x0101u)
    );
    float globalTiltBias = mix(
        -0.105,
        0.105,
        auroraMasterRandom(seedA, seedB, 0x0102u)
    );
    float globalDepthScale = mix(
        0.78,
        1.28,
        auroraMasterRandom(seedA, seedB, 0x0103u)
    );
    float globalStrengthScale = mix(
        0.84,
        1.14,
        auroraMasterRandom(seedA, seedB, 0x0104u)
    );
    bool mirrorComposition = auroraMasterRandom(seedA, seedB, 0x0105u) < 0.5;
    float2 sceneUV = float2(mirrorComposition ? 1.0 - uv.x : uv.x, uv.y);

    // The sky gets a fully independent stream rather than sharing the geometry
    // seed of the curtains.
    float skySeed = auroraStreamSeed(seedA, seedB, 0x0200u);
    float vertical = clamp(uv.y, 0.0, 1.0);
    float skyHue = auroraRandom(skySeed, 127.7);
    float3 topSky = auroraHSV(skyHue, 0.72, 0.024);
    float3 bottomSky = auroraHSV(fract(skyHue + 0.08), 0.82, 0.006);
    float3 color = mix(topSky, bottomSky, vertical);

    float skyTexture = auroraFBM4(float2(
        uv.x * mix(0.55, 1.05, auroraRandom(skySeed, 129.3))
            + auroraOffset(skySeed, 128.5, 48.0),
        uv.y * mix(0.42, 0.92, auroraRandom(skySeed, 130.9)) - time * 0.006
    ), noiseTexture);
    float3 skyAccent = auroraHSV(
        fract(skyHue + mix(0.18, 0.62, auroraRandom(skySeed, 132.1))),
        0.76,
        0.020
    );
    color += skyAccent * smoothstep(0.48, 0.88, skyTexture) * 0.44;

    // Every curtain receives four independently hashed sub-seeds: geometry,
    // fold/detail structure, palette, and motion. The first two layers are
    // always present; the master identity decides whether layers 3-6 exist.
    float4 seeds1 = auroraCurtainSeedPack(seedA, seedB, 0u);
    color = auroraCompositeCurtain(
        color, sceneUV, time, seeds1,
        -0.04, 0.56, -0.58, 0.58, 0.24, 0.48, 0.050, 0.125,
        0.78, 1.14, 0.70, 1.35,
        intensity, globalYShift, globalTiltBias, globalDepthScale,
        globalStrengthScale, noiseTexture
    );

    float4 seeds2 = auroraCurtainSeedPack(seedA, seedB, 1u);
    color = auroraCompositeCurtain(
        color, sceneUV, time, seeds2,
        0.08, 0.70, -0.58, 0.58, 0.24, 0.50, 0.052, 0.135,
        0.74, 1.12, 0.70, 1.35,
        intensity, globalYShift, globalTiltBias, globalDepthScale,
        globalStrengthScale, noiseTexture
    );

    if (curtainCount >= 3u) {
        float4 seeds3 = auroraCurtainSeedPack(seedA, seedB, 2u);
        color = auroraCompositeCurtain(
            color, sceneUV, time, seeds3,
            0.20, 0.82, -0.58, 0.58, 0.22, 0.48, 0.055, 0.145,
            0.72, 1.12, 0.72, 1.40,
            intensity, globalYShift, globalTiltBias, globalDepthScale,
            globalStrengthScale, noiseTexture
        );
    }

    if (curtainCount >= 4u) {
        float4 seeds4 = auroraCurtainSeedPack(seedA, seedB, 3u);
        color = auroraCompositeCurtain(
            color, sceneUV, time, seeds4,
            0.34, 0.92, -0.56, 0.56, 0.20, 0.44, 0.058, 0.155,
            0.62, 1.02, 0.74, 1.42,
            intensity, globalYShift, globalTiltBias, globalDepthScale,
            globalStrengthScale, noiseTexture
        );
    }

    if (curtainCount >= 5u) {
        float4 seeds5 = auroraCurtainSeedPack(seedA, seedB, 4u);
        color = auroraCompositeCurtain(
            color, sceneUV, time, seeds5,
            -0.02, 0.86, -0.72, 0.72, 0.18, 0.46, 0.060, 0.165,
            0.50, 0.92, 0.68, 1.52,
            intensity, globalYShift, globalTiltBias, globalDepthScale,
            globalStrengthScale * 0.90, noiseTexture
        );
    }

    if (curtainCount >= 6u) {
        float4 seeds6 = auroraCurtainSeedPack(seedA, seedB, 5u);
        color = auroraCompositeCurtain(
            color, sceneUV, time, seeds6,
            0.02, 0.96, -0.78, 0.78, 0.16, 0.42, 0.062, 0.175,
            0.44, 0.86, 0.66, 1.58,
            intensity, globalYShift, globalTiltBias, globalDepthScale,
            globalStrengthScale * 0.82, noiseTexture
        );
    }

    // Corona topology is independently selected. Some scenes have none, most
    // have one, and a minority retain the richer two-corona structure.
    float coronaRoll = auroraMasterRandom(seedA, seedB, 0x0300u);
    uint coronaCount = coronaRoll < 0.14 ? 0u : (coronaRoll < 0.72 ? 1u : 2u);

    if (coronaCount >= 1u) {
        float coronaGeometryA = auroraStreamSeed(seedA, seedB, 0x0310u);
        float coronaColorA = auroraStreamSeed(seedA, seedB, 0x0311u);
        float4 coronaA = auroraCorona(
            sceneUV,
            time,
            coronaGeometryA,
            coronaColorA,
            noiseTexture
        );
        color = auroraScreen(
            color,
            coronaA.rgb * coronaA.a * intensity
                * mix(0.72, 1.52, auroraMasterRandom(seedA, seedB, 0x0312u))
        );
    }

    if (coronaCount >= 2u) {
        float coronaGeometryB = auroraStreamSeed(seedA, seedB, 0x0320u);
        float coronaColorB = auroraStreamSeed(seedA, seedB, 0x0321u);
        float4 coronaB = auroraCorona(
            float2(
                1.0 - sceneUV.x,
                sceneUV.y * mix(
                    0.90,
                    1.12,
                    auroraMasterRandom(seedA, seedB, 0x0322u)
                )
            ),
            time * mix(
                0.72,
                1.18,
                auroraMasterRandom(seedA, seedB, 0x0323u)
            ),
            coronaGeometryB,
            coronaColorB,
            noiseTexture
        );
        color = auroraScreen(
            color,
            coronaB.rgb * coronaB.a * intensity
                * mix(0.42, 1.22, auroraMasterRandom(seedA, seedB, 0x0324u))
        );
    }

    float exposure = mix(
        0.92,
        1.08,
        auroraMasterRandom(seedA, seedB, 0x0400u)
    );
    color *= exposure;
    color = color / (1.0 + color * 0.17);
    color = pow(clamp(color, 0.0, 1.0), float3(0.79));

    return color;
}

// The wide master identity is split into exact 16-bit words before crossing the
// SwiftUI shader boundary. Metal reconstructs and hashes all 128 bits into
// independent streams, while every animated noise coordinate still uses only
// compact bounded offsets. That preserves smooth sub-frame motion without
// sacrificing the enlarged procedural identity space.
[[ stitchable ]] half4 auroraBorealis(
    float2 position,
    half4 sourceColor,
    float2 size,
    float time,
    float4 seedA,
    float4 seedB,
    float intensity,
    texture2d<half> noiseTexture,
    float lightMode
) {
    float2 safeSize = max(size, float2(1.0));
    float2 uv = position / safeSize;
    float3 sky = auroraSceneColor(uv, time, seedA, seedB, intensity, noiseTexture);
    // Preserve the original curtains and color identity in both appearances.
    // A pearl base makes the light version bright enough for dark foregrounds.
    float3 darkSky = sky * 0.76;
    float3 lightSky = mix(float3(0.94, 0.95, 0.98), sky, 0.24);
    return half4(half3(mix(darkSky, lightSky, lightMode)), half(1.0));
}

// MARK: - Single-pass glass optics

static bool auroraPaneIsValid(float2 size) {
    return size.x > 1.0 && size.y > 1.0;
}

static float auroraRoundedPaneSDF(
    float2 position,
    float2 origin,
    float2 size,
    float radius
) {
    if (!auroraPaneIsValid(size)) {
        return 1.0e5;
    }

    float safeRadius = clamp(radius, 0.0, min(size.x, size.y) * 0.5);
    float2 local = position - (origin + size * 0.5);
    float2 halfSize = max(size * 0.5, float2(1.0));
    float2 q = abs(local) - (halfSize - safeRadius);

    return length(max(q, float2(0.0)))
        + min(max(q.x, q.y), 0.0)
        - safeRadius;
}

static float2 auroraRoundedPaneNormal(
    float2 position,
    float2 origin,
    float2 size,
    float radius
) {
    float safeRadius = clamp(radius, 0.0, min(size.x, size.y) * 0.5);
    float2 local = position - (origin + size * 0.5);
    float2 halfSize = max(size * 0.5, float2(1.0));
    float2 q = abs(local) - (halfSize - safeRadius);
    float2 cornerVector = max(q, float2(0.0));
    float cornerLength = length(cornerVector);
    float2 direction = select(float2(-1.0), float2(1.0), local >= 0.0);

    if (cornerLength > 0.0001) {
        return normalize(cornerVector) * direction;
    }

    return q.x > q.y
        ? float2(direction.x, 0.0)
        : float2(0.0, direction.y);
}

[[ stitchable ]] half4 auroraPaneOptics(
    float2 position,
    SwiftUI::Layer layer,
    float2 counterOrigin,
    float2 counterSize,
    float counterRadius,
    float2 ledgerOrigin,
    float2 ledgerSize,
    float ledgerRadius,
    float pointScale
) {
    float counterDistance = auroraRoundedPaneSDF(
        position,
        counterOrigin,
        counterSize,
        counterRadius
    );
    float ledgerDistance = auroraRoundedPaneSDF(
        position,
        ledgerOrigin,
        ledgerSize,
        ledgerRadius
    );

    bool insideCounter = counterDistance <= 0.0;
    bool insideLedger = ledgerDistance <= 0.0;

    if (insideCounter) {
        float scale = max(pointScale, 0.05);
        float insideDistance = max(-counterDistance, 0.0);
        float2 outwardNormal = auroraRoundedPaneNormal(
            position,
            counterOrigin,
            counterSize,
            counterRadius
        );

        // Keep the broad, fluid bend from the natural-glass pass, then add a
        // concentrated outer lens.  The two-stage field preserves recognizable
        // source detail through most of the pane while making the last 20–30
        // points visibly redirect light as it crosses the curved perimeter.
        float cornerFactor = smoothstep(
            0.16,
            0.90,
            2.0 * min(abs(outwardNormal.x), abs(outwardNormal.y))
        );

        float shoulderWidth = mix(74.0, 90.0, cornerFactor) * scale;
        float broadShoulder = 1.0 - smoothstep(
            0.0,
            shoulderWidth,
            insideDistance
        );
        broadShoulder = pow(clamp(broadShoulder, 0.0, 1.0), 1.08);

        float edgeCoreWidth = mix(23.0, 30.0, cornerFactor) * scale;
        float edgeCore = 1.0 - smoothstep(
            0.0,
            edgeCoreWidth,
            insideDistance
        );
        edgeCore = pow(clamp(edgeCore, 0.0, 1.0), 1.42);

        // Corners receive more geometric reach, not more brightness.  At the
        // physical rim the straight edges displace about 26 points and the
        // corners about 30, then the effect falls rapidly into the broad bend.
        float broadReach = mix(18.5, 20.5, cornerFactor) * scale;
        float coreReach = mix(7.0, 9.5, cornerFactor) * scale;
        float refractionOffset =
            broadReach * broadShoulder
            + coreReach * edgeCore;
        float2 refractedPosition =
            position + outwardNormal * refractionOffset;

        // Preserve detail: center sampling now carries most of the result and
        // the neighboring samples only remove aliasing at the displaced seam.
        float opticalSoftness = mix(0.36, 0.54, cornerFactor) * scale;
        half4 refractedCenter = layer.sample(refractedPosition);
        half4 refractedInner = layer.sample(
            refractedPosition - outwardNormal * opticalSoftness
        );
        half4 refractedOuter = layer.sample(
            refractedPosition + outwardNormal * opticalSoftness
        );

        float3 filteredRefraction =
            float3(refractedCenter.rgb) * 0.82
            + float3(refractedInner.rgb) * 0.09
            + float3(refractedOuter.rgb) * 0.09;

        // Keep chromatic dispersion sub-point and confined to the strongest
        // curvature.  It enriches the edge without becoming an RGB fringe.
        float chromaReach = mix(0.30, 0.48, cornerFactor)
            * scale
            * pow(edgeCore, 1.75);
        half4 chromaRed = layer.sample(
            refractedPosition + outwardNormal * chromaReach
        );
        half4 chromaBlue = layer.sample(
            refractedPosition - outwardNormal * chromaReach
        );
        float3 refractedColor = float3(
            float(chromaRed.r),
            filteredRefraction.g,
            float(chromaBlue.b)
        );
        refractedColor = mix(
            filteredRefraction,
            refractedColor,
            0.30 * pow(edgeCore, 1.35)
        );

        // The reversed fold is intentionally shorter and less readable than
        // the previous pass.  It remains as a physical cue at the rim, while
        // the refraction—not mirrored text—does the visual work.
        float mirrorWidth = mix(7.5, 10.5, cornerFactor) * scale;
        float mirrorMask = 1.0 - smoothstep(
            0.0,
            mirrorWidth,
            insideDistance
        );
        mirrorMask = pow(clamp(mirrorMask, 0.0, 1.0), 1.62);

        if (mirrorMask <= 0.0001) {
            return half4(
                half3(clamp(refractedColor, 0.0, 1.0)),
                half(1.0)
            );
        }

        float mirrorOffset =
            2.0 * min(insideDistance, mirrorWidth)
            + 2.0 * scale;
        float2 reflectedPosition =
            position + outwardNormal * mirrorOffset;
        half4 reflected = layer.sample(reflectedPosition);
        float3 reflectedColor = float3(reflected.rgb);

        float reflectionBand = exp(-pow(
            (insideDistance - 2.8 * scale) / max(2.25 * scale, 0.001),
            2.0
        ));
        float reflectionMix = clamp(
            mirrorMask * 0.12 + reflectionBand * 0.035,
            0.0,
            0.16
        );
        float3 opticalColor = mix(
            refractedColor,
            reflectedColor,
            reflectionMix
        );

        // Highlights remain source-driven.  Corner strength is already carried
        // by the displacement field, so no corner brightness multiplier is used.
        float reflectedLuma = dot(
            reflectedColor,
            float3(0.2126, 0.7152, 0.0722)
        );
        float sourceResponse = mix(
            0.28,
            1.0,
            smoothstep(0.10, 0.78, reflectedLuma)
        );
        float caustic = (
            reflectionBand * 0.090 + mirrorMask * 0.014
        ) * sourceResponse;
        opticalColor = 1.0
            - (1.0 - opticalColor)
            * (1.0 - reflectedColor * caustic);

        float edgeDensity = pow(mirrorMask, 2.2)
            * (1.0 - smoothstep(0.06, 0.58, reflectedLuma))
            * 0.028;
        opticalColor *= 1.0 - edgeDensity;

        return half4(
            half3(clamp(opticalColor, 0.0, 1.0)),
            half(1.0)
        );
    }

    if (insideLedger) {
        float scale = max(pointScale, 0.05);
        float insideDistance = max(-ledgerDistance, 0.0);
        float2 outwardNormal = auroraRoundedPaneNormal(
            position,
            ledgerOrigin,
            ledgerSize,
            ledgerRadius
        );

        // Keep the broad, fluid bend from the natural-glass pass, then add a
        // concentrated outer lens.  The two-stage field preserves recognizable
        // source detail through most of the pane while making the last 20–30
        // points visibly redirect light as it crosses the curved perimeter.
        float cornerFactor = smoothstep(
            0.16,
            0.90,
            2.0 * min(abs(outwardNormal.x), abs(outwardNormal.y))
        );

        float shoulderWidth = mix(74.0, 90.0, cornerFactor) * scale;
        float broadShoulder = 1.0 - smoothstep(
            0.0,
            shoulderWidth,
            insideDistance
        );
        broadShoulder = pow(clamp(broadShoulder, 0.0, 1.0), 1.08);

        float edgeCoreWidth = mix(23.0, 30.0, cornerFactor) * scale;
        float edgeCore = 1.0 - smoothstep(
            0.0,
            edgeCoreWidth,
            insideDistance
        );
        edgeCore = pow(clamp(edgeCore, 0.0, 1.0), 1.42);

        // Corners receive more geometric reach, not more brightness.  At the
        // physical rim the straight edges displace about 26 points and the
        // corners about 30, then the effect falls rapidly into the broad bend.
        float broadReach = mix(18.5, 20.5, cornerFactor) * scale;
        float coreReach = mix(7.0, 9.5, cornerFactor) * scale;
        float refractionOffset =
            broadReach * broadShoulder
            + coreReach * edgeCore;
        float2 refractedPosition =
            position + outwardNormal * refractionOffset;

        // Preserve detail: center sampling now carries most of the result and
        // the neighboring samples only remove aliasing at the displaced seam.
        float opticalSoftness = mix(0.36, 0.54, cornerFactor) * scale;
        half4 refractedCenter = layer.sample(refractedPosition);
        half4 refractedInner = layer.sample(
            refractedPosition - outwardNormal * opticalSoftness
        );
        half4 refractedOuter = layer.sample(
            refractedPosition + outwardNormal * opticalSoftness
        );

        float3 filteredRefraction =
            float3(refractedCenter.rgb) * 0.82
            + float3(refractedInner.rgb) * 0.09
            + float3(refractedOuter.rgb) * 0.09;

        // Keep chromatic dispersion sub-point and confined to the strongest
        // curvature.  It enriches the edge without becoming an RGB fringe.
        float chromaReach = mix(0.30, 0.48, cornerFactor)
            * scale
            * pow(edgeCore, 1.75);
        half4 chromaRed = layer.sample(
            refractedPosition + outwardNormal * chromaReach
        );
        half4 chromaBlue = layer.sample(
            refractedPosition - outwardNormal * chromaReach
        );
        float3 refractedColor = float3(
            float(chromaRed.r),
            filteredRefraction.g,
            float(chromaBlue.b)
        );
        refractedColor = mix(
            filteredRefraction,
            refractedColor,
            0.30 * pow(edgeCore, 1.35)
        );

        // The reversed fold is intentionally shorter and less readable than
        // the previous pass.  It remains as a physical cue at the rim, while
        // the refraction—not mirrored text—does the visual work.
        float mirrorWidth = mix(7.5, 10.5, cornerFactor) * scale;
        float mirrorMask = 1.0 - smoothstep(
            0.0,
            mirrorWidth,
            insideDistance
        );
        mirrorMask = pow(clamp(mirrorMask, 0.0, 1.0), 1.62);

        if (mirrorMask <= 0.0001) {
            return half4(
                half3(clamp(refractedColor, 0.0, 1.0)),
                half(1.0)
            );
        }

        float mirrorOffset =
            2.0 * min(insideDistance, mirrorWidth)
            + 2.0 * scale;
        float2 reflectedPosition =
            position + outwardNormal * mirrorOffset;
        half4 reflected = layer.sample(reflectedPosition);
        float3 reflectedColor = float3(reflected.rgb);

        float reflectionBand = exp(-pow(
            (insideDistance - 2.8 * scale) / max(2.25 * scale, 0.001),
            2.0
        ));
        float reflectionMix = clamp(
            mirrorMask * 0.12 + reflectionBand * 0.035,
            0.0,
            0.16
        );
        float3 opticalColor = mix(
            refractedColor,
            reflectedColor,
            reflectionMix
        );

        // Highlights remain source-driven.  Corner strength is already carried
        // by the displacement field, so no corner brightness multiplier is used.
        float reflectedLuma = dot(
            reflectedColor,
            float3(0.2126, 0.7152, 0.0722)
        );
        float sourceResponse = mix(
            0.28,
            1.0,
            smoothstep(0.10, 0.78, reflectedLuma)
        );
        float caustic = (
            reflectionBand * 0.090 + mirrorMask * 0.014
        ) * sourceResponse;
        opticalColor = 1.0
            - (1.0 - opticalColor)
            * (1.0 - reflectedColor * caustic);

        float edgeDensity = pow(mirrorMask, 2.2)
            * (1.0 - smoothstep(0.06, 0.58, reflectedLuma))
            * 0.028;
        opticalColor *= 1.0 - edgeDensity;

        return half4(
            half3(clamp(opticalColor, 0.0, 1.0)),
            half(1.0)
        );
    }

    return layer.sample(position);
}
