#include <metal_stdlib>
using namespace metal;

struct WarpVertex {
  float2 position;
  float2 uv;
};

struct WaveVertex {
  float2 position;
};

struct WaveColorVertex {
  float2 position;
  float4 color;
};

struct ShapeVertex {
  float2 position;
  float4 color;
  float2 uv;
};

struct WarpOut {
  float4 position [[position]];
  float2 uv;
  float2 uvOrig;
};

struct WarpUniforms {
  float2 resolution;
  float time;
  float decay;
  float rms;
  float beat;
  float4 waveColorAlpha;
  float4 waveParams;
  float4 echoParams;
};

struct OutputOut {
  float4 position [[position]];
  float2 uv;
};

struct WaveColorOut {
  float4 position [[position]];
  float4 color;
};

struct OutputUniforms {
  float2 resolution;
  float time;
  float fShader;
  float4 echoParams;
  float4 postParams0;
  float4 postParams1;
  float4 hueBase0;
  float4 hueBase1;
  float4 hueBase2;
  float4 hueBase3;
};

struct WaveUniforms {
  float2 thickOffset;
  float4 color;
};

struct ShapeUniforms {
  float textured;
  float3 padding;
};

struct ShapeOut {
  float4 position [[position]];
  float4 color;
  float2 uv;
};

vertex WarpOut warp_vertex(const device WarpVertex *vertices [[buffer(0)]],
                           uint vid [[vertex_id]]) {
  WarpOut out;
  float2 pos = vertices[vid].position;
  out.position = float4(pos, 0.0, 1.0);
  out.uv = vertices[vid].uv;
  out.uvOrig = pos * 0.5 + 0.5;
  return out;
}

fragment float4 warp_fragment(WarpOut in [[stage_in]],
                              constant WarpUniforms &u [[buffer(0)]],
                              const device float *spectrum [[buffer(1)]],
                              texture2d<float> prevTexture [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
  float2 uv = in.uv;
  float3 base = prevTexture.sample(samp, uv).rgb * u.decay;
  return float4(base, 1.0);
}

vertex OutputOut output_vertex(uint vid [[vertex_id]]) {
  float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
  float2 pos = positions[vid];
  OutputOut out;
  out.position = float4(pos, 0.0, 1.0);
  out.uv = pos * 0.5 + 0.5;
  return out;
}

fragment float4 output_fragment(OutputOut in [[stage_in]],
                                constant OutputUniforms &u [[buffer(0)]],
                                texture2d<float> targetTexture [[texture(0)]],
                                sampler samp [[sampler(0)]]) {
  float2 uv = clamp(in.uv, 0.0, 1.0);
  float3 color = targetTexture.sample(samp, uv).rgb;
  float3 echoColor = color;
  float echoAlpha = clamp(u.echoParams.x, 0.0, 1.0);
  float echoZoom = max(u.echoParams.y, 0.0001);
  float echoOrient = u.echoParams.z;
  if (echoAlpha > 0.001) {
    float orientHoriz = fmod(echoOrient, 2.0);
    float orientX = orientHoriz != 0.0 ? -1.0 : 1.0;
    float orientY = echoOrient >= 2.0 ? -1.0 : 1.0;
    float2 uvEcho = ((uv - 0.5) * (1.0 / echoZoom) * float2(orientX, orientY)) + 0.5;
    echoColor = targetTexture.sample(samp, uvEcho).rgb;
  }

  float darkenCenter = u.postParams1.z;
  if (darkenCenter > 0.5) {
    float2 res = max(u.resolution, float2(1.0, 1.0));
    float aspecty = res.x > res.y ? res.y / res.x : 1.0;
    float halfSize = 0.05;
    float2 clip = uv * 2.0 - 1.0;
    float denomX = max(0.0001, halfSize * aspecty);
    float denomY = max(0.0001, halfSize);
    float sum = fabs(clip.x) / denomX + fabs(clip.y) / denomY;
    float weight = clamp(1.0 - sum, 0.0, 1.0);
    float factor = 1.0 - weight * (3.0 / 32.0);
    color *= factor;
    echoColor *= factor;
  }

  color = mix(color, echoColor, echoAlpha);
  float gammaAdj = max(u.postParams0.x, 0.0001);
  float brighten = u.postParams0.y;
  float darken = u.postParams0.z;
  float invert = u.postParams0.w;
  float solarize = u.postParams1.x;
  color *= gammaAdj;

  float x = uv.x;
  float y = uv.y;
  float3 hue = u.hueBase0.xyz * x * y
             + u.hueBase1.xyz * (1.0 - x) * y
             + u.hueBase2.xyz * x * (1.0 - y)
             + u.hueBase3.xyz * (1.0 - x) * (1.0 - y);
  if (u.fShader >= 1.0) {
    color *= hue;
  } else if (u.fShader > 0.001) {
    color *= (1.0 - u.fShader) + (u.fShader * hue);
  }

  if (brighten > 0.5) {
    color = sqrt(color);
  }
  if (darken > 0.5) {
    color = color * color;
  }
  if (solarize > 0.5) {
    color = color * (1.0 - color) * 4.0;
  }
  if (invert > 0.5) {
    color = 1.0 - color;
  }
  return float4(color, 1.0);
}

vertex OutputOut wave_vertex(const device WaveVertex *vertices [[buffer(0)]],
                             constant WaveUniforms &u [[buffer(1)]],
                             uint vid [[vertex_id]]) {
  OutputOut out;
  float2 pos = vertices[vid].position + u.thickOffset;
  out.position = float4(pos, 0.0, 1.0);
  out.uv = float2(0.0, 0.0);
  return out;
}

fragment float4 wave_fragment(OutputOut in [[stage_in]],
                              constant WaveUniforms &u [[buffer(1)]]) {
  return u.color;
}

vertex WaveColorOut wave_color_vertex(const device WaveColorVertex *vertices [[buffer(0)]],
                                      constant WaveUniforms &u [[buffer(1)]],
                                      uint vid [[vertex_id]]) {
  WaveColorOut out;
  float2 pos = vertices[vid].position + u.thickOffset;
  out.position = float4(pos, 0.0, 1.0);
  out.color = vertices[vid].color;
  return out;
}

fragment float4 wave_color_fragment(WaveColorOut in [[stage_in]]) {
  return in.color;
}

vertex ShapeOut shape_vertex(const device ShapeVertex *vertices [[buffer(0)]],
                             uint vid [[vertex_id]]) {
  ShapeOut out;
  out.position = float4(vertices[vid].position, 0.0, 1.0);
  out.color = vertices[vid].color;
  out.uv = vertices[vid].uv;
  return out;
}

fragment float4 shape_fragment(ShapeOut in [[stage_in]],
                               constant ShapeUniforms &u [[buffer(0)]],
                               texture2d<float> prevTexture [[texture(0)]],
                               sampler samp [[sampler(0)]]) {
  float4 color = in.color;
  if (u.textured > 0.5) {
    float3 tex = prevTexture.sample(samp, in.uv).rgb;
    color = float4(tex, 1.0) * color;
  }
  return color;
}
