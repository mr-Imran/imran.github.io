#include "ReShade.fxh"

// CineREALISM Graphic MOD - Raindrops lens effect - DO NOT DISTRIBUTE WITHOUT PERMISSION OF OVER★LORD!
// Heartfelt - by Martijn Steinrucken aka BigWings - 2017
// Email:countfrolic@gmail.com Twitter:@The_ArtOfCode
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.

// I revisited the rain effect I did for another shader. This one is better in multiple ways:
// 1. The glass gets foggy.
// 2. Drops cut trails in the fog on the glass.
// 3. The amount of rain is adjustable (with Mouse.y)

// To have full control over the rain, uncomment the HAS_HEART define 

// A video of the effect can be found here:
// https://www.youtube.com/watch?v=uiF5Tlw22PI&feature=youtu.be

// 2020
// Small additions by LVutner - turbulence, and few other things...
// Credits for turbulence code - Meltac

uniform float fRainIntensity <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Rain Intensity [Droplets]";
> = 1.0;

uniform float fRainAmt <
	ui_type = "drag";
	ui_min = -1.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Rain Amount [Droplets]";
> = 1.0;

uniform float3 fDropAmt <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 10.0;
	ui_step = 1.0;
	ui_label = "Droplet Amount (Static,Layer1,Layer2) [Droplets]";
> = float3(2.0,1.0,1.0);

uniform float DROPS_TURBSIZE <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 64.0;
	ui_label = "Turbulence Size [Droplets]";
> = 12.0;

uniform float4 DROPS_TURBSHIFT <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 2.0;
	ui_label = "Turbulence Shift XYZ [Droplets]";
> = float4(0.35, 1.0, 0.0, 1);

#define DROPS_TURBTIME sin(0.1/3.0f)

uniform float DROPS_TURBCOF <
	ui_type = "drag";
	ui_min = 0.0;
	ui_max = 1.0;
	ui_step = 0.001;
	ui_label = "Drops Turbulence Coefficient [Droplets]";
> = 0.33;

uniform float iTime < source = "timer"; >;

float2 mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 permute(float3 x) { return mod289(((x*34.0)+1.0)*x); }
float4 permute(float4 x) { return mod289(((x*34.0)+1.0)*x); }

