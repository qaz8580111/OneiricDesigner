## CharacterSkin.gd - 角色皮肤资源类（主题系统的基础单元）
## 职责：定义"单个角色"的完整外观（形状+主色+配件=有辨识度的像素角色）
## 继承：Resource（可在编辑器创建 .tres，或作为 SubResource 内嵌在主题包 GameTheme 中）
## 双渲染模式：
##   PROCEDURAL = 程序化生成：零美术依赖，参数即角色（形状+颜色+武器+帽子+发型+护甲+配件）
##                逐像素生成纹理，皮肤实例内缓存，同皮肤共享
##   FRAMES     = 序列帧动画：SpriteFrames 槽位命名约定 idle/move/attack/hit/death
## 设计意图：配件全部做成可选 String 枚举（"none"=不绘制），无配件=老版色块（兼容回退），
##           有配件=完整角色形象；主题 .tres 里给每个角色配不同组合即千人千面
class_name CharacterSkin
extends Resource

## ========== 渲染模式枚举 ==========

enum RenderMode {
	PROCEDURAL,  ## 程序化：按参数逐像素生成纹理
	FRAMES       ## 序列帧：播放 frames 字段中的 SpriteFrames
}

## ========== 皮肤标识 ==========

@export var skin_id: String = "generic"

## ========== 渲染模式与序列帧资源 ==========

@export var render_mode: RenderMode = RenderMode.PROCEDURAL
## 序列帧动画资源（仅 FRAMES 模式使用）。槽位命名：idle/move/attack/hit/death（可部分缺失）
@export var frames: SpriteFrames = null

## ========== 基础形状 & 颜色（PROCEDURAL 模式） ==========

## 轮廓形状：square/circle/diamond（与 EnemyData.shape_type 三分类保持一致）
@export var shape: String = "square"
## 主体颜色（同时是角色"逻辑色"——死亡碎片/无形态子弹染色都取此色）
@export var main_color: Color = Color(1, 0.2, 0.2, 1)
## 副色/高光色（形状顶部受光边缘 + 配件高光）
@export var accent_color: Color = Color(1, 1, 1, 1)
## 是否绘制眼睛
@export var has_eyes: bool = true
@export var eye_color: Color = Color(0.12, 0.1, 0.18, 1)
## 目标尺寸（像素；玩家 40x40，敌人 22~56 不等）
@export var target_size: Vector2 = Vector2(30, 30)

## ========== 配件系统（让色块变角色的关键——全部 String 枚举，"none"=不绘制） ==========

## 武器类型：none/sword/bow/staff/pistol/axe/glove（大拳头）
@export var weapon_type: String = "none"
@export var weapon_color: Color = Color(0.7, 0.7, 0.8, 1)

## 帽子类型：none/crown(皇冠)/wizard(法师尖帽)/helmet(头盔)/hood(兜帽)/feather(羽毛头饰)
@export var hat_type: String = "none"
@export var hat_color: Color = Color(0.4, 0.35, 0.55, 1)

## 发型：none/spiky(短尖刺)/long(长发)/ponytail(马尾)/bald(光头)/tentacles(触须——夜魇专用)
@export var hair_style: String = "none"
@export var hair_color: Color = Color(0.2, 0.15, 0.1, 1)

## 护甲：none/chestplate(胸甲)/shoulder(护肩)/armor(全身甲)/scales(鳞甲)
@export var armor_style: String = "none"
@export var armor_color: Color = Color(0.55, 0.55, 0.6, 1)

## 小配件：none/glasses(眼镜)/mask(面具——下半脸)/scarf(围巾)/flower(花朵)/skull(骷髅徽——精英)
@export var accessory_type: String = "none"
@export var accessory_color: Color = Color(1, 0.9, 0.4, 1)

## 轮廓描边颜色（在形状外画 1px 深色边，让角色在明亮背景上也能辨认）
@export var outline_color: Color = Color(0, 0, 0, 0.6)

## 是否绘制形状专属装饰（circle=果冻水滴, diamond=水晶刻面, square=螺栓/铆钉）
@export var shape_details: bool = true

## ========== 动画幅度参数（PROCEDURAL 模式，CharacterAnimator 消费） ==========

