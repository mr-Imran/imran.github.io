#include "ReShade.fxh"

uniform float fFocusDepth <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Focus plane [Ansel DoF]";
	ui_tooltip = "Use this to set the focus plane distance of the DoF effect.";
> = 0.5;

uniform float fFarBlurCurve <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Far Blur Curve [Ansel DoF]";
	ui_tooltip = "Curve of blur behind focus plane.";
> = 0.15;

uniform float fNearBlurCurve <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Near Blur Curve [Ansel DoF]";
	ui_tooltip = "Curve of blur closer than focus plane.";
> = 0.85;

uniform float fBlurRadius <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Blur Radius [Ansel DoF]";
	ui_tooltip = "Maximal blur radius.";
> = 0.5;


///////////TEXTURES AND DEFINITIONS////////////
#define ui_iShapeVertices 6 //float ui_iShapeVertices;          //bokeh shape vertices, 5 == pentagon, 6 == hexagon ...
#define ui_fShapeRoundness 1//float ui_fShapeRoundness;         //deforms polygon to circle, 0 == polygon, 1 == circle
#define ui_fBokehIntensity 0.7//float ui_fBokehIntensity;         //intensity of bokeh highlighting

texture2D texCommon0 { Width = BUFFER_WIDTH;   Height = BUFFER_HEIGHT;   Format = RGBA8; };
sampler2D SamplerCommon0 { Texture = texCommon0;	};
texture2D texCommon1 { Width = BUFFER_WIDTH;   Height = BUFFER_HEIGHT;   Format = RGBA8; };
sampler2D SamplerCommon1 { Texture = texCommon1;	};

//------------------------------------------------------------------

/* calculates out-of-focus value for given depth and focus plane distance.
   where 0 means pixel is in focus, 1 means focus is entirely out of focus.
   Aggressive leak reduction basically shifts depth to minimum of neighbour pixels
   to completely eradicate color leaking of main bokeh pass. This introduces a sharp
   border around sharp objects, which gets removed by gaussian blur after bokeh filter
   which uses CoC without leak reduction.*/
float CircleOfConfusion(float2 texcoord, bool aggressiveLeakReduction)
{
	float2 depthdata; //x - linear scene depth, y - linear scene focus
	float scenecoc;   //blur value, signed by position relative to focus plane

    depthdata.x = ReShade::GetLinearizedDepth(texcoord.xy);

	[branch]
	if(aggressiveLeakReduction)
	{
        float3 neighbourOffsets = float3(ReShade::PixelSize.xy, 0);
        //sadly, flipped depth buffers etc don't allow for gather or linearizing in batch
        float4 neighbourDepths = float4(ReShade::GetLinearizedDepth(texcoord.xy - neighbourOffsets.xz), //left
                                        ReShade::GetLinearizedDepth(texcoord.xy + neighbourOffsets.xz), //right
                                        ReShade::GetLinearizedDepth(texcoord.xy - neighbourOffsets.zy), //top
                                        ReShade::GetLinearizedDepth(texcoord.xy + neighbourOffsets.zy));//bottom

		float neighbourMin = min(min(neighbourDepths.x,neighbourDepths.y),min(neighbourDepths.z,neighbourDepths.w));
		depthdata.x = lerp(min(neighbourMin, depthdata.x), depthdata.x, 0.001);
	}

	depthdata.y =  fFocusDepth*fFocusDepth*fFocusDepth;

	[branch]
	if(depthdata.x < depthdata.y)
	{
		scenecoc = depthdata.x / depthdata.y - 1.0;
		scenecoc = ldexp(scenecoc, -0.5*fNearBlurCurve*fNearBlurCurve*10*10);
	}
	else
	{
		scenecoc = (depthdata.x - depthdata.y)/(ldexp(depthdata.y, pow(fFarBlurCurve * 10, 1.5)) - depthdata.y);
	    scenecoc = saturate(scenecoc);
	}

	return abs(scenecoc);
}

float2 CoC2BlurRadius(float CoC)
{
	return float2(1.0, (ReShade::ScreenSize.x / ReShade::ScreenSize.y)) * CoC * fBlurRadius * 6e-4;
}

//------------------------------------------------------------------
// Pixel Shaders
//------------------------------------------------------------------

