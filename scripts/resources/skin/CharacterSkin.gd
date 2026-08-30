## CharacterSkin.gd - 角色皮肤资源类（主题系统的基础单元）
## 职责：定义"单个角色"的完整外观与动画参数，玩家/敌人/Boss通用
## 继承：Resource（可在编辑器创建 .tres，或作为 SubResource 内嵌在主题包 GameTheme 中）
## 双渲染模式设计（核心思想——"现在没美术也能跑，以后有美术无痛升级"）：
##   PROCEDURAL = 程序化生成：无任何美术依赖，参数即皮肤（形状/主色/副色/眼睛/动画幅度），
##                逐像素生成占位风格纹理（像素风，与项目 default_texture_filter=0 一致）
##   FRAMES     = 序列帧动画：美术用 Aseprite/PS 等导出序列帧 → 编辑器拼成 SpriteFrames
##                → 填入 frames 字段即可，动画槽位命名约定：idle/move/attack/hit/death
## 被引用方：GameTheme（主题包持有皮肤）、ThemeManager（按角色分发皮肤）、
##           Player/Enemy（应用皮肤时取 get_texture() 挂到 Sprite2D）
## 动画说明：procedural 模式的动画由 CharacterAnimator 组件按下方"动画幅度参数"程序驱动；
##           frames 模式由 CharacterAnimator 切换 SpriteFrames 播放列表（两种模式对外接口一致）
class_name CharacterSkin
extends Resource

## ========== 渲染模式枚举 ==========

enum RenderMode {
	PROCEDURAL,  ## 程序化：按参数逐像素生成纹理（当前默认，零美术依赖）
	FRAMES       ## 序列帧：播放 frames 字段中的 SpriteFrames（美术资源就绪后使用）
}

## ========== 皮肤标识 ==========

## 皮肤唯一标识（调试/日志用；一个主题内不应重复）
@export var skin_id: String = "generic"

## ========== 渲染模式与序列帧资源 ==========

## 渲染模式：PROCEDURAL（程序化）/ FRAMES（序列帧）
@export var render_mode: RenderMode = RenderMode.PROCEDURAL

## 序列帧动画资源（仅 FRAMES 模式使用）
## 动画槽位命名约定：idle(待机) / move(移动) / attack(攻击) / hit(受击) / death(死亡)
## 槽位可只配部分：CharacterAnimator 会用 has_animation 检查，缺失的槽位自动跳过
@export var frames: SpriteFrames = null

## ========== 程序化外观参数（PROCEDURAL 模式） ==========

## 轮廓形状："square"=方形(重装/近战) / "circle"=圆形(柔软/飞行) / "diamond"=菱形(敏捷/远程)
## 与 EnemyData.shape_type 的三分类保持一致，保证换肤前后敌人的"体型语言"不变
@export var shape: String = "square"

## 主体颜色（纹理主色；同时作为该角色的"逻辑色"——死亡碎片/无形态子弹染色都取此色）
@export var main_color: Color = Color(1, 0.2, 0.2, 1)

## 副色/高光色（用于形状顶部的受光边缘，让纯色块有立体感）
@export var accent_color: Color = Color(1, 1, 1, 1)

## 是否绘制眼睛（两个小方点，像素风点睛——有眼睛立刻"像角色"而不是"色块"）
@export var has_eyes: bool = true

## 眼睛颜色（深色为主，与主色拉开对比）
@export var eye_color: Color = Color(0.12, 0.1, 0.18, 1)

## 目标尺寸（像素；应与角色碰撞体尺寸匹配，玩家40x40 / 敌人默认30x30）
@export var target_size: Vector2 = Vector2(30, 30)

## ========== 动画幅度参数（PROCEDURAL 模式，由 CharacterAnimator 消费） ==========
## 设计意图：把"动画性格"做成参数——史莱姆弹得夸张、坦克弹得沉重、法师几乎不弹，
##           同一套动画器代码，不同角色填不同参数即可千人千面

## 待机呼吸幅度（0.05=待机时纵向轻微呼吸 5%）
@export var idle_breath_scale: float = 0.05

## 移动弹跳幅度（0.14=移动时纵向拉伸挤压 14%，经典 squash & stretch 手感）
@export var move_bounce_scale: float = 0.14

## 移动弹跳频率（Hz，越大弹得越快；heavy 角色建议调小）
@export var move_bounce_speed: float = 11.0

## 是否随朝向水平翻转纹理（有眼睛的角色开启，翻转后眼睛跟随朝向）
@export var flip_with_direction: bool = true

