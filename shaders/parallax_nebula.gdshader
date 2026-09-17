// parallax_nebula.gdshader - 视差Layer0：深层星云（最远层，motion_scale=0.2）
// 实现：周期性包裹的格子值噪声 + 3阶fbm，纯代码生成极暗紫蓝星云，无任何贴图资源
// 无缝：基础晶格数为2的幂，每个octave周期倍增且整除平铺周期，纹理四边严格连续
// 性能：单张1024×1024色块 + motion_mirroring平铺，每像素仅3次廉价值噪声，GPU增量可忽略

shader_type canvas_item;

// 星云暗部颜色（无云区域，必须比bg_color略亮一点点，避免与底色糊成一片）
uniform vec4 tint_deep : source_color = vec4(0.11, 0.09, 0.20, 1.0);
// 星云雾部颜色（云芯最亮处仍极暗，对比度严禁超过玩家/敌人等实体）
uniform vec4 tint_glow : source_color = vec4(0.24, 0.17, 0.42, 1.0);
// 整体不透明度倍率（保守压低，只做氛围暗示）
uniform float alpha_scale = 0.50;
// 基础晶格数（2的幂；改此值后fbm循环内的周期仍自动整除，保持无缝）
const float BASE_TILES = 4.0;

// 二维哈希：晶格坐标 → [0,1) 伪随机值
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// 周期包裹值噪声：晶格索引按 period 取模，纹理边缘两侧采样同一晶格 → 任意周期无缝
float periodic_value_noise(vec2 uv, float period) {
	vec2 p = uv * period;
	vec2 i = floor(p);
	vec2 f = fract(p);
	// 四个角点全部取模，保证 period-1 与 0 位置的角点值一致
	vec2 iw = mod(i, period);
	float a = hash21(iw);
	float b = hash21(mod(iw + vec2(1.0, 0.0), period));
	float c = hash21(mod(iw + vec2(0.0, 1.0), period));
	float d = hash21(mod(iw + vec2(1.0, 1.0), period));
	// 平滑插值（Hermite阶梯），消除晶格硬边
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 分形布朗运动：多倍频噪声叠加，频率倍增/振幅减半，产生自然云雾层次
float fbm(vec2 uv) {
	float v = 0.0;
	float amp = 0.55;
	float period = BASE_TILES;
	for (int k = 0; k < 3; k++) {
		v += amp * periodic_value_noise(uv, period);
		period *= 2.0;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	float n = fbm(UV);
	// 阈值平滑：只有较高噪声值形成可见云团，大部分区域保持深底色
	float clouds = smoothstep(0.35, 0.95, n);
	vec3 col = mix(tint_deep.rgb, tint_glow.rgb, clouds);
	// 缓慢呼吸（极慢正弦，静态截图也成立，避免玩家察觉为动画干扰）
	float breathe = 0.92 + 0.08 * sin(TIME * 0.25 + n * 6.2831);
	COLOR = vec4(col, clouds * alpha_scale * breathe);
}