/* writes CoC to alpha channel. Early firefly reduction with depth
masking to prevent color leaking in main bokeh pass.*/
float4 PS_CoC2Alpha( float4 vpos : SV_Position, float2 txcoord : TEXCOORD) : SV_Target
{
	float4 color = tex2D(ReShade::BackBuffer, txcoord.xy);

	static const float2 sampleOffsets[4] = {float2( 1.5, 0.5) * ReShade::PixelSize.xy,
		                                	float2( 0.5,-1.5) * ReShade::PixelSize.xy,
				                			float2(-1.5,-0.5) * ReShade::PixelSize.xy,
				                			float2(-0.5, 1.5) * ReShade::PixelSize.xy};

	float centerDepth = ReShade::GetLinearizedDepth(txcoord.xy);
    float2 sampleCoord = 0.0;
    float3 neighbourOffsets = float3(ReShade::PixelSize.xy, 0);
    float4 coccolor = 0.0;

	[loop]
	for(int i=0; i<4; i++)
	{
		sampleCoord.xy = txcoord.xy + sampleOffsets[i];
		float3 sampleColor = tex2Dlod(ReShade::BackBuffer,float4(sampleCoord.xy,0,0)).rgb;

        float4 sampleDepths = float4(ReShade::GetLinearizedDepth(sampleCoord.xy + neighbourOffsets.xz),  //right
                                     ReShade::GetLinearizedDepth(sampleCoord.xy - neighbourOffsets.xz),  //left
                                     ReShade::GetLinearizedDepth(sampleCoord.xy + neighbourOffsets.zy),  //bottom
                                     ReShade::GetLinearizedDepth(sampleCoord.xy - neighbourOffsets.zy)); //top

        float sampleDepthMin = min(min(sampleDepths.x,sampleDepths.y),min(sampleDepths.z,sampleDepths.w));

		sampleColor /= 1.0 + max(max(sampleColor.r, sampleColor.g), sampleColor.b);

		float sampleWeight = saturate(sampleDepthMin * rcp(centerDepth + 1e-6) + 1e-3);
		coccolor += float4(sampleColor.rgb * sampleWeight, sampleWeight);
	}

	coccolor.rgb /= coccolor.a;
	coccolor.rgb /= 1.0 - max(coccolor.r, max(coccolor.g, coccolor.b));

	color.rgb = lerp(color.rgb, coccolor.rgb, saturate(coccolor.w * 8.0));
	color.w = CircleOfConfusion(txcoord.xy, 1);
    color.w = saturate(color.w * 0.5 + 0.5);
	return color;
}

//------------------------------------------------------------------

/* main bokeh blur pass.*/
float4 PS_Bokeh( float4 vpos : SV_Position, float2 txcoord : TEXCOORD) : SV_Target
{
	float4 BokehSum, BokehMax;
	BokehMax		        = tex2D(SamplerCommon0, txcoord.xy);
    BokehSum                        = BokehMax;
	float weightSum 		= 1.0;
	float CoC 			= abs(BokehSum.w * 2.0 - 1.0);
	float2 bokehRadiusScaled	= CoC2BlurRadius(CoC);
	float nRings 			= round(bokehRadiusScaled + 2 + (dot(vpos.xy,1) % 2)) * 0.5;

	bokehRadiusScaled /= nRings;
	CoC /= nRings;

	float2 currentVertex,nextVertex,matrixVector;
	sincos(radians(10.0), currentVertex.y,currentVertex.x);
	sincos(radians(360.0 / round(ui_iShapeVertices)),matrixVector.x,matrixVector.y);

	float2x2 rotMatrix = float2x2(matrixVector.y,-matrixVector.x,matrixVector.x,matrixVector.y);

	[fastopt]
    for (int iVertices = 0; iVertices < ui_iShapeVertices; iVertices++)
    {
	nextVertex = mul(currentVertex.xy, rotMatrix);
        [fastopt]
            for(float iRings = 1; iRings <= nRings; iRings++)
            {
                [fastopt]
                for(float iSamplesPerRing = 0; iSamplesPerRing < iRings; iSamplesPerRing++)
                {
	            float2 sampleOffset = lerp(currentVertex,nextVertex,iSamplesPerRing/iRings);

		      	//sampleOffset *= (1.0-ui_fShapeRoundness) + rsqrt(dot(sampleOffset,sampleOffset))*ui_fShapeRoundness;
		      	sampleOffset *= rsqrt(dot(sampleOffset,sampleOffset));

	            float4 sampleBokeh 	= tex2Dlod(SamplerCommon0,float4(txcoord.xy + sampleOffset.xy * bokehRadiusScaled * iRings,0,0));
	            float sampleWeight	= saturate(1e6 * (abs(sampleBokeh.a * 2.0 - 1.0) - CoC * (float)iRings) + 1.0);

	            sampleBokeh.rgb *= sampleWeight;
	            weightSum 		+= sampleWeight;
	            BokehSum 		+= sampleBokeh;
	            BokehMax 		= max(BokehMax,sampleBokeh);
               }
           }

           currentVertex = nextVertex;
       }

	//scale bokeh intensity by blur level to make transition from sharp to blurred area less apparent
    return lerp(BokehSum / weightSum, BokehMax, ui_fBokehIntensity * saturate(CoC*nRings*4.0));
}