@export var idle_breath_scale: float = 0.05
@export var move_bounce_scale: float = 0.14
@export var move_bounce_speed: float = 11.0
@export var flip_with_direction: bool = true

## ========== 运行时缓存 ==========

## 皮肤纹理缓存（皮肤全局共享，一个皮肤只生成一次纹理）
var _cached_texture: ImageTexture = null

## ========== 核心方法 ==========

func has_frames() -> bool:
	return render_mode == RenderMode.FRAMES and frames != null

func get_texture() -> ImageTexture:
	if _cached_texture != null:
		return _cached_texture
	_cached_texture = _generate_texture()
	return _cached_texture

## ========== 纹理生成主流程 ==========

## 逐像素生成程序化纹理：形状 → 描边 → 高光 → 形状装饰 → 配件(武器/帽子/发型/护甲/小配件) → 眼睛
func _generate_texture() -> ImageTexture:
	var width: int = maxi(int(target_size.x), 8)
	var height: int = maxi(int(target_size.y), 8)
	## 2px 外边距：武器/帽子/触须会超出形状轮廓，给配件留出空间
	var margin: int = 2
	var canvas_w: int = width + margin * 2
	var canvas_h: int = height + margin * 2
	var image: Image = Image.create(canvas_w, canvas_h, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	## 形状中心 = canvas 中心
	var cx: float = canvas_w / 2.0
	var cy: float = canvas_h / 2.0
	var radius: float = min(width, height) / 2.0

	## ---------- 第一遍：形状主体（主色 + 顶部受光） ----------
	for y in range(canvas_h):
		for x in range(canvas_w):
			var dx: float = x + 0.5 - cx
			var dy: float = y + 0.5 - cy
			if _is_in_shape(dx, dy, radius):
				var col: Color = main_color
				## 顶部高光（上 30% 区域用副色提亮）
				if dy <= -radius * 0.3:
					col = accent_color.lerp(main_color, 0.65)
				image.set_pixel(x, y, col)

	## ---------- 第二遍：描边（沿形状外缘画 1px 深色边） ----------
	_draw_outline(image, cx, cy, radius)

	## ---------- 第三遍：形状专属装饰（果冻水滴/水晶刻面/螺栓） ----------
	if shape_details:
		_draw_shape_details(image, cx, cy, radius)

	## ---------- 配件绘制（叠在形状之上/之外，方向上侧+右侧+下方） ----------
	_draw_all_accessories(image, cx, cy, radius)

	## ---------- 眼睛（最后画，保证在所有层之上） ----------
	if has_eyes:
		_draw_eyes(image, cx, cy, radius)

	return ImageTexture.create_from_image(image)

## 判断像素是否在指定形状内（dx,dy 为像素中心相对形状中心的偏移）
func _is_in_shape(dx: float, dy: float, radius: float) -> bool:
	match shape:
		"circle":
			return Vector2(dx, dy).length() <= radius
		"diamond":
			return absf(dx) + absf(dy) <= radius
		_:
			## 方形：以 min(width,height)/2 为半径，以形状中心为原点的矩形
			var half_w: float = target_size.x / 2.0
			var half_h: float = target_size.y / 2.0
			return absf(dx) <= half_w and absf(dy) <= half_h

## 描边：沿形状外缘画 1px 深色边（跳过 canvas 边缘）
func _draw_outline(image: Image, cx: float, cy: float, radius: float) -> void:
	var w: int = image.get_width()
	var h: int = image.get_height()
	for y in range(h):
		for x in range(w):
			var dx: float = x + 0.5 - cx
			var dy: float = y + 0.5 - cy
			## 当前像素在形状内
			if _is_in_shape(dx, dy, radius):
				## 检查四个方向的邻居：任一不在形状内 → 当前像素是边缘
				var is_edge: bool = false
				for dir in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
					if not _is_in_shape(dx + dir.x, dy + dir.y, radius):
						is_edge = true
						break
				if is_edge:
					image.set_pixel(x, y, outline_color)

## 形状专属装饰：circle→底部果冻水滴 / diamond→高光刻面 / square→四角螺栓
func _draw_shape_details(image: Image, cx: float, cy: float, radius: float) -> void:
	match shape:
		"circle":
			## 史莱姆水滴：底部中心 2-3px 小三角
			var drop_y: int = int(cy + radius * 0.55)
			var drop_x: int = int(cx)
			for i in range(2):
				for j in range(-i, i + 1):
					_safe_set(image, drop_x + j, drop_y + i, accent_color.lerp(main_color, 0.7))
		"diamond":
			## 水晶高光刻面：左上 3px 小三角（用副色提亮）
			var fy: int = int(cy - radius * 0.15)
			for i in range(3):
				for j in range(-i, 1):
					_safe_set(image, int(cx) - 3 + j, fy - i, accent_color)
		_:
			## 方形螺栓：四角各 2px 亮点（用副色）
			var half_w: float = target_size.x / 2.0
			var half_h: float = target_size.y / 2.0
			for dx in [-1, 1]:
				for dy in [-1, 1]:
					var bx: int = int(cx + dx * (half_w - 1))
					var by: int = int(cy + dy * (half_h - 1))
					_safe_set(image, bx, by, accent_color)

## ========== 配件绘制（武器/帽子/发型/护甲/小配件） ==========

func _draw_all_accessories(image: Image, cx: float, cy: float, radius: float) -> void:
	## 绘制顺序（从下到上叠层）：护甲 → 武器 → 发型 → 帽子 → 小配件 → 眼睛(单独画)

	## 1. 护甲（身体覆盖层，在形状基础色之上）
	if armor_style != "none":
		_draw_armor(image, cx, cy, radius)

	## 2. 武器（身体右侧伸出）
	if weapon_type != "none":
		_draw_weapon(image, cx, cy, radius)

	## 3. 发型（头顶+两侧+后侧覆盖）
	if hair_style != "none":
		_draw_hair(image, cx, cy, radius)

	## 4. 帽子（头顶，最上层覆盖头部）
	if hat_type != "none":
		_draw_hat(image, cx, cy, radius)

	## 5. 小配件（眼镜/面具/围巾/花朵/骷髅徽）
	if accessory_type != "none":
		_draw_accessory(image, cx, cy, radius)

## 武器绘制：从身体右侧中心向外伸出 5-7px 的武器像素块
## 方向统一向右（CharacterAnimator.flip_with_direction 负责水平翻转朝向左）
func _draw_weapon(image: Image, cx: float, cy: float, radius: float) -> void:
	## 武器附着点：身体右侧中心偏上（手臂大致位置）
	var attach_x: int = int(cx + radius * 0.95)
	var attach_y: int = int(cy - radius * 0.05)
	match weapon_type:
		"sword":
			## 剑：柄 2px + 刃 6px 长条形（竖直）
			for i in range(2):
				_safe_set(image, attach_x + i, attach_y - 1, weapon_color)
				_safe_set(image, attach_x + i, attach_y + 1, weapon_color)
			## 剑刃 8px：垂直长条 + 尖顶
			for i in range(8):
				_safe_set(image, attach_x + 4, attach_y - 4 + i, weapon_color)
			_safe_set(image, attach_x + 4, attach_y - 5, accent_color)  ## 剑尖高光
		"bow":
			## 弓：弧形 6px 高 + 弦
			for i in range(-3, 4):
				_safe_set(image, attach_x + 2, attach_y + i, weapon_color)
				_safe_set(image, attach_x + 4, attach_y + i, weapon_color)
				## 弧线：每侧 i=±3 时向外各多画 1px
				if abs(i) == 3:
					_safe_set(image, attach_x + 1, attach_y + i, weapon_color)
					_safe_set(image, attach_x + 5, attach_y + i, weapon_color)
			## 弓弦：3 条横线表示
			_safe_set(image, attach_x + 3, attach_y - 3, Color(1, 1, 1, 0.7))
			_safe_set(image, attach_x + 3, attach_y, Color(1, 1, 1, 0.7))
			_safe_set(image, attach_x + 3, attach_y + 3, Color(1, 1, 1, 0.7))
		"staff":
			## 法杖：竖直长杆 + 顶端宝石
			for i in range(-6, 7):
				_safe_set(image, attach_x + 3, attach_y + i, weapon_color)
			## 宝石 2x2
			for dx in range(2):
				for dy in range(2):
					_safe_set(image, attach_x + 2 + dx, attach_y - 8 + dy, accent_color)
		"pistol":
			## 手枪：短枪管 3px + 握把
			for i in range(3):
				_safe_set(image, attach_x + i, attach_y - 1, weapon_color)
				_safe_set(image, attach_x + i, attach_y, weapon_color)
			## 握把：向下 2px
			_safe_set(image, attach_x + 1, attach_y + 1, weapon_color)
			_safe_set(image, attach_x + 1, attach_y + 2, weapon_color)
		"axe":
			## 斧：柄 2px + 斧刃（右侧三角）
			for i in range(4):
				_safe_set(image, attach_x + 1, attach_y - 1 + i, weapon_color)
			## 斧刃：三角（上宽下窄）
			for i in range(3):
				for j in range(i, 4):
					_safe_set(image, attach_x + 3 + j, attach_y - 2 + i, weapon_color)
		"glove":
			## 大拳头：圆形 3x3（大老板/重装兵）
			for dx in range(3):
				for dy in range(3):
					if Vector2(dx - 1, dy - 1).length() <= 1.5:
						_safe_set(image, attach_x + 1 + dx, attach_y + dy, weapon_color)

## 帽子绘制：头顶区域的像素块堆叠
func _draw_hat(image: Image, cx: float, cy: float, radius: float) -> void:
	var head_top: int = int(cy - radius * 0.6)
	match hat_type:
		"crown":
			## 皇冠：底部 4px 横条 + 顶部 3 个尖刺
			for i in range(4):
				_safe_set(image, int(cx) - 1 + i, head_top - 1, hat_color)
			_safe_set(image, int(cx) - 1, head_top - 2, hat_color)  ## 左尖
			_safe_set(image, int(cx), head_top - 3, hat_color)       ## 中尖
			_safe_set(image, int(cx) + 2, head_top - 2, hat_color)  ## 右尖
			## 宝石 2px
			_safe_set(image, int(cx), head_top - 2, accessory_color)
		"wizard":
			## 法师尖帽：高三角 5px
			for i in range(5):
				for j in range(-i, i + 1):
					_safe_set(image, int(cx) + j, head_top - 1 - i, hat_color)
			## 帽尖宝石
			_safe_set(image, int(cx), head_top - 6, accessory_color)
		"helmet":
			## 头盔：平顶 5px + 护脸条
			for i in range(5):
				_safe_set(image, int(cx) - 2 + i, head_top - 1, hat_color)
			_safe_set(image, int(cx) - 2, head_top, hat_color)
			_safe_set(image, int(cx) + 2, head_top, hat_color)
			## 护脸（眼睛上方遮条 5px）
			for i in range(5):
				_safe_set(image, int(cx) - 2 + i, head_top + 1, outline_color)
		"hood":
			## 兜帽：圆角方块 5x3（比头略大）
			for dy in range(3):
				for dx in range(-2, 3):
					_safe_set(image, int(cx) + dx, head_top - 1 + dy, hat_color)
			## 兜帽下缘（两侧垂片）
			for dy in range(4):
				_safe_set(image, int(cx) - 2, head_top + 2 + dy, hat_color)
				_safe_set(image, int(cx) + 2, head_top + 2 + dy, hat_color)
		"feather":
			## 羽毛头饰：3 根斜插羽毛 + 发带
			_safe_set(image, int(cx) - 2, head_top - 1, hat_color)
			_safe_set(image, int(cx) - 3, head_top - 2, hat_color)
			_safe_set(image, int(cx) - 4, head_top - 3, hat_color)
			_safe_set(image, int(cx) + 1, head_top - 1, hat_color)
			_safe_set(image, int(cx) + 2, head_top - 2, hat_color)
			_safe_set(image, int(cx) + 3, head_top - 3, hat_color)
			## 发带
			for i in range(4):
				_safe_set(image, int(cx) - 1 + i, head_top, hat_color)

## 发型绘制：头顶/两侧/后侧的额外像素（在帽子之前画，帽子覆盖顶部）
func _draw_hair(image: Image, cx: float, cy: float, radius: float) -> void:
	var head_top: int = int(cy - radius * 0.55)
	match hair_style:
		"spiky":
			## 短尖刺头顶：3 个尖刺
			_safe_set(image, int(cx) - 1, head_top - 2, hair_color)
			_safe_set(image, int(cx), head_top - 3, hair_color)
			_safe_set(image, int(cx) + 1, head_top - 2, hair_color)
			## 两侧垂发
			_safe_set(image, int(cx) - 2, head_top + 1, hair_color)
			_safe_set(image, int(cx) + 2, head_top + 1, hair_color)
		"long":
			## 长发：头顶 4px + 两侧 3px + 后侧 5px 长垂
			for i in range(4):
				_safe_set(image, int(cx) - 1 + i, head_top - 1, hair_color)
			for dy in range(4):
				_safe_set(image, int(cx) - 2, head_top + dy, hair_color)
				_safe_set(image, int(cx) + 2, head_top + dy, hair_color)
			## 后侧长发（身体后方，需要在形状上补画）
			for dy in range(6):
				_safe_set(image, int(cx) - 1, head_top + dy + 2, hair_color)
				_safe_set(image, int(cx), head_top + dy + 2, hair_color)
				_safe_set(image, int(cx) + 1, head_top + dy + 2, hair_color)
		"ponytail":
			## 马尾：头顶 4px + 后侧 1px 马尾垂到身体下方
			for i in range(4):
				_safe_set(image, int(cx) - 1 + i, head_top - 1, hair_color)
			## 马尾：从头顶中心向下方延伸 6px（形状后方）
			for dy in range(6):
				_safe_set(image, int(cx), head_top + dy, hair_color)
		"tentacles":
			## 触须：头顶 2px + 两侧各 3 条弯触须（夜魇/幽灵专用）
			for i in range(2):
				_safe_set(image, int(cx) + i, head_top - 1, hair_color)
			for dir in [-1, 1]:
				for i in range(3):
					_safe_set(image, int(cx) + dir * (1 + i), head_top - 1 + i, hair_color)

## 护甲绘制：胸部/肩部/全身甲的色块叠加
func _draw_armor(image: Image, cx: float, cy: float, radius: float) -> void:
	var chest_top: int = int(cy - radius * 0.1)
	var chest_bottom: int = int(cy + radius * 0.55)
	match armor_style:
		"chestplate":
			## 胸甲：身体中央 5x3 矩形（副色提亮边框）
			for dy in range(chest_bottom - chest_top):
				for dx in range(-2, 3):
					_safe_set(image, int(cx) + dx, chest_top + dy, armor_color)
			## 胸甲亮边（顶部一行用副色）
			for dx in range(-2, 3):
				_safe_set(image, int(cx) + dx, chest_top, accent_color)
		"shoulder":
			## 护肩：身体两侧肩高位置各 3x2 方形
			var shoulder_y: int = int(cy - radius * 0.2)
			for dir in [-1, 1]:
				for dy in range(2):
					for dx in range(3):
						_safe_set(image, int(cx) + dir * (radius * 0.9) + dir * dx, shoulder_y + dy, armor_color)
		"armor":
			## 全身甲：在形状上覆盖深色条纹（腰带+护胸亮条）
			## 腰带：身体下 1/3 处横条
			var belt_y: int = int(cy + radius * 0.35)
			for dx in range(int(-radius), int(radius) + 1):
				_safe_set(image, int(cx) + dx, belt_y, armor_color)
				_safe_set(image, int(cx) + dx, belt_y + 1, armor_color)
			## 护胸亮条：身体中央竖条
			for dy in range(int(-radius * 0.3), int(radius * 0.2)):
				_safe_set(image, int(cx), int(cy) + dy, accent_color)
		"scales":
			## 鳞甲：身体上半部画半格棋盘鳞纹（副色作为鳞片间隙）
			for y in range(int(cy - radius * 0.4), int(cy + radius * 0.1)):
				for x in range(int(cx - radius * 0.9), int(cx + radius * 0.9) + 1):
					if _is_in_shape(x + 0.5 - cx, y + 0.5 - cy, radius):
						## 间隔涂色制造鳞纹感
						if (x + y) % 2 == 0:
							_safe_set(image, x, y, armor_color)

## 小配件绘制：眼镜/面具/围巾/花朵/骷髅徽
func _draw_accessory(image: Image, cx: float, cy: float, radius: float) -> void:
	match accessory_type:
		"glasses":
			## 眼镜：在眼睛位置上方画横线 + 两个镜框
			var eye_y: int = int(cy - radius * 0.05)
			## 镜框左
			for dx in range(-3, -1):
				for dy in range(-1, 2):
					_safe_set(image, int(cx) + dx, eye_y + dy, accessory_color)
			## 镜框右
			for dx in range(1, 3):
				for dy in range(-1, 2):
					_safe_set(image, int(cx) + dx, eye_y + dy, accessory_color)
			## 鼻梁
			_safe_set(image, int(cx), eye_y, accessory_color)
			## 镜片高光
			_safe_set(image, int(cx) - 2, eye_y - 1, Color(1, 1, 1, 0.6))
			_safe_set(image, int(cx) + 2, eye_y - 1, Color(1, 1, 1, 0.6))
		"mask":
			## 面具：覆盖下半脸（眼睛以下）的色块
			var mask_top: int = int(cy)
			var mask_bot: int = int(cy + radius * 0.5)
			for y in range(mask_top, mask_bot):
				for x in range(int(cx - radius * 0.5), int(cx + radius * 0.5) + 1):
					if _is_in_shape(x + 0.5 - cx, y + 0.5 - cy, radius):
						_safe_set(image, x, y, accessory_color)
			## 面具上沿亮条
			for x in range(int(cx - radius * 0.5), int(cx + radius * 0.5) + 1):
				if _is_in_shape(x + 0.5 - cx, mask_top + 0.5 - cy, radius):
					_safe_set(image, x, mask_top, accent_color)
		"scarf":
			## 围巾：颈部 1 条横条 + 下方垂片
			var scarf_y: int = int(cy + radius * 0.3)
			for dx in range(int(-radius * 0.7), int(radius * 0.7) + 1):
				if _is_in_shape(dx + 0.5, scarf_y + 0.5 - cy, radius):
					_safe_set(image, int(cx) + dx, scarf_y, accessory_color)
					_safe_set(image, int(cx) + dx, scarf_y + 1, accessory_color)
			## 围巾垂片 3px
			for dy in range(3):
				_safe_set(image, int(cx) + 1, scarf_y + 2 + dy, accessory_color)
		"flower":
			## 花朵：头顶 4 瓣 + 花心
			var fx: int = int(cx)
			var fy: int = int(cy - radius * 0.75)
			for dir in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
				_safe_set(image, fx + dir.x, fy + dir.y, accessory_color)
			_safe_set(image, fx, fy, accent_color)  ## 花心
		"skull":
			## 骷髅徽（精英怪）：胸部区域小骷髅图案
			var sx: int = int(cx)
			var sy: int = int(cy + radius * 0.15)
			## 骷髅头 3x3 方块
			for dy in range(3):
				for dx in range(3):
					_safe_set(image, sx - 1 + dx, sy + dy, Color(0.95, 0.95, 0.9, 1))
			## 眼洞
			_safe_set(image, sx - 1, sy + 1, Color(0.15, 0.05, 0.05, 1))
			_safe_set(image, sx + 1, sy + 1, Color(0.15, 0.05, 0.05, 1))

## 绘制眼睛（保证画在形状/配件之上，作为角色最显眼的特征）
func _draw_eyes(image: Image, cx: float, cy: float, radius: float) -> void:
	var eye_size: int = maxi(2, int(radius * 0.28))
	var eye_y: int = int(cy - radius * 0.05) - eye_size / 2
	var eye_gap: int = int(radius * 0.32) - eye_size / 2
	## 左眼
	_fill_safe_rect(image, int(cx) - eye_gap - eye_size, eye_y, eye_size, eye_color)
	## 右眼
	_fill_safe_rect(image, int(cx) + eye_gap, eye_y, eye_size, eye_color)

## 安全绘制单个像素（边界保护，跳过 canvas 外坐标）
func _safe_set(image: Image, x: int, y: int, color: Color) -> void:
	if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
		return
	image.set_pixel(x, y, color)

## 安全填充一个矩形区域（边界保护）
func _fill_safe_rect(image: Image, sx: int, sy: int, size: int, color: Color) -> void:
	for dy in range(size):
		for dx in range(size):
			_safe_set(image, sx + dx, sy + dy, color)