/// <summary>
/// 2D Noise by Ian McEwan, Ashima Arts.
/// <summary>
float snoise_2D (float2 v)
{
    const float4 C = float4(0.211324865405187,  // (3.0-sqrt(3.0))/6.0
                        0.366025403784439,  // 0.5*(sqrt(3.0)-1.0)
                        -0.577350269189626, // -1.0 + 2.0 * C.x
                        0.024390243902439); // 1.0 / 41.0

    // First corner
    float2 i  = floor(v + dot(v, C.yy) );
    float2 x0 = v -   i + dot(i, C.xx);

    // Other corners
    float2 i1;
    i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;

    // Permutations
    i = mod289(i); // Avoid truncation effects in permutation
    float3 p = permute( permute( i.y + float3(0.0, i1.y, 1.0 ))
        + i.x + float3(0.0, i1.x, 1.0 ));

    float3 m = max(0.5 - float3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m*m ;
    m = m*m ;

    // Gradients: 41 points uniformly over a line, mapped onto a diamond.
    // The ring size 17*17 = 289 is close to a multiple of 41 (41*7 = 287)

    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;

    // Normalise gradients implicitly by scaling m
    // Approximation of: m *= inversesqrt( a0*a0 + h*h );
    m *= 1.79284291400159 - 0.85373472095314 * ( a0*a0 + h*h );

    // Compute final noise value at P
    float3 g;
    g.x  = a0.x  * x0.x  + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

#define S(a, b, t) smoothstep(a, b, t)

float2 l_jh2(float2 f, float4 s, float l){
    // from Meltac (Dynamic Shaders 2.0 CTP)
	float2 x = s.xy, V = s.zw;
	float y = snoise_2D(f * float2(DROPS_TURBSIZE, DROPS_TURBSIZE))*.5;
	float4 r = float4(y, y, y, 1);
	r.xy = float2(r.x + r.z/4.f, r.y + r.x/2.f);
	r -= 1.5;
	r *= l;
	return (f + (x + V) *r.xy);
}

float3 N13(float p) {
    //  from DAVE HOSKINS
   float3 p3 = frac(float3(p,p,p) * float3(.1031,.11369,.13787));
   p3 += dot(p3, p3.yzx + 19.19);
   return frac(float3((p3.x + p3.y)*p3.z, (p3.x+p3.z)*p3.y, (p3.y+p3.z)*p3.x));
}

float4 N14(float t) {
	return frac(sin(t*float4(123., 1024., 1456., 264.))*float4(6547., 345., 8799., 1564.));
}
float N(float t) {
    return frac(sin(t*12345.564)*7658.76);
}

float Saw(float b, float t) {
	return S(0.0, b, t)*S(1.0, b, t);
}


float2 DropLayer2(float2 uv, float t) {
    float2 UV = uv;
    
    uv.y += t*0.75;
    float2 a = float2(6.0, 1.0);
    float2 grid = a*2.0;
    float2 id = floor(uv*grid);
    
    float colShift = N(id.x); 
    uv.y += colShift;
    
    id = floor(uv*grid);
    float3 n = N13(id.x*35.2+id.y*2376.1);
    float2 st = frac(uv*grid)-float2(0.5, 0);
    
    float x = n.x-.5;
    
    float y = UV.y*20.;
    float wiggle = sin(y+sin(y));
    x += wiggle*(.5-abs(x))*(n.z-.5);
    x *= .7;
    float ti = frac(t+n.z);
    y = (Saw(.85, ti)-.5)*.9+.5;
    float2 p = float2(x, y);
    
    float d = length((st-p)*a.yx);
    
    float mainDrop = S(.25, .0, d);
    
    float r = sqrt(S(1., y, st.y));
    float cd = abs(st.x-x);
    float trail = S(.23*r, .15*r*r, cd);
    float trailFront = S(-.02, .02, st.y-y);
    trail *= trailFront*r*r;
    
    y = UV.y;
    float trail2 = S(0.2*r, 0.0, cd);
    float droplets = max(0.0, (sin(y*(1.-y)*120.0)-st.y))*trail2*trailFront*n.z;
    y = frac(y*0.5)+(st.y-.5);
    float dd = length(st-float2(x, y));
    droplets = S(0.3, 0.0, dd);
    float m = mainDrop+droplets*r*trailFront;
    
    return float2(m, trail);
}

float StaticDrops(float2 uv, float t) {
	uv *= 35.0;
    
    float2 id = floor(uv);
    uv = frac(uv)-.5;
    float3 n = N13(id.x*107.45+id.y*3543.654);
    float2 p = (n.xy-0.5)*.7;
    float d = length(uv-p);
    
    float fade = Saw(0.025, frac(t+n.z));
    float c = S(0.3, 0.0, d)*frac(n.z*10.0)*fade;
    return c;
}

float2 Drops(float2 uv, float t, float l0, float l1, float l2) {
    float s = StaticDrops(lerp(uv, l_jh2(uv, DROPS_TURBSHIFT, DROPS_TURBTIME), DROPS_TURBCOF), t)*l0; 
    float2 m1 = DropLayer2(uv, t)*l1;
    float2 m2 = DropLayer2(uv*1.85, t)*l2;
    float c = s+m1.x+m2.x;
    c = S(.3, 1., c);
    
    return float2(c, max(m1.y*l0, m2.y*l1));
}

float4 PS_Droplets( float4 pos : SV_Position, float2 frgCoord : TEXCOORD) : SV_Target
{
	float2 fragCord = frgCoord * ReShade::ScreenSize; //this is because the original shader uses OpenGL's fragCoord, which is in texels rather than pixels
	float4 fragCol;
	float2 uv = (fragCord.xy-0.5*ReShade::ScreenSize.xy) / ReShade::ScreenSize.y;
	uv.y = 1.0-uv.y;
    float2 UV = fragCord.xy/ReShade::ScreenSize.xy;
	//UV.y = 1.0 - UV.y;
    float T = (iTime*0.001)*2.0;
    
    float t = T*.2;
    
    float rainAmount = (sin(T*0.05)*0.3+0.7)*fRainAmt;
    
    float maxBlur = 0.0;
    float minBlur = 0.0;
    
    float staticDrops = S(-0.5, 1.0, rainAmount)*fDropAmt.x;
    float layer1 = S(0.25, 0.75, rainAmount)*fDropAmt.y;
    float layer2 = S(0.0, 0.5, rainAmount)*fDropAmt.z;
    
    float2 c = Drops(uv, t, staticDrops, layer1, layer2);
    float2 e = float2(0.001, 0.0);
    float cx = Drops(uv+e, t, staticDrops, layer1, layer2).x;
    float cy = Drops(uv+e.yx, t, staticDrops, layer1, layer2).x;
    float2 n = float2(cx-c.x, cy-c.x);		// expensive normals
    
    float focus = lerp(maxBlur-c.y, minBlur, S(0.1, 0.2, c.x));
    float3 col = tex2Dlod(ReShade::BackBuffer, float4(UV+n,0,focus)).rgb;
    
    fragCol = float4(col, fRainIntensity);
	return fragCol;
}

technique Droplets {
    pass P1_Droplets {
        VertexShader=PostProcessVS;
        PixelShader=PS_Droplets;
    }
}