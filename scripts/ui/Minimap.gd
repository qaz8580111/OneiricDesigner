## Minimap.gd - 右上角小地图
## 职责：实时显示玩家位置，并在商店/神庙存在时显示对应标记
## 继承：Control（纯代码绘制，无.tscn，由 GameHUD._ready 实例化挂载为子节点）
## 数据源：
##   - 玩家位置：player 组（实时读取 global_position）
##   - 商店标记：shop 组（存在时显示金色标记，中央商店5分钟后生成）
##   - 神庙标记：temple 组（存在时显示紫色标记，高级怪死亡后概率生成）
## 坐标映射：世界坐标（竞技场 5760×3840，原点在中心）→ 小地图矩形坐标
## 性能：玩家标记每帧重绘（仅6次 draw 调用，可忽略）；商店/神庙组查询节流0.5s，
##       避免每帧全量组查询带来的开销
extends Control

## ========== 预加载资源 ==========

## 竞技场尺寸常量（世界坐标范围单一数据源，与物理墙/相机同源）
const ArenaConfigClass = preload("res://scripts/world/ArenaConfig.gd")

## ========== 小地图尺寸与边距 ==========

## 小地图宽度（像素），与竞技场宽高比 1.5 对齐避免变形
const MINIMAP_WIDTH: float = 180.0
## 小地图高度（像素）
const MINIMAP_HEIGHT: float = 120.0
## 距右上角右边缘距离（像素）
const MARGIN_RIGHT: float = 20.0
## 距屏幕上边缘距离（像素）；设为72避开右上角"难度"标签(y=44~64)，避免重叠
const MARGIN_TOP: float = 72.0

## ========== 标记颜色 ==========

## 玩家标记颜色：青色（与游戏主视觉一致）
const PLAYER_COLOR: Color = Color(0.4, 0.95, 1.0)
## 商店标记颜色：金色
const SHOP_COLOR: Color = Color(1.0, 0.85, 0.3)
## 神庙标记颜色：紫色
const TEMPLE_COLOR: Color = Color(0.7, 0.5, 1.0)
## 标记半径（像素）：商店/神庙稍大，玩家稍小
const MARKER_RADIUS: float = 5.0
const PLAYER_RADIUS: float = 4.0

## ========== 成员变量（运行时缓存） ==========

## 玩家引用（_ready 查找一次后缓存；玩家节点本局内不销毁）
var _player: Node2D = null
## 商店引用（节流扫描缓存，不存在时为 null）
var _shop: Node2D = null
## 神庙引用（节流扫描缓存，不存在时为 null）
var _temple: Node2D = null
## 组查询节流计时器（0.5秒扫描一次商店/神庙是否存在）
var _scan_timer: float = 0.0
const SCAN_INTERVAL: float = 0.5

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化一次
func _ready() -> void:
	## 小地图纯展示，不拦截鼠标（点击穿透到下层）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 锚定右上角：右边缘固定、上边缘固定，尺寸由 offset 决定，分辨率无关
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 0.0
	offset_left = -(MARGIN_RIGHT + MINIMAP_WIDTH)
	offset_right = -MARGIN_RIGHT
	offset_top = MARGIN_TOP
	offset_bottom = MARGIN_TOP + MINIMAP_HEIGHT

	## 查找玩家并做一次初始标记扫描
	_find_player()
	_scan_markers()

## _process() - 每帧调用：节流扫描标记 + 触发重绘
func _process(delta: float) -> void:
	## 商店/神庙组查询节流（0.5秒一次）：组查询比单节点读取贵，避免每帧执行
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = SCAN_INTERVAL
		_scan_markers()
	## 触发重绘（玩家位置实时跟随，仅绘制6个以内图元，开销可忽略）
	queue_redraw()

## ========== 数据源查找 ==========

## 查找玩家节点（player组，未找到时置null，配合节流扫描兜底"玩家晚于HUD创建"的场景）
func _find_player() -> void:
	var players: Array = get_tree().get_nodes_in_group("player")
	_player = players[0] as Node2D if not players.is_empty() else null

## 扫描商店与神庙是否存在（组查询，节流调用）
## 说明：中央商店全局唯一；神庙同一时间最多一座（生成后交互即消失），取第一座即可；
##       玩家引用为空时随本次扫描一并补找（避免HUD早于玩家创建导致永久找不到）
func _scan_markers() -> void:
	if _player == null or not is_instance_valid(_player):
		_find_player()

	var shops: Array = get_tree().get_nodes_in_group("shop")
	_shop = shops[0] as Node2D if not shops.is_empty() else null

	var temples: Array = get_tree().get_nodes_in_group("temple")
	_temple = temples[0] as Node2D if not temples.is_empty() else null

## ========== 坐标映射 ==========

## 世界坐标 → 小地图坐标（竞技场中心原点映射到小地图中心，等比缩放）
## 参数：world - 世界坐标（像素）
## 返回：小地图内的相对坐标（已钳制到边界，防止标记越界绘制）
func _world_to_minimap(world: Vector2) -> Vector2:
	var x: float = (world.x + ArenaConfigClass.HALF_WIDTH) / (ArenaConfigClass.HALF_WIDTH * 2.0) * MINIMAP_WIDTH
	var y: float = (world.y + ArenaConfigClass.HALF_HEIGHT) / (ArenaConfigClass.HALF_HEIGHT * 2.0) * MINIMAP_HEIGHT
	return Vector2(
		clampf(x, 0.0, MINIMAP_WIDTH),
		clampf(y, 0.0, MINIMAP_HEIGHT)
	)

## ========== 绘制 ==========

## _draw() - 绘制小地图背景、边框与各标记
func _draw() -> void:
	## 背景：半透明深色底（与游戏HUD深色风格统一）
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.55))
	## 边框：白色细线，界定小地图范围
	draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 1.0, 1.0, 0.25), false, 1.0)

	## 商店标记（存在时）：金色圆点，带深色描边保证浅色底图可读
	if _shop != null and is_instance_valid(_shop):
		_draw_marker(_shop.global_position, SHOP_COLOR, MARKER_RADIUS, true)
	## 神庙标记（存在时）：紫色圆点
	if _temple != null and is_instance_valid(_temple):
		_draw_marker(_temple.global_position, TEMPLE_COLOR, MARKER_RADIUS, true)
	## 玩家标记：青色圆点，实时跟随玩家
	if _player != null and is_instance_valid(_player):
		_draw_marker(_player.global_position, PLAYER_COLOR, PLAYER_RADIUS, false)

## 绘制单个标记圆点
## 参数：world_pos - 世界坐标；color - 标记颜色；radius - 半径；with_outline - 是否加深色描边
func _draw_marker(world_pos: Vector2, color: Color, radius: float, with_outline: bool) -> void:
	var p: Vector2 = _world_to_minimap(world_pos)
	if with_outline:
		## 深色描边：略大一圈的深色圆垫底，提升标记在浅色区域的辨识度
		draw_circle(p, radius + 1.5, Color(0.0, 0.0, 0.0, 0.7))
	draw_circle(p, radius, color)
