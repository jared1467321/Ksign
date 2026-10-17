#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>

// A tiny Metal vector double lets this test execute the production color
// transform without an Apple GPU. No color-conversion logic is duplicated.
struct float3 {
    float r, g, b;
    explicit float3(float v) : r(v), g(v), b(v) {}
    float3(float r, float g, float b) : r(r), g(g), b(b) {}
    float3 operator-(float v) const { return float3(r-v, g-v, b-v); }
    float3 operator+(float v) const { return float3(r+v, g+v, b+v); }
    float3 operator*(float v) const { return float3(r*v, g*v, b*v); }
    float3 operator/(float v) const { return float3(r/v, g/v, b/v); }
};
using std::min;
using std::max;
using std::abs;
float clamp(float v, float a, float b) { return min(b, max(a, v)); }
float3 clamp(float3 v, float a, float b) {
    return float3(clamp(v.r,a,b), clamp(v.g,a,b), clamp(v.b,a,b));
}
float mix(float a, float b, float t) { return a+(b-a)*t; }

// PRODUCTION_LIGHT_APPEARANCE

float linear(float v) {
    return v <= 0.04045f ? v/12.92f : std::pow((v+0.055f)/1.055f, 2.4f);
}
float luminance(float3 v) { return 0.2126f*linear(v.r)+0.7152f*linear(v.g)+0.0722f*linear(v.b); }
float saturation(float3 v) {
    float peak=max(v.r,max(v.g,v.b)), floor=min(v.r,min(v.g,v.b));
    return (peak-floor)/max(0.001f,1-abs(peak+floor-1));
}

int main() {
    float minimumContrast = 100;
    // Representative low-intensity saturated curtains must keep their color,
    // instead of being compressed to a near-white background.
    for (auto source : {float3(0.1f,0.005f,0.005f), float3(0.005f,0.1f,0.005f), float3(0.005f,0.005f,0.1f)}) {
        auto light=auroraLightAppearance(source);
        assert(max(light.r,max(light.g,light.b))-min(light.r,min(light.g,light.b)) > 0.40f);
        assert(abs(saturation(light)-saturation(source)) < 0.001f);
    }
    const float3 primary(24/255.0f,32/255.0f,52/255.0f);
    const float3 secondary(26/255.0f,35/255.0f,53/255.0f);
    for (int r=0;r<=20;r++) for (int g=0;g<=20;g++) for (int b=0;b<=20;b++) {
        float3 source(r/20.0f,g/20.0f,b/20.0f);
        auto light=auroraLightAppearance(source);
        assert(std::isfinite(light.r) && std::isfinite(light.g) && std::isfinite(light.b));
        assert(min(light.r,min(light.g,light.b)) >= 0 && max(light.r,max(light.g,light.b)) <= 1);
        assert(luminance(light) > luminance(source*0.76f));
        for (auto ink : {primary, secondary}) {
            float contrast=(luminance(light)+0.05f)/(luminance(ink)+0.05f);
            minimumContrast=min(minimumContrast,contrast);
            assert(contrast >= 4.5f);
        }
    }
    std::cout << "Aurora colors passed: saturated curtains, brighter Light sky, finite RGB and text contrast across 9261 samples (minimum "
              << minimumContrast << ").\n";
}
