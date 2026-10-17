#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>

// Clang vectors execute the actual Metal arithmetic on macOS/Linux. The only
// doubles are the texture/layer interfaces; both shaders see identical input.
using uint = uint32_t;
using half = float;
using float2 = float __attribute__((ext_vector_type(2)));
using float3 = float __attribute__((ext_vector_type(3)));
using float4 = float __attribute__((ext_vector_type(4)));
using uint4 = uint __attribute__((ext_vector_type(4)));
using int2 = int __attribute__((ext_vector_type(2)));
using half3 = float3;
using half4 = float4;
float2 make2(float x) { return {x, x}; }
float2 make2(float x, float y) { return {x, y}; }
float3 make3(float x) { return {x, x, x}; }
float3 make3(float3 x) { return x; }
float3 make3(float x, float y, float z) { return {x, y, z}; }
float4 make4(float3 rgb, float a) { return {rgb.x, rgb.y, rgb.z, a}; }
float4 make4(float x, float y, float z, float w) { return {x, y, z, w}; }
uint4 makeU4(uint x, uint y, uint z, uint w) { return {x, y, z, w}; }
#define float2(...) make2(__VA_ARGS__)
#define float3(...) make3(__VA_ARGS__)
#define float4(...) make4(__VA_ARGS__)
#define uint4(...) makeU4(__VA_ARGS__)
#define half3(...) make3(__VA_ARGS__)
#define half4(...) make4(__VA_ARGS__)
#define device
float min(float a, float b) { return std::min(a, b); }
float max(float a, float b) { return std::max(a, b); }
uint max(uint a, uint b) { return std::max(a, b); }
float2 max(float2 a, float2 b) { return {max(a.x, b.x), max(a.y, b.y)}; }
float clamp(float x, float a, float b) { return min(max(x, a), b); }
float3 clamp(float3 x, float a, float b) { return {clamp(x.x,a,b), clamp(x.y,a,b), clamp(x.z,a,b)}; }
float floor(float x) { return std::floor(x); }
float2 floor(float2 x) { return {floor(x.x), floor(x.y)}; }
float fract(float x) { return x - floor(x); }
float2 fract(float2 x) { return x - floor(x); }
float3 fract(float3 x) { return {fract(x.x), fract(x.y), fract(x.z)}; }
float abs(float x) { return std::abs(x); }
float2 abs(float2 x) { return {abs(x.x), abs(x.y)}; }
float3 abs(float3 x) { return {abs(x.x), abs(x.y), abs(x.z)}; }
float dot(float2 a, float2 b) { return a.x*b.x + a.y*b.y; }
float dot(float3 a, float3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
float length(float2 x) { return std::sqrt(dot(x,x)); }
float2 normalize(float2 x) { return x / length(x); }
float2 select(float2 a, float2 b, int2 c) { return {c.x ? b.x : a.x, c.y ? b.y : a.y}; }
float sin(float x) { return std::sin(x); }
float cos(float x) { return std::cos(x); }
float exp(float x) { return std::exp(x); }
float sqrt(float x) { return std::sqrt(x); }
float pow(float x, float y) { return std::pow(x,y); }
float3 pow(float3 x, float3 y) { return {pow(x.x,y.x), pow(x.y,y.y), pow(x.z,y.z)}; }
float mix(float a, float b, float t) { return a+(b-a)*t; }
float3 mix(float3 a, float3 b, float t) { return a+(b-a)*t; }
float smoothstep(float a, float b, float x) { float t=clamp((x-a)/(b-a),0,1); return t*t*(3-2*t); }
namespace coord { constexpr int normalized=0; }
namespace address { constexpr int repeat=0; }
namespace filter { constexpr int linear=0; }
struct sampler { constexpr sampler(int,int,int) {} };

template<class T> struct texture2d {
    uint64_t *samples;
    uint get_width() const { return 256; }
    uint get_height() const { return 256; }
    float4 sample(sampler, float2 uv) const {
        ++*samples;
        // Same repeat/bilinear addressing and 8-bit lattice as the Swift cache.
        static const auto lattice=[] {
            std::array<float,256*256> result{};
            for(int y=0;y<256;y++) for(int x=0;x<256;x++) {
                float px=fract(float(x)*123.34f), py=fract(float(y)*456.21f);
                float d=px*(px+45.32f)+py*(py+45.32f);
                px+=d; py+=d;
                result[y*256+x]=std::round(clamp(fract(px*py),0,1)*255)/255;
            }
            return result;
        }();
        float x=uv.x*256-0.5f, y=uv.y*256-0.5f;
        int ix=int(floor(x)), iy=int(floor(y));
        auto at=[&](int dx,int dy) { return lattice[((iy+dy)&255)*256+((ix+dx)&255)]; };
        float v=mix(mix(at(0,0),at(1,0),fract(x)),mix(at(0,1),at(1,1),fract(x)),fract(y));
        return float4(v,v,v,1);
    }
};

namespace SwiftUI {
struct Layer {
    uint64_t *samples;
    half4 sample(float2 p) const {
        ++*samples;
        // A high-frequency, multicolor image exposes changed sample positions.
        return half4(fract(p.x*0.137f),fract(p.y*0.193f),fract((p.x+p.y)*0.071f),1);
    }
};
}

namespace Reference {
// REFERENCE_SHADER
}
namespace Production {
// PRODUCTION_SHADER
}

uint bits(float f) { uint b; std::memcpy(&b,&f,4); return b; }
float fromBits(uint b) { float f; std::memcpy(&f,&b,4); return f; }
void equal(float4 a, float4 b) {
    for(int i=0;i<4;i++) {
        if(a[i]!=b[i]) { std::cerr << "Shader output changed: " << a[i] << " vs " << b[i] << '\n'; std::abort(); }
        assert(std::isfinite(a[i]));
    }
}

int main(int argc, char **argv) {
    assert(argc==2);
    // Exercise the zero-envelope bounds independently at the hot-core
    // thresholds as well as across randomized fold/ribbon combinations.
    uint rng=0x938FE2A1;
    auto random=[&]() { rng=rng*1664525u+1013904223u; return float(rng>>8)/16777216.f; };
    auto hotCore=[](float b) { return pow(smoothstep(0.56f,0.96f,b),1.65f)*0.34f; };
    for(uint i=0;i<100000;i++) {
        float primary=i%7==0 ? 1.f : random();
        float secondary=i%11==0 ? 1.f : random();
        float ribbon=i%13==0 ? 1.f : random();
        float wave=random();
        if(i%4==0) wave=std::nextafter(0.56f, i%8==0 ? 0.f : 1.f);
        if(i%4==1) wave=std::nextafter(0.68f, i%8==1 ? 0.f : 1.f);
        float folded=primary*(0.54f+0.46f*secondary), keptFold=0, keptRibbon=0;
        float limit=max(wave,0.56f);
        if(wave<0.68f && primary*0.46f+0.22f>limit) {
            keptFold=folded;
            if(folded*0.46f+0.22f>limit) keptRibbon=ribbon;
        }
        assert(hotCore(max(wave,folded*0.46f+ribbon*0.22f))==hotCore(max(wave,keptFold*0.46f+keptRibbon*0.22f)));
    }
    std::ifstream input(argv[1]);
    uint count; input>>count; assert(count==41);
    std::vector<uint> streams(count);
    for(auto &s:streams) input>>s;
    uint64_t high,low, identities=0, pixels=0;
    uint curtainTopologies=0,coronaTopologies=0;
    uint64_t beforeNoise=0,afterNoise=0,beforeOptics=0,afterOptics=0;
    texture2d<half> originalTexture{&beforeNoise}, optimizedTexture{&afterNoise};
    while(input>>high>>low) {
        std::vector<float> values(count);
        for(auto &v:values) { uint b; input>>b; v=fromBits(b); }
        auto chunks=[](uint64_t word) { return float4(word&65535,(word>>16)&65535,(word>>32)&65535,(word>>48)&65535); };
        float4 seedA=chunks(low),seedB=chunks(high);
        for(uint i=0;i<count;i++) {
            assert(Production::auroraIdentityIndex(streams[i])==i);
            assert(bits(Reference::auroraMasterRandom(seedA,seedB,streams[i]))==bits(values[i]));
        }
        // Full scene tests cover all topology options over multiple identities,
        // times and pixel positions; all other identities test the hash ABI.
        if(identities<24) {
            uint curtains=2+uint(floor(values[0]*5));
            uint coronas=values[31]<0.14f ? 0 : (values[31]<0.72f ? 1 : 2);
            curtainTopologies|=1u<<curtains;
            coronaTopologies|=1u<<coronas;
        }
        if(identities<24) for(float time:{0.f,1.8f,60.f,10000.f}) {
            for(int y=0;y<18;y++) for(int x=0;x<24;x++) {
                float2 p=float2(x*17.13f,y*49.71f), size=float2(440,956);
                for(float mode:{0.f,1.f}) {
                    equal(Reference::auroraBorealis(p,half4(0,0,0,1),size,time,seedA,seedB,1.34f,originalTexture,mode,float2(0)),
                          Production::auroraBorealis(p,half4(0,0,0,1),size,time,values.data(),count,1.34f,optimizedTexture,mode,float2(0)));
                    ++pixels;
                }
            }
        }
        ++identities;
    }
    for(float scale:{0.38f,0.42f,0.46f,0.50f,0.54f}) {
        for(int layout=0;layout<4;layout++) for(int y=0;y<120;y++) for(int x=0;x<90;x++) {
            float2 p=float2(x*5.f,y*8.f)*scale;
            float2 a=float2(20,40)*scale, b=float2(40,400)*scale;
            float2 as=float2(400,320)*scale, bs=float2(370,500)*scale;
            if(layout==0) as=float2(0);
            if(layout<2) bs=float2(0);
            if(layout==3) b=float2(40,200)*scale; // overlapping panes: first wins
            equal(Reference::auroraPaneOptics(p,SwiftUI::Layer{&beforeOptics},a,as,18*scale,b,bs,18*scale,scale),
                  Production::auroraPaneOptics(p,SwiftUI::Layer{&afterOptics},a,as,18*scale,b,bs,18*scale,scale));
        }
    }
    assert(identities==388 && pixels>0);
    assert(curtainTopologies==0x7c && coronaTopologies==7);
    assert(afterNoise<beforeNoise && afterOptics<beforeOptics);
    std::cout << "Aurora differential tests passed: " << identities*count << " exact identity values, " << pixels
              << " identical Light/Dark sky pixels and 216000 identical optics pixels.\n"
              << "Noise texture reads: " << beforeNoise << " -> " << afterNoise << "; optics reads: " << beforeOptics << " -> " << afterOptics << ".\n";
}
