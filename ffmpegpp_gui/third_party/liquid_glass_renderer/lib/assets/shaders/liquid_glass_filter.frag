// Copyright 2025, Tim Lehmann for whynotmake.it
//
// This shader is based on a bunch of sources:
// - https://www.shadertoy.com/view/wccSDf for the refraction
// - https://iquilezles.org/articles/distfunctions2d/ for SDFs
// - Gracious help from @dkwingsmt for the Squircle SDF
//
// Feel free to use this shader in your own projects, it'd be lovely if you could
// give some credit like I did here.

#version 460 core
precision mediump float;

#define DEBUG_NORMALS 0

#include <flutter/runtime_effect.glsl>
#include "shared.glsl"

// 本地补丁（FFmpeg++ vendor 副本）：MAX_SHAPES 与 uShapeData 必须在
// #include "sdf.glsl" 之前声明 —— sdf.glsl 现在直接读 uShapeData 全局 uniform，
// 不再把它按值传参（按值传参会被翻译成 `float param_2[96] = shapeData;`，
// SkSL 禁止数组初始化器 → Windows/Linux 构建失败，flutter/flutter#182400）。
#define MAX_SHAPES 16

// Optimized uniform layout - grouped into vectors for better performance
layout(location = 0) uniform vec2 uSize;                    // width, height
layout(location = 1) uniform vec4 uGlassColor;             // r, g, b, a
layout(location = 2) uniform vec4 uOpticalProps;           // refractiveIndex, chromaticAberration, thickness, blend
layout(location = 3) uniform vec4 uLightConfig;            // angle, intensity, ambient, saturation
layout(location = 4) uniform vec2 uLightDirection;         // pre-computed cos(angle), sin(angle)
layout(location = 5) uniform float uNumShapes;             // numShapes  
layout(location = 6) uniform float uShapeData[MAX_SHAPES * 6];

#include "sdf.glsl"

// Extract individual values for backward compatibility
float uChromaticAberration = uOpticalProps.y;
float uLightAngle = uLightConfig.x;
float uLightIntensity = uLightConfig.y;
float uAmbientStrength = uLightConfig.z;
float uThickness = uOpticalProps.z;
float uRefractiveIndex = uOpticalProps.x;
float uBlend = uOpticalProps.w;
float uSaturation = uLightConfig.w;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
     
    // We invert screenUV Y on OpenGL to sample the textures correctly
    // fragCoord stays the same so shape positions are correct.
    #ifdef IMPELLER_TARGET_OPENGLES
        vec2 screenUV = vec2(fragCoord.x / uSize.x, 1.0 - (fragCoord.y / uSize.y));
    #else
        vec2 screenUV = vec2(fragCoord.x / uSize.x, fragCoord.y / uSize.y);
    #endif
    
    // Generate shape and calculate normal using shader-specific method
    // 本地补丁：sceneSDF 不再按值接收 uShapeData（SkSL 禁止数组初始化器）。
    float sd = sceneSDF(fragCoord, int(uNumShapes), uBlend);
    float foregroundAlpha = 1.0 - smoothstep(-2.0, 0.0, sd);

    // Early discard for pixels outside glass shapes to reduce overdraw
    if (foregroundAlpha < 0.01) {
        // Outside we sample the background texture
        fragColor = vec4(0, 0, 0, 0);
        return;
    }

    // 本地补丁：getNormal 改为接收预先算好的 SDF 梯度（SkSL 无 dFdx/dFdy）。
    vec3 normal = getNormal(sdfGradient(fragCoord, int(uNumShapes), uBlend, sd), sd, uThickness);
    
    // Use shared rendering pipeline
    fragColor = renderLiquidGlass(
        screenUV, 
        fragCoord, 
        uSize, 
        sd, 
        uThickness, 
        uRefractiveIndex, 
        uChromaticAberration, 
        uGlassColor, 
        uLightDirection, 
        uLightIntensity, 
        uAmbientStrength, 
        normal,
        foregroundAlpha,
        0.0,
        uSaturation
    );
    
    // Apply debug normals visualization using shared function
    #if DEBUG_NORMALS
        fragColor = debugNormals(fragColor, normal, true);
    #endif
}
