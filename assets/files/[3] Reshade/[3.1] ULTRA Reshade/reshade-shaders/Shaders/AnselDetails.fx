
#include "ReShade.fxh"

texture2D texBlurred		{ Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; MipLevels = 1;};
sampler2D SamplerBlurred	{ Texture = texBlurred;	};

uniform float SHARPEN_AMOUNT < 
	ui_type = "drag"; 
	ui_min = 0.0; 
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Sharpen Amount [Ansel Details]";
	ui_tooltip = "Amount of sharpening applied to the image.";
> = 0.0;

uniform float CLARITY_AMOUNT < 
	ui_type = "drag"; 
	ui_min = -1.0; 
	ui_max = 1.0;	
	ui_step = 0.001;
	ui_label = "Clarity Amount [Ansel Details]";
	ui_tooltip = "Amount of Clarity applied to the image.";
> = 0.0;

uniform float HDR_AMOUNT < 
	ui_type = "drag"; 
	ui_min = -1.0; 
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "HDR Amount [Ansel Details]";
	ui_tooltip = "Amount of HDR coloring applied to the image.";
> = 0.0;

uniform float BLOOM_AMOUNT < 
	ui_type = "drag"; 
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Bloom Amount [Ansel Details]";
	ui_tooltip = "Amount of Bloom applied to the image.";
> = 0.0;

float4 ScaleableGaussianBlurLinear(sampler      tex,
                                   float2       texcoord,
                                   int          nSteps,
                                   float2       axis,
                                   float2       texelsize)
{
        float norm = -1.35914091423/(nSteps*nSteps);
        float4 accum = tex2D(tex,texcoord.xy);
        float2 offsetinc = axis * texelsize;

	float divisor = 0.5; //exp(0)

        [loop]
        for(float iStep = 1; iStep <= nSteps; iStep++)
        {
                float2 tapOffsetD = iStep * 2.0 + float2(-1.0,0.0);
                float2 tapWeightD = exp(tapOffsetD*tapOffsetD*norm);

                float tapWeightL = dot(tapWeightD,1.0);
                float tapOffsetL = dot(tapOffsetD,tapWeightD)/tapWeightL;

                accum += tex2Dlod(tex,float4(texcoord.xy+offsetinc * tapOffsetL,0,0)) * tapWeightL;
                accum += tex2Dlod(tex,float4(texcoord.xy-offsetinc * tapOffsetL,0,0)) * tapWeightL;
		divisor += tapWeightL;
        }
	accum /= 2.0 * divisor;
        return accum;
}

float4 BoxBlur(sampler tex, float2 texcoord, float2 texelsize)
{
        float3 blurData[9] = 
        {
                float3( 1.0, 1.0,0.50),
                float3( 0.0, 1.0,0.75),
                float3(-1.0, 1.0,0.50),
                float3( 1.0, 0.0,0.75),
                float3( 0.0, 0.0,1.00),
                float3(-1.0, 0.0,0.75), 
                float3( 1.0,-1.0,0.50),
                float3( 0.0,-1.0,0.75),
                float3(-1.0,-1.0,0.50)
        };

        float4 blur = 0.0;        
        for(int i=0; i<9; i++) { blur += tex2D(tex, texcoord.xy + blurData[i].xy * texelsize.xy) * blurData[i].z; }
        blur /= (4.0 * 0.5) + (4.0 * 0.75) + (1.0 * 1.0);
        return blur;
}


float4 PS_LargeBlur1(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return ScaleableGaussianBlurLinear(ReShade::BackBuffer,texcoord,15,float2(1,0),ReShade::PixelSize.xy);
}

float4 PS_SharpenClarity(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float4 color = tex2D(ReShade::BackBuffer,texcoord.xy);
	float4 largeblur = ScaleableGaussianBlurLinear(SamplerBlurred,texcoord,15,float2(0,1),ReShade::PixelSize.xy);
	float4 smallblur = BoxBlur(ReShade::BackBuffer,texcoord,ReShade::PixelSize);

	float a 		= dot(color.rgb,float3(0.25,0.5,0.25));
	float sqrta 		= sqrt(a);
	float b 		= dot(largeblur.rgb,float3(0.25,0.5,0.25));
	float c			= dot(smallblur.rgb,float3(0.25,0.5,0.25));

//HDR Toning
	float HDRToning = sqrta * lerp(sqrta*(2*a*b-a-2*b+2.0), (2*sqrta*b-2*b+1), b > 0.5); //modified soft light v1
	color = color / (a+1e-6) * lerp(a,HDRToning,HDR_AMOUNT);

//sharpen
	float Sharpen = (a-c)/SHARPEN_AMOUNT; //clamp to +- 1.0 / SHARPEN_AMOUNT with smooth falloff
	Sharpen = sign(Sharpen)*(pow(Sharpen,6)-abs(Sharpen))/(pow(Sharpen,6)-1);
	color += Sharpen*color*SHARPEN_AMOUNT;

//clarity
        float Clarity = (0.5 + a - b);
        Clarity = lerp(2*Clarity + a*(1-2*Clarity), 2*(1-Clarity)+(2*Clarity-1)*rsqrt(a), a > b); //modified soft light v2
        color.rgb *= lerp(1.0,Clarity,CLARITY_AMOUNT);

//bloom
        color.rgb = 1-(1-color.rgb)*(1-largeblur.rgb * BLOOM_AMOUNT);

	return color;
}

technique AnselDetails
{
	pass P1
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_LargeBlur1;
		RenderTarget = texBlurred;
	}
	pass P3
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_SharpenClarity;
	}
}