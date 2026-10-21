#include <string>

// SHADER_SUPPORT

namespace Production {
// PRODUCTION_SHADER
}

static float hue(float3 c) {
    float hi=max(c.r,max(c.g,c.b)), lo=min(c.r,min(c.g,c.b)), d=hi-lo;
    // Hue is undefined for neutral colors; half-precision output cannot retain
    // a meaningful hue in a near-white difference smaller than 0.001 either.
    if(d<0.001f) return -1;
    float h=hi==c.r ? (c.g-c.b)/d : hi==c.g ? 2+(c.b-c.r)/d : 4+(c.r-c.g)/d;
    h/=6;
    return h<0 ? h+1 : h;
}

static void close(float3 a, float3 b) {
    for(int i=0;i<3;i++) assert(std::abs(a[i]-b[i])<0.00002f);
}

static void checkColor(float3 sky) {
    float3 ink=Production::auroraComplementaryInk(sky);
    for(int i=0;i<3;i++) assert(std::isfinite(ink[i]) && ink[i]>=0 && ink[i]<=1.00001f);
    assert(max(ink.r,max(ink.g,ink.b))>0.9999f);
    assert(dot(ink,float3(0.2126f,0.7152f,0.0722f))>=0.41999f);
    float a=hue(sky), b=hue(ink);
    if(a>=0 && b>=0 && std::abs(std::abs(a-b)-0.5f)>=0.0001f) {
        std::cerr<<"Hue mismatch: sky "<<sky.r<<','<<sky.g<<','<<sky.b
                 <<" ink "<<ink.r<<','<<ink.g<<','<<ink.b<<" hues "<<a<<','<<b<<'\n';
        std::abort();
    }
}

static void preview(const char *directory, int scene, const std::vector<float>& values,
                    texture2d<half> texture) {
    const int width=200,height=400;
    std::string prefix=std::string(directory)+"/scene-"+std::to_string(scene);
    std::ofstream skyFile(prefix+"-sky.ppm",std::ios::binary);
    std::ofstream inkFile(prefix+"-ink.ppm",std::ios::binary);
    skyFile<<"P6\n"<<width<<' '<<height<<"\n255\n";
    inkFile<<"P6\n"<<width<<' '<<height<<"\n255\n";
    for(int y=0;y<height;y++) for(int x=0;x<width;x++) {
        float2 uv=float2(float(x)/width,float(y)/height);
        float3 sky=Production::auroraSceneColor(uv,1.8f,values.data(),1.34f,texture);
        float3 ink=Production::auroraComplementaryInk(sky);
        for(int i=0;i<3;i++) {
            skyFile.put(char(std::round(clamp(sky[i],0,1)*255)));
            inkFile.put(char(std::round(clamp(ink[i],0,1)*255)));
        }
    }
}

int run(int argc, char **argv) {
    assert(argc==2 || argc==3);
    for(int r=0;r<=32;r++) for(int g=0;g<=32;g++) for(int b=0;b<=32;b++)
        checkColor(float3(r/32.f,g/32.f,b/32.f));
    for(float3 sky:{float3(1,0,0),float3(0,1,0),float3(0,0,1),float3(0.6f,0.2f,0.9f)})
        for(float exposure:{0.02f,0.1f,0.5f,1.f})
            close(Production::auroraComplementaryInk(sky),Production::auroraComplementaryInk(sky*exposure));
    close(Production::auroraComplementaryInk(float3(1,0,0)),float3(0.08f,1,1));
    close(Production::auroraComplementaryInk(float3(0,0,1)),float3(1,1,0.08f));
    for(float gray:{0.f,0.001f,0.5f,1.f})
        close(Production::auroraComplementaryInk(float3(gray)),float3(1));

    // RGBA data stays in top-to-bottom order without image gamma conversion.
    // Check texel centers, bilinear interpolation, clamped edges and fallback.
    const uchar4 sentinel[]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}};
    auto sample=[&](float2 p,int bytes=16) {
        return Production::auroraTextInk(p,float4(0,0,1,1),float2(2,2),sentinel,bytes,1).rgb;
    };
    close(sample(float2(0.25f,0.25f)),float3(1,0,0));
    close(sample(float2(0.75f,0.25f)),float3(0,1,0));
    close(sample(float2(0.25f,0.75f)),float3(0,0,1));
    close(sample(float2(0.5f,0.5f)),float3(0.5f));
    close(sample(float2(-5,-5)),float3(1,0,0));
    close(sample(float2(5,5)),float3(1));
    close(sample(float2(0.5f),0),float3(1));

    std::ifstream input(argv[1]);
    uint count; input>>count; assert(count==41);
    uint stream; for(uint i=0;i<count;i++) input>>stream;
    uint64_t high,low,noise=0;
    texture2d<half> texture{&noise};
    int scenes=0,pixels=0,changed=0;
    uint hueBins=0;
    std::vector<float> cacheErrors;
    int cachedChanges=0,directChanges=0,cachedSamples=0;

    while(scenes<24 && input>>high>>low) {
        std::vector<float> values(count);
        for(auto &value:values) { uint bits; input>>bits; std::memcpy(&value,&bits,4); }
        for(float time:{0.f,1.8f,60.f}) {
            std::vector<uchar4> mapPixels;
            if(scenes<4) {
                for(int y=0;y<INK_MAP_HEIGHT;y++) for(int x=0;x<INK_MAP_WIDTH;x++) {
                    float2 uv=float2((x+0.5f)/INK_MAP_WIDTH,(y+0.5f)/INK_MAP_HEIGHT);
                    float3 ink=Production::auroraInkFieldColor(uv,time,values.data(),texture);
                    uchar4 pixel={uint8_t(std::round(ink.r*255)),uint8_t(std::round(ink.g*255)),uint8_t(std::round(ink.b*255)),255};
                    mapPixels.push_back(pixel);
                }
            }
            float2 mapSize=float2(INK_MAP_WIDTH,INK_MAP_HEIGHT);
            int mapBytes=int(mapPixels.size()*4);
            for(int y=0;y<32;y++) for(int x=0;x<20;x++) {
                float2 p=float2(x*20.f,y*25.f),size=float2(400,800);
                float3 sky=Production::auroraSceneColor(p/size,time,values.data(),1.34f,texture);
                float3 ink=Production::auroraComplementaryInk(sky);
                checkColor(sky);
                float h=hue(ink);
                if(h>=0) hueBins|=1u<<std::min(11,int(h*12));
                float3 neighbor=Production::auroraInkFieldColor((p+float2(8,0))/size,time,values.data(),texture);
                float3 difference=abs(ink-neighbor);
                bool changes=max(difference.r,max(difference.g,difference.b))>0.015f;
                if(changes) ++changed;
                if(!mapPixels.empty()) {
                    uint64_t before=noise;
                    float2 origin=float2(37,89);
                    float4 bounds=float4(-origin.x,-origin.y,size.x,size.y);
                    float4 result=Production::auroraTextInk(p-origin,bounds,mapSize,mapPixels.data(),mapBytes,0.7f);
                    float4 unshifted=Production::auroraTextInk(p,float4(0,0,size.x,size.y),mapSize,mapPixels.data(),mapBytes,0.7f);
                    close(result.rgb,unshifted.rgb);
                    assert(result.a==0.7f);
                    float4 next=Production::auroraTextInk(p+float2(8,0),float4(0,0,size.x,size.y),mapSize,mapPixels.data(),mapBytes,0.7f);
                    assert(noise==before);
                    float3 error=abs(result.rgb/0.7f-ink);
                    cacheErrors.push_back(max(error.r,max(error.g,error.b)));
                    float3 delta=abs(result.rgb-next.rgb)/0.7f;
                    if(max(delta.r,max(delta.g,delta.b))>0.015f) ++cachedChanges;
                    if(changes) ++directChanges;
                    ++cachedSamples;
                }
                ++pixels;
            }
        }
        if(argc==3 && scenes<4) preview(argv[2],scenes,values,texture);
        ++scenes;
    }
    int bins=0; for(uint b=hueBins;b;b>>=1) bins+=b&1u;
    assert(scenes==24 && bins>=8 && changed>pixels/20);
    std::sort(cacheErrors.begin(),cacheErrors.end());
    double mean=0;
    for(float error:cacheErrors) mean+=error/cacheErrors.size();
    float p95=cacheErrors[cacheErrors.size()*95/100];
    std::cout<<"Shared-map fidelity: mean max-channel error "<<mean<<", p95 "<<p95
             <<"; letter-scale changes "<<cachedChanges<<" cached / "<<directChanges<<" direct.\n";
    assert(mean<0.005 && p95<0.015);
    assert(cachedChanges>directChanges*0.90 && cachedChanges<directChanges*1.10);
    assert(cachedSamples>0);
    std::cout<<"Text shader tests passed: 35,937 RGB colors, complementary hue, exposure-independent color,\n"
             <<"brightness/value bounds, neutral stability, cached premultiplied opacity and window-offset continuity,\n"
             <<pixels<<" actual aurora samples across "<<scenes<<" identities and three times; "
             <<bins<<"/12 hue bins; "<<changed<<" samples change by >0.015 within 8 points.\n"
             <<"Glyph fills only interpolate the shared color bytes and use zero procedural noise reads.\n";
    return 0;
}
} // namespace AuroraTest (opened by the shared shader adapters)

int main(int argc, char **argv) { return AuroraTest::run(argc,argv); }