/* combines blurred bokeh output with sharp original texture.
Calculate CoC a second time because gaussian blur is not prone to
obvious color leaking. */
float4 PS_Combine( float4 vpos : SV_Position, float2 txcoord : TEXCOORD) : SV_Target
{
	float4 blurredColor   = tex2D(SamplerCommon1, txcoord.xy);
	float4 originalColor  = tex2D(ReShade::BackBuffer, txcoord.xy);

	float CoC 		 = CircleOfConfusion(txcoord.xy, 0);
	float2 bokehRadiusScaled = CoC * fBlurRadius * 25;

	#define linearstep(a,b,x) saturate((x-a)/(b-a))
	float blendWeight = linearstep(0.25, 1.0, bokehRadiusScaled.x);
	blendWeight = sqrt(blendWeight);

	float4 color;
	color.rgb      = lerp(originalColor.rgb, blurredColor.rgb, blendWeight);
	color.a        = saturate(CoC * 2.0) * 0.5 + 0.5;
	return color;
}

/* blur color (and blur radius) to solve common DoF technique
issue of having sharp transitions in blurred regions because of
blurred color vs sharp depth info*/
float4 PS_Gauss1( float4 vpos : SV_Position, float2 txcoord : TEXCOORD) : SV_Target
{
	float4 centerTap = tex2D(SamplerCommon0, txcoord.xy);
    float CoC = abs(centerTap.a * 2.0 - 1.0);

    float nSteps 		= floor(CoC * (2.0));
	float expCoeff 		= -2.0 * rcp(nSteps * nSteps + 1e-3); //sigma adjusted for blur width
	float2 blurAxisScaled 	= float2(1,0) * ReShade::PixelSize.xy;

	float4 gaussianSum = 0.0;
	float  gaussianSumWeight = 1e-3;

	for(float iStep = -nSteps; iStep <= nSteps; iStep++)
	{
		float currentWeight = exp(iStep * iStep * expCoeff);
		float currentOffset = 2.0 * iStep - 0.5; //Sample between texels to double blur width at no cost

		float4 currentTap = tex2Dlod(SamplerCommon0,float4(txcoord.xy + blurAxisScaled.xy * currentOffset,0,0));
		currentWeight *= saturate(abs(currentTap.a * 2.0 - 1.0) - CoC * 0.25); //bleed fix

		gaussianSum += currentTap * currentWeight;
		gaussianSumWeight += currentWeight;
	}

	gaussianSum /= gaussianSumWeight;

	float4 color;
	color.rgb = lerp(centerTap.rgb, gaussianSum.rgb, saturate(gaussianSumWeight));
    color.a = centerTap.a;
	return color;
}

float4 PS_Gauss2( float4 vpos : SV_Position, float2 txcoord : TEXCOORD) : SV_Target
{
	float4 centerTap = tex2D(SamplerCommon1, txcoord.xy);
    float CoC = abs(centerTap.a * 2.0 - 1.0);

    float nSteps 		= floor(CoC * (2.0));
	float expCoeff 		= -2.0 * rcp(nSteps * nSteps + 1e-3); //sigma adjusted for blur width
	float2 blurAxisScaled 	= float2(0,1) * ReShade::PixelSize.xy;

	float4 gaussianSum = 0.0;
	float  gaussianSumWeight = 1e-3;

	for(float iStep = -nSteps; iStep <= nSteps; iStep++)
	{
		float currentWeight = exp(iStep * iStep * expCoeff);
		float currentOffset = 2.0 * iStep - 0.5; //Sample between texels to double blur width at no cost

		float4 currentTap = tex2Dlod(SamplerCommon1,float4(txcoord.xy + blurAxisScaled.xy * currentOffset, 0,0));
		currentWeight *= saturate(abs(currentTap.a * 2.0 - 1.0) - CoC * 0.25); //bleed fix

		gaussianSum += currentTap * currentWeight;
		gaussianSumWeight += currentWeight;
	}

	gaussianSum /= gaussianSumWeight;

	float4 color;
	color.rgb = lerp(centerTap.rgb, gaussianSum.rgb, saturate(gaussianSumWeight));
    color.a = centerTap.a;
	return color;
}

technique AnselDoF
{
	pass AnselDoF_1
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_CoC2Alpha;
		RenderTarget = texCommon0;
	}
	pass AnselDoF_2
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_Bokeh;
		RenderTarget = texCommon1;
	}
	pass AnselDoF_3
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_Combine;
		RenderTarget = texCommon0;
	}
	pass AnselDoF_4
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_Gauss1;
		RenderTarget = texCommon1;
	}
	pass AnselDoF_5
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_Gauss2;
	}
}