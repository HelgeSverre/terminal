#include <metal_stdlib>
using namespace metal;
struct Instance { float4 rect; float4 uv; float4 color; float4 material; };
struct Vertex { float4 position [[position]]; float2 uv; float4 color; float4 material; };
vertex Vertex terminal_vertex(uint vertexID [[vertex_id]],uint instanceID [[instance_id]],constant Instance *instances [[buffer(0)]],constant float2 &extent [[buffer(1)]]) {
    const float2 corners[6] = {float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
    Instance i=instances[instanceID]; float2 p=corners[vertexID]; float2 px=i.rect.xy+p*i.rect.zw;
    Vertex out;out.position=float4(px.x/extent.x*2-1,1-px.y/extent.y*2,0,1);out.uv=i.uv.xy+p*i.uv.zw;out.color=i.color;out.material=i.material;return out;
}
fragment float4 terminal_fragment(Vertex in [[stage_in]],texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::nearest);
    float4 sampled=atlas.sample(s,in.uv);float4 tint=in.color;
    if (in.material.x < 0.5) { float coverage=sampled.r; return float4(tint.rgb*coverage*tint.a,coverage*tint.a); }
    return float4(sampled.rgb*tint.rgb*tint.a,sampled.a*tint.a);
}
fragment float4 terminal_image_fragment(Vertex in [[stage_in]],texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float4 rgba=image.sample(s,in.uv); // sRGB texture sampling decodes RGB to linear.
    return float4(rgba.rgb*rgba.a*in.color.rgb*in.color.a,rgba.a*in.color.a);
}