## ========== 运行时缓存 ==========

## 皮肤纹理缓存（皮肤是全局共享资源，一个皮肤只逐像素生成一次，
##               所有使用该皮肤的角色实例共享同一张 ImageTexture——零重复开销）
var _cached_texture: ImageTexture = null

## ========== 核心方法 ==========

## 是否携带序列帧动画（FRAMES 模式且 frames 已配置）
## Player/Enemy 据此决定走"程序动画"还是"SpriteFrames 播放"分支
func has_frames() -> bool:
	return render_mode == RenderMode.FRAMES and frames != null

## 获取程序化纹理（带缓存：首次调用逐像素生成，之后直接返回缓存）
## 返回：ImageTexture（像素风占位风格纹理）
func get_texture() -> ImageTexture:
	## 缓存命中：直接复用（皮肤共享 → 同皮肤所有角色共享一张纹理）
	if _cached_texture != null:
		return _cached_texture
	## 缓存未命中：首次生成并缓存
	_cached_texture = _generate_texture()
	return _cached_texture

## 逐像素生成程序化纹理
## 生成内容 = 形状轮廓(主色) + 顶部受光边缘(副色) + 眼睛(两个方点)
## 返回：新生成的 ImageTexture
func _generate_texture() -> ImageTexture:
	## 尺寸取整（防御小数尺寸）
	var width: int = maxi(int(target_size.x), 4)
	var height: int = maxi(int(target_size.y), 4)
	## 创建透明底图（形状之外的像素保持透明，形成轮廓）
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	## 中心坐标与判定半径（取宽高较小值的一半，保证形状完整不越界）
	var cx: float = width / 2.0
	var cy: float = height / 2.0
	var radius: float = min(width, height) / 2.0

	## ---------- 第一遍：按形状填充主色 + 顶部高光 ----------
	for y in range(height):
		for x in range(width):
			## 像素中心相对形状中心的偏移
			var dx: float = x + 0.5 - cx
			var dy: float = y + 0.5 - cy
			var filled: bool = false
			match shape:
				"circle":
					## 圆形：到中心的欧氏距离 ≤ 半径
					filled = Vector2(dx, dy).length() <= radius
				"diamond":
					## 菱形：到中心的曼哈顿距离 ≤ 半径
					filled = absf(dx) + absf(dy) <= radius
				_:
					## 方形：矩形范围内全部填充
					filled = true
			if filled:
				## 顶部区域（上边缘 35% 高度以内）用副色提亮做受光感，
				## 其余部分用主色；副色向主色插值 0.65 避免高光过曝
				var pixel_color: Color = main_color
				if dy <= -radius * 0.3:
					pixel_color = accent_color.lerp(main_color, 0.65)
				image.set_pixel(x, y, pixel_color)

	## ---------- 第二遍：绘制眼睛（保证画在形状内部的半透明像素上） ----------
	if has_eyes:
		_draw_eyes(image, width, height, cx, cy, radius)

	## 图像 → 纹理
	return ImageTexture.create_from_image(image)

## 在纹理上绘制两只眼睛（两个方形色块，关于中线对称）
## 设计意图：眼睛画在"上半部居中"——俯视角下角色面向镜头时五官自然居上
func _draw_eyes(image: Image, width: int, height: int, cx: float, cy: float, radius: float) -> void:
	## 眼睛边长：随体型缩放，最小2像素（30px身体≈4px眼睛，40px≈5px）
	var eye_size: int = maxi(2, int(radius * 0.28))
	## 眼睛纵向位置：中心偏上（约 -0.05 半径处）
	var eye_y: int = int(cy - radius * 0.05) - eye_size / 2
	## 两眼间距：中心左右各 0.32 半径
	var eye_gap: int = int(radius * 0.32) - eye_size / 2
	## 左眼区域
	_fill_eye_rect(image, int(cx) - eye_gap - eye_size, eye_y, eye_size)
	## 右眼区域
	_fill_eye_rect(image, int(cx) + eye_gap, eye_y, eye_size)

## 在指定区域填充一个眼睛方块（跳过形状外/透明像素，避免眼睛"长"到轮廓外面）
func _fill_eye_rect(image: Image, start_x: int, start_y: int, size: int) -> void:
	for y in range(start_y, start_y + size):
		for x in range(start_x, start_x + size):
			## 边界保护：跳过纹理外像素
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			## 只画在已有形状（alpha>0）的像素上，眼睛不会溢出轮廓
			if image.get_pixel(x, y).a > 0.0:
				image.set_pixel(x, y, eye_color)
