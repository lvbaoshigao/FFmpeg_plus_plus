// Copyright 2025, Tim Lehmann for whynotmake.it
//
// Geometry precomputation shader for blended liquid glass shapes
// This shader pre-computes the refraction displacement and encodes it into a texture
// Only needs to be re-run when shape geometry or layout changes

#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

// 本地补丁（FFmpeg++ vendor 副本）：MAX_SHAPES 与 uShapeData 必须在
// #include "sdf.glsl" 之前声明 —— sdf.glsl 现在直接读 uShapeData 全局 uniform，
// 不再把它按值传参（按值传参会被翻译成 `float param_2[96] = shapeData;`，
// SkSL 禁止数组初始化器 → Windows/Linux 构建失败，flutter/flutter#182400）。
#define MAX_SHAPES 16

layout(location = 0) uniform vec2 uSize;
layout(location = 1) uniform vec4 uOpticalProps;
layout(location = 2) uniform float uNumShapes;
layout(location = 3) uniform float uShapeData[MAX_SHAPES * 6];

#include "sdf.glsl"
#include "displacement_encoding.glsl"

float uThickness = uOpticalProps.z;
float uRefractiveIndex = uOpticalProps.x;
float uBlend = uOpticalProps.w;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    
    #ifdef IMPELLER_TARGET_OPENGLES
        vec2 screenUV = vec2(fragCoord.x / uSize.x, 1.0 - (fragCoord.y / uSize.y));
    #else
        vec2 screenUV = vec2(fragCoord.x / uSize.x, fragCoord.y / uSize.y);
    #endif
    
    // 本地补丁：sceneSDF 不再按值接收 uShapeData（SkSL 禁止数组初始化器）。
    float sd = sceneSDF(fragCoord, int(uNumShapes), uBlend);
    
    float foregroundAlpha = 1.0 - smoothstep(-2.0, 0.0, sd);
    if (foregroundAlpha < 0.01) {
        fragColor = vec4(0.0);
        return;
    }
    
    // 本地补丁：SkSL 没有 dFdx/dFdy 重载，改用 sdf.glsl 里的中心差分。
    vec2 sdfGrad = sdfGradient(fragCoord, int(uNumShapes), uBlend, sd);
    
    float n_cos = max(uThickness + sd, 0.0) / uThickness;
    float n_sin = sqrt(max(0.0, 1.0 - n_cos * n_cos));
    
    vec3 normal = normalize(vec3(sdfGrad.x * n_cos, sdfGrad.y * n_cos, n_sin));
    
    if (sd >= 0.0 || uThickness <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }
    
    float x = uThickness + sd;
    float sqrtTerm = sqrt(max(0.0, uThickness * uThickness - x * x));
    float height = mix(sqrtTerm, uThickness, float(sd < -uThickness));
    
    float baseHeight = uThickness * 8.0;
    vec3 incident = vec3(0.0, 0.0, -1.0);
    
    float invRefractiveIndex = 1.0 / uRefractiveIndex;
    vec3 baseRefract = refract(incident, normal, invRefractiveIndex);
    float baseRefractLength = (height + baseHeight) / max(0.001, abs(baseRefract.z));
    vec2 displacement = baseRefract.xy * baseRefractLength;
    
    float maxDisplacement = uThickness * 10.0;
    
    fragColor = encodeDisplacementData(displacement, maxDisplacement, height, uThickness, foregroundAlpha);
}
