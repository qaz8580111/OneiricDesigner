// parallax_debris.gdshader - 视差Layer1：漂浮碎片/符文尘（中景层，motion_scale=0.5）
// 实现：把平铺周期划分为6×6晶格，晶格哈希决定"是否有碎片/大小/位置"，
//       碎片为暗色小方块并缓慢向上漂移、独立相位闪烁；晶格索引取模→四边无缝
// 性能：1024以内单色块 + mirroring平铺，无节点/Tween，碎片数随分辨率恒定

shader_type canvas_item;

// 碎片颜色（冷灰紫，低亮度，暗示梦境残骸而非实体）
uniform vec4 shard_color : source_color = vec4(0.45, 0.48, 0.66, 1.0);
// 单张纹理内的晶格数（x/y方向碎片格数量）
uniform vec2 cells = vec2(6.0, 6.0);
// 每格生成碎片的概率（0~1，控制稀疏度）
uniform float density = 0.45;
// 漂移速度（UV/秒，正值采样点上移→视觉上碎片上浮）
uniform float drift_speed = 0.008;

// 二维哈希（与星云shader同一族确定性随机）
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	// y坐标减去时间量：纹理内容整体缓慢上浮；取模在晶格层完成，漂移不出接缝
	vec2 p = vec2(UV.x * cells.x, UV.y * cells.y - TIME * drift_speed * cells.y);
	vec2 id = floor(p); // 晶格索引
	vec2 g = fract(p);  // 晶格内局部坐标 0~1
	// 周期包裹：跨纹理边界的晶格与对侧共用哈希值
	vec2 idw = mod(id, cells);
	float h = hash21(idw);
	// 哈希未命中概率阈值：该格为空，直接丢弃片元
	if (h < 1.0 - density) {
		discard;
	}
	// 碎片尺寸（晶格比例2.5%~7%）与中心位置（25%~75%）均由哈希固定，闪烁不动摇
	float size_mix = mix(0.025, 0.07, hash21(idw + 7.13));
	vec2 center = vec2(
		mix(0.25, 0.75, hash21(idw + 13.7)),
		mix(0.25, 0.75, hash21(idw + 29.3))
	);
	// 切比雪夫距离画方块（max(abs(dx),abs(dy))），边缘smoothstep抗锯齿
	float d_box = max(abs(g.x - center.x), abs(g.y - center.y));
	float shard = 1.0 - smoothstep(size_mix * 0.7, size_mix, d_box);
	// 独立相位闪烁（频率0.6~1.6，亮度55%~100%，像远处微光呼吸）
	float twinkle = 0.55 + 0.45 * sin(TIME * (0.6 + h) + h * 40.0);
	float alpha = shard * twinkle * mix(0.12, 0.40, h);
	COLOR = vec4(shard_color.rgb, alpha);
}
