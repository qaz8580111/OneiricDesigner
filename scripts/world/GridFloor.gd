## GridFloor.gd - 程序化无限网格地面（纯代码绘制，无需美术资源）
## 职责：在世界坐标中绘制覆盖相机可视范围的网格线，随玩家移动在脚下流动，
##       为纯色背景提供空间参照物——玩家可直观感知移动方向/速度/距离（幸存者类游戏标配）
## 继承：Node2D（挂在 GameWorld 下，世界空间节点，自动跟随 Camera2D）
## 绘制层级：z_index=-1，永远在玩家/敌人/子弹/掉落物等实体之下、BgLayer(CanvasLayer)之上
## 数据流：主题色 → set_colors()；相机每帧位置 → _process检测位移 → queue_redraw()
##         → _draw()按相机可视范围+网格取模对齐画线（无限世界只画屏幕内这几十条线）
## 性能设计：
##   1. 静止时零绘制（相机位移<1px或zoom未变不queue_redraw）
##   2. 线数量恒定≈(屏幕宽/格)+(屏幕高/格)，1920x1280/64 ≈ 50条，与世界大小无关
##   3. 单节点单_draw，无纹理/节点/Tween开销

extends Node2D

## ========== 网格配置常量 ==========

## 小格边长（像素）：玩家角色40px、敌人24~40px，64px一格正好是一个"身位"尺度单位
const GRID_SIZE: float = 64.0

## 每多少格画一条主线（主线更亮，提供远距离尺度参照；8格=512px≈8个身位）
const MAJOR_EVERY: int = 8

## 触发重绘的相机位移阈值（像素）：小于1px的亚像素移动不重绘，平滑跟随时也能省帧
const REDRAW_MOVE_THRESHOLD: float = 1.0

## ========== 网格线颜色（含alpha，由GameTheme注入） ==========

## 次网格线颜色（默认暗紫灰，主题未注入时兜底；实际显示值以主题grid_color为准）
var _minor_color: Color = Color(0.20, 0.19, 0.27, 0.45)

## 主网格线颜色（默认稍亮；实际显示值以主题grid_major_color为准）
var _major_color: Color = Color(0.27, 0.26, 0.36, 0.65)

## ========== 运行时状态 ==========

## 当前相机缓存（每帧获取，null时跳过绘制）
var _camera: Camera2D = null

## 上次绘制时的相机位置（与当前位置比较决定是否需要重绘）
var _last_cam_pos: Vector2 = Vector2(INF, INF)

## 上次绘制时的相机缩放（zoom变化也要重绘并重算线宽）
var _last_zoom: float = -1.0

## ========== 生命周期 ==========

func _ready() -> void:
	## z_index=-1：压在所有默认层级(z_index=0)的游戏实体之下；
	## BgLayer是独立CanvasLayer(layer=-1)在更下层负责纯色/远景，本节点在它之上
	z_index = -1

## _process：检测相机位移/缩放，变化超阈值才请求重绘（静止时零_draw开销）
func _process(_delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_2d()
		if _camera == null:
			## 相机尚未就绪（玩家场景晚于世界创建的短暂窗口期），不绘制也不报错
			return
	## 位移超阈值 或 zoom变化 → 重绘
	if _camera.global_position.distance_to(_last_cam_pos) >= REDRAW_MOVE_THRESHOLD \
			or absf(_camera.zoom.x - _last_zoom) > 0.0001:
		_last_cam_pos = _camera.global_position
		_last_zoom = _camera.zoom.x
		queue_redraw()

## ========== 主题接入 ==========

## 设置网格线颜色（主题加载/热切换时由GameWorld调用，并立即重绘一次）
## 参数：minor - 次线颜色(含alpha)；major - 主线颜色(含alpha)
func set_colors(minor: Color, major: Color) -> void:
	_minor_color = minor
	_major_color = major
	_last_cam_pos = Vector2(INF, INF)  ## 强制下次_process重绘（新颜色立即生效）

## ========== 绘制 ==========

## _draw：以相机可视范围为界画网格，坐标按GRID_SIZE取模对齐→无限延伸无接缝
## 关键：节点位于世界原点(0,0)，draw_line直接使用世界坐标；网格线起止覆盖整个可视矩形
func _draw() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var screen_size: Vector2 = get_viewport_rect().size
	var zoom: float = maxf(_camera.zoom.x, 0.0001)  ## 防除零（zoom理论上恒正）
	## 相机可视的世界尺寸（屏幕尺寸/缩放）
	var view_half: Vector2 = screen_size / (2.0 * zoom)
	var cam_pos: Vector2 = _camera.global_position
	## 可视矩形世界坐标边界
	var top_left: Vector2 = cam_pos - view_half
	var bottom_right: Vector2 = cam_pos + view_half
	## 网格对齐后的起点（floor到整格），并向外多扩一格防屏幕边缘漏线
	var start_x: float = floor(top_left.x / GRID_SIZE) * GRID_SIZE - GRID_SIZE
	var start_y: float = floor(top_left.y / GRID_SIZE) * GRID_SIZE - GRID_SIZE
	var end_x: float = bottom_right.x + GRID_SIZE
	var end_y: float = bottom_right.y + GRID_SIZE
	## 线宽按zoom反比缩放：无论相机如何缩放，屏幕上恒为1像素线
	var line_width: float = 1.0 / zoom
	## 起点对应的格序号（用于判断主线：序号能被MAJOR_EVERY整除）
	var col_index: int = int(round(start_x / GRID_SIZE))
	## ---- 竖线（沿Y方向贯穿可视区） ----
	var x: float = start_x
	while x <= end_x:
		var color: Color = _major_color if col_index % MAJOR_EVERY == 0 else _minor_color
		draw_line(Vector2(x, start_y), Vector2(x, end_y), color, line_width, true)
		x += GRID_SIZE
		col_index += 1
	## ---- 横线（沿X方向贯穿可视区） ----
	var row_index: int = int(round(start_y / GRID_SIZE))
	var y: float = start_y
	while y <= end_y:
		var color: Color = _major_color if row_index % MAJOR_EVERY == 0 else _minor_color
		draw_line(Vector2(start_x, y), Vector2(end_x, y), color, line_width, true)
		y += GRID_SIZE
		row_index += 1
