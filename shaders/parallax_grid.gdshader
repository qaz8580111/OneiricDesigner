// parallax_grid.gdshader - 视差Layer2：平铺网格（最近参考层，motion_scale=1.0 与世界1:1）
// 实现：512px平铺周期内画64px小格，纹理四条边恰好是512px(8格)主格线；
//       配合ParallaxLayer.motion_mirroring=(512,512)在世界中无限对齐铺展
// 铁律：网格颜色必须极暗（默认#1A1A24），对比度低于游戏实体，只提供移动/空间参照
// 主题：minor_color/major_color 由 ParallaxSetup.set_grid_colors() 运行时注入，可热切换

shader_type canvas_item;

// 次线颜色（64px小格，默认极暗蓝紫灰 #1A1A24，带alpha）
uniform vec4 minor_color : source_color = vec4(0.102, 0.102, 0.141, 0.60);
// 主线颜色（512px大格，略亮一档，提供远距离尺度参照）
uniform vec4 major_color : source_color = vec4(0.18, 0.19, 0.28, 0.75);
// 小格边长（像素，世界尺度：玩家半径20，64px约一个身位）
uniform float minor_px = 64.0;
// 平铺周期（像素，必须与ParallaxLayer.motion_mirroring一致，且为minor_px整数倍）
uniform float tile_px = 512.0;

void fragment() {
	vec2 px = UV * tile_px;
	// 小格：fract(+0.5)-0.5 让最近的整数格线落在|f|=0处；除以fwidth做屏幕空间抗锯齿
	// fwidth在任意相机缩放下都保持约1px的屏幕线宽
	vec2 gm = abs(fract(px / minor_px + 0.5) - 0.5) / fwidth(px / minor_px);
	float minor = 1.0 - min(min(gm.x, gm.y), 1.0);
	// 主线：周期取512，纹理边缘(uv=0/1)即主格线，mirroring后与邻片主线严丝合缝
	vec2 gM = abs(fract(px / tile_px + 0.5) - 0.5) / fwidth(px / tile_px);
	float major = 1.0 - min(min(gM.x, gM.y), 1.0);
	// 主线位置覆盖次线颜色（clamp(major)做权重），alpha取两者并集
	vec4 col = mix(minor_color, major_color, clamp(major, 0.0, 1.0));
	COLOR = vec4(col.rgb, col.a * clamp(max(minor, major), 0.0, 1.0));
}
