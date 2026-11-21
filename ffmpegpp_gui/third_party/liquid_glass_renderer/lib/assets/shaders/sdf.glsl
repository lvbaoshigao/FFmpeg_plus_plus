// Shape array uniforms - 6 floats per shape (type, centerX, centerY, sizeW, sizeH, cornerRadius)
// Reduced from 64 to 16 shapes to fit Impeller's uniform buffer limit (16 * 6 = 96 floats vs 384)
//
// 本地补丁（FFmpeg++ vendor 副本，非上游内容）：MAX_SHAPES 改由包含方在
// #include 之前定义 —— 下面直接读全局 uniform uShapeData，而 GLSL 单遍编译，
// uniform 必须先于函数体声明，可数组长度又依赖 MAX_SHAPES。保留兜底值。
#ifndef MAX_SHAPES
#define MAX_SHAPES 16
#endif

float sdfRRect( in vec2 p, in vec2 b, in float r ) {
    float shortest = min(b.x, b.y);
    r = min(r, shortest);
    vec2 q = abs(p)-b+r;
    return min(max(q.x,q.y),0.0) + length(max(q,0.0)) - r;
}

float sdfRect(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdfSquircle(vec2 p, vec2 b, float r) {
    float shortest = min(b.x, b.y);
    r = min(r, shortest);

    vec2 q = abs(p) - b + r;
    
    vec2 maxQ = max(q, 0.0);
    return min(max(q.x, q.y), 0.0) + sqrt(maxQ.x * maxQ.x + maxQ.y * maxQ.y) - r;
}

float sdfEllipse(vec2 p, vec2 r) {
    r = max(r, 1e-4);
    
    vec2 invR = 1.0 / r;
    vec2 invR2 = invR * invR;
    
    vec2 pInvR = p * invR;
    float k1 = length(pInvR);
    
    vec2 pInvR2 = p * invR2;
    float k2 = length(pInvR2);
    
    return (k1 * (k1 - 1.0)) / max(k2, 1e-4);
}

float smoothUnion(float d1, float d2, float k) {
    if (k <= 0.0) {
        return min(d1, d2);
    }
    float e = max(k - abs(d1 - d2), 0.0);
    return min(d1, d2) - e * e * 0.25 / k;
}

float getShapeSDF(float type, vec2 p, vec2 center, vec2 size, float r) {
    if (type == 1.0) { // squircle
        return sdfSquircle(p - center, size / 2.0, r);
    }
    if (type == 2.0) { // ellipse
        return sdfEllipse(p - center, size / 2.0);
    }
    if (type == 3.0) { // rounded rectangle
        return sdfRRect(p - center, size / 2.0, r);
    }
    return 1e9; // none
}

// 本地补丁：上游用 getShapeSDFFromArray(int index, ...) 带运行期下标读
// uShapeData，且把数组按值传参。两条都会让 SkSL 编译失败：
//   1) 按值传参 → `float param_2[96] = shapeData;`，SkSL 禁止数组初始化器；
//   2) uniform 数组的运行期下标 → error 81: index expression must be constant。
// 改为宏 + 字面量下标展开，让编译器做常量折叠。取值顺序与上游完全一致。
#define SHAPE_SDF_AT(I, p) \
    getShapeSDF(uShapeData[(I) * 6], (p), \
        vec2(uShapeData[(I) * 6 + 1], uShapeData[(I) * 6 + 2]), \
        vec2(uShapeData[(I) * 6 + 3], uShapeData[(I) * 6 + 4]), \
        uShapeData[(I) * 6 + 5])

float sceneSDF(vec2 p, int numShapes, float blend) {
    if (numShapes == 0) {
        return 1e9;
    }
    
    float result = SHAPE_SDF_AT(0, p);
    
    // 上游是「1~4 展开 + 5 以上走循环」，但循环的 min(int,int) 与运行期下标
    // 都不被 SkSL 接受。这里改成 16 个形状全部按常量展开；分支条件保证
    // numShapes 之外的形状不会参与运算，语义与上游逐字相同。
    if (numShapes >= 2)  { result = smoothUnion(result, SHAPE_SDF_AT(1,  p), blend); }
    if (numShapes >= 3)  { result = smoothUnion(result, SHAPE_SDF_AT(2,  p), blend); }
    if (numShapes >= 4)  { result = smoothUnion(result, SHAPE_SDF_AT(3,  p), blend); }
    if (numShapes >= 5)  { result = smoothUnion(result, SHAPE_SDF_AT(4,  p), blend); }
    if (numShapes >= 6)  { result = smoothUnion(result, SHAPE_SDF_AT(5,  p), blend); }
    if (numShapes >= 7)  { result = smoothUnion(result, SHAPE_SDF_AT(6,  p), blend); }
    if (numShapes >= 8)  { result = smoothUnion(result, SHAPE_SDF_AT(7,  p), blend); }
    if (numShapes >= 9)  { result = smoothUnion(result, SHAPE_SDF_AT(8,  p), blend); }
    if (numShapes >= 10) { result = smoothUnion(result, SHAPE_SDF_AT(9,  p), blend); }
    if (numShapes >= 11) { result = smoothUnion(result, SHAPE_SDF_AT(10, p), blend); }
    if (numShapes >= 12) { result = smoothUnion(result, SHAPE_SDF_AT(11, p), blend); }
    if (numShapes >= 13) { result = smoothUnion(result, SHAPE_SDF_AT(12, p), blend); }
    if (numShapes >= 14) { result = smoothUnion(result, SHAPE_SDF_AT(13, p), blend); }
    if (numShapes >= 15) { result = smoothUnion(result, SHAPE_SDF_AT(14, p), blend); }
    if (numShapes >= MAX_SHAPES) { result = smoothUnion(result, SHAPE_SDF_AT(15, p), blend); }
    
    return result;
}

// 本地补丁：SkSL 里 dFdx/dFdy 没有可用重载（spirv-cross 生成 `dFdx(...)`
// 会报 error 195/196: no match for dFdx）。SkSL 的内建名是小写 `dfdx`，
// 但 GLSL 侧无从调用。改用前向差分（步长 1 像素，与硬件导数同量纲）。
// 复用调用方已经算好的 sd，只需再求两次 SDF，避免重复计算。
vec2 sdfGradient(vec2 p, int numShapes, float blend, float sd) {
    const float e = 1.0;
    float gx = sceneSDF(p + vec2(e, 0.0), numShapes, blend) - sd;
    float gy = sceneSDF(p + vec2(0.0, e), numShapes, blend) - sd;
    return vec2(gx, gy);
}

// Calculate 3D normal from a precomputed SDF gradient
vec3 getNormal(vec2 sdfGrad, float sd, float thickness) {
    // The cosine and sine between normal and the xy plane
    float n_cos = max(thickness + sd, 0.0) / thickness;
    float n_sin = sqrt(max(0.0, 1.0 - n_cos * n_cos));
    
    return normalize(vec3(sdfGrad.x * n_cos, sdfGrad.y * n_cos, n_sin));
}
