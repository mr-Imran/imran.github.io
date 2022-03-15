#include "ReShade.fxh"

uniform float fStrength <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Strength [Ansel Sharpening]";
	ui_tooltip = "Amount of sharpen to apply";
> = 0.5;

uniform float fDenoise <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Denoise [Ansel Sharpening]";
	ui_tooltip = "Ignore Film Grain";
> = 0.15;

float GetLuma(float r, float g, float b)
{
    // Y from JPEG spec
    return 0.299f * r + 0.587f * g + 0.114f * b;
}

float GetLuma(float4 p)
{
    return GetLuma(p.x, p.y, p.z);
}

float Square(float v)
{
    return v * v;
}

// highlight fall-off start (prevents halos and noise in bright areas)
#define kHighBlock 0.65f
// offset reducing sharpening in the shadows
#define kLowBlock (1.0f / 256.0f)
#define kSharpnessMin (-1.0f / 14.0f)
#define kSharpnessMax (-1.0f / 6.5f)
#define kDenoiseMin (0.001f)
#define kDenoiseMax (-0.1f)

texture texOriginalColor
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
	Format = RGBA32F;
};
sampler samplerOriginalColor { Texture = texOriginalColor; };

float4 PS_OriginalColor(float4 vpos : SV_Position, float2 tex : TexCoord) : SV_Target
{
	float4 color=tex2D(ReShade::BackBuffer, tex);
	return color;
}

void PS_AnselSharpen(in float4 i_pos : SV_POSITION, in float2 i_uv : TEXCOORD, out float4 o_rgba : SV_Target)
{
    float4 x = tex2Dlod(ReShade::BackBuffer, float4(i_uv,0,0));

    float4 a = tex2Dlod(ReShade::BackBuffer, float4(mad(ReShade::PixelSize, int2(-1, 0), i_uv),0,0));
    float4 b = tex2Dlod(ReShade::BackBuffer, float4(mad(ReShade::PixelSize, int2(1, 0), i_uv),0,0)); 
    float4 c = tex2Dlod(ReShade::BackBuffer, float4(mad(ReShade::PixelSize, int2(0,1), i_uv),0,0));
    float4 d = tex2Dlod(ReShade::BackBuffer, float4(mad(ReShade::PixelSize, int2(0,-1), i_uv),0,0));

    float4 e = tex2Dlod(ReShade::BackBuffer, float4(mad(ReShade::PixelSize, int2(-1,-1), i_uv),0,0));
    float4 f = tex2Dlod(ReShade::BackBuffer, float4(mad(ReShade::PixelSize, int2(1,1), i_uv),0,0));
    float4 g = tex2Dlod(ReShade::BackBuffer, float4(mad(ReShade::PixelSize, int2(-1,1), i_uv),0,0));
    float4 h = tex2Dlod(ReShade::BackBuffer, float4(mad(ReShade::PixelSize, int2(1,-1), i_uv),0,0));

    float lx = GetLuma(x);

    float la = GetLuma(a);
    float lb = GetLuma(b);
    float lc = GetLuma(c);
    float ld = GetLuma(d);

    float le = GetLuma(e);
    float lf = GetLuma(f);
    float lg = GetLuma(g);
    float lh = GetLuma(h);

    // cross min/max
    const float ncmin = min(min(le, lf), min(lg, lh));
    const float ncmax = max(max(le, lf), max(lg, lh));

    // plus min/max
    float npmin = min(min(min(la, lb), min(lc, ld)), lx);
    float npmax = max(max(max(la, lb), max(lc, ld)), lx);

    // compute "soft" local dynamic range -- average of 3x3 and plus shape
    float lmin = 0.5f * min(ncmin, npmin) + 0.5f * npmin;
    float lmax = 0.5f * max(ncmax, npmax) + 0.5f * npmax;

    // compute local contrast enhancement kernel
    float lw = lmin / (lmax + kLowBlock);
    float hw = Square(1.0f - Square(max(lmax - kHighBlock, 0.0f) / ((1.0f - kHighBlock))));

    // noise suppression
    // Note: Ensure that the denoiseFactor is in the range of (10, 1000) on the CPU-side prior to launching this shader.
    // For example, you can do so by adding these lines
    //      const float kDenoiseMin = 0.001f;
    //      const float kDenoiseMax = 0.1f;
    //      float kernelDenoise = 1.0f / (kDenoiseMin + (kDenoiseMax - kDenoiseMin) * min(max(denoise, 0.0f), 1.0f));
    // where kernelDenoise is the value to be passed in to this shader (the amount of noise suppression is inversely proportional to this value),
    //       denoise is the value chosen by the user, in the range (0, 1)
	float kernelDenoise = 1.0f / (kDenoiseMin + (kDenoiseMax - kDenoiseMin) * min(max(fDenoise, 0.0f), 1.0f));
    const float nw = Square((lmax - lmin) * kernelDenoise);

    // pick conservative boost
    const float boost = min(min(lw, hw), nw);

    // run variable-sigma 3x3 sharpening convolution
    // Note: Ensure that the sharpenFactor is in the range of (-1.0f/14.0f, -1.0f/6.5f) on the CPU-side prior to launching this shader.
    // For example, you can do so by adding these lines
    //      const float kSharpnessMin = -1.0f / 14.0f;
    //      const float kSharpnessMax = -1.0f / 6.5f;
    //      float kernelSharpness = kSharpnessMin + (kSharpnessMax - kSharpnessMin) * min(max(sharpen, 0.0f), 1.0f);
    // where kernelSharpness is the value to be passed in to this shader,
    //       sharpen is the value chosen by the user, in the range (0, 1)
    float kernelSharpness = kSharpnessMin + (kSharpnessMax - kSharpnessMin) * min(max(fStrength, 0.0f), 1.0f);
    const float k = boost * kernelSharpness;

    float accum = lx;
    accum += la * k;
    accum += lb * k;
    accum += lc * k;
    accum += ld * k;
    accum += le * (k * 0.5f);
    accum += lf * (k * 0.5f);
    accum += lg * (k * 0.5f);
    accum += lh * (k * 0.5f);

    // normalize (divide the accumulator by the sum of convolution weights)
    accum /= 1.0f + 6.0f * k;

    // accumulator is in linear light space            
    float delta = accum - GetLuma(x);
    x.x += delta;
    x.y += delta;
    x.z += delta;

    o_rgba = x;
}

technique AnselSharpening {
	pass AnselOriginalColor
	{	
		RenderTarget = texOriginalColor;
		VertexShader = PostProcessVS;
		PixelShader = PS_OriginalColor;
	}
	
	pass AnselSharpening
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_AnselSharpen;
	}
}