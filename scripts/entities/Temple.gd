## Temple.gd - 远古神庙世界物体
## 职责：神庙的视觉呈现、玩家交互、选项面板管理、选定后消失
## 继承：Area2D（与PickUp同类的世界交互物体）
## 出现方式：GameWorld.spawn_temple() 在高级怪死亡位置生成（概率由DifficultyManager计算）
## 交互方式：玩家靠近后按E（GameWorld统一处理E键，优先级高于拾取物）→ 调用 interact(player)
## 消失规则：玩家完成一次选项交互后，神庙伴随消散特效消失
## 视觉方案：_draw()程序化绘制（石台+双柱+顶盖+发光宝石，脉冲呼吸），
##           与主题皮肤系统无关——神庙是场景物体不是角色
## 扩展性：选项完全数据驱动（扫描data/temple/*.tres），新增选项不改本文件
extends Area2D

## ========== 预加载资源 ==========

## 神庙选项资源基类（用于类型校验）
const TempleOptionClass = preload("res://scripts/resources/temple/TempleOption.gd")
## 神庙面板脚本（纯代码UI）
const TEMPLE_PANEL_SCRIPT = preload("res://scripts/ui/TemplePanel.gd")

## ========== 常量 ==========

## 交互半径（玩家与神庙距离小于此值时可交互）
const INTERACT_RANGE: float = 64.0

## ========== 成员变量 ==========

## 神庙全部选项（_ready时从data/temple/扫描加载）
var _options: Array = []

## 面板实例（交互期间存在）
var _panel: Control = null

## 面板专用CanvasLayer（隔离相机transform）
var _overlay_layer: CanvasLayer = null

## 是否已交互（防止重复交互/重复开面板）
var _interacted: bool = false

## 视觉脉冲计时器（宝石发光呼吸）
var _pulse_time: float = 0.0

## 消失动画中（true后不再响应交互，等待queue_free）
var _vanishing: bool = false

## ========== 生命周期方法 ==========

## _ready() - 加入场景树：扫描选项、分组、入场动画
func _ready() -> void:
	## 加入temple分组（GameWorld按组管理）
	add_to_group("temple")

	## 扫描加载全部神庙选项
	_load_options()

	## 入场动画：从透明+缩小弹出
	modulate.a = 0.0
	scale = Vector2(0.5, 0.5)
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.3)
	tween.tween_property(self, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## _process() - 视觉脉冲计时
func _process(delta: float) -> void:
	## 脉冲宝石发光（修改_process不重绘时用queue_redraw驱动_draw重画）
	_pulse_time += delta
	queue_redraw()

## _draw() - 程序化绘制神庙外观（石台+双柱+顶盖+发光宝石）
func _draw() -> void:
	var stone: Color = Color(0.45, 0.42, 0.5, 1.0)   ## 石头主色
	var stone_dark: Color = Color(0.32, 0.3, 0.38, 1.0)  ## 石头暗色
	var gem_glow: float = 0.6 + 0.4 * sin(_pulse_time * 2.5)  ## 宝石脉冲系数
	var gem: Color = Color(0.7, 0.5, 1.0, gem_glow)  ## 紫色发光宝石

	## 底部石台（梯形底座）
	draw_rect(Rect2(-26, 10, 52, 8), stone_dark)
	draw_rect(Rect2(-20, 4, 40, 8), stone)

	## 左右石柱
	draw_rect(Rect2(-18, -18, 8, 24), stone)
	draw_rect(Rect2(10, -18, 8, 24), stone)

	## 顶部横梁（顶盖）
	draw_rect(Rect2(-24, -26, 48, 9), stone)
	draw_rect(Rect2(-26, -30, 52, 5), stone_dark)

	## 中央发光宝石（脉冲呼吸）
	draw_circle(Vector2(0, -12), 6.0, gem)
	## 宝石外圈光晕（半透明大圆）
	var glow_color: Color = gem
	glow_color.a = 0.25 * gem_glow
	draw_circle(Vector2(0, -12), 10.0, glow_color)

	## 玩家在交互范围内且未交互：绘制交互提示
	if not _interacted and not _vanishing and _is_player_near():
		var hint_color: Color = Color(0.9, 0.85, 1.0, 0.9)
		draw_string(ThemeDB.fallback_font, Vector2(-32, 40), "按 [E] 进入神庙", \
			HORIZONTAL_ALIGNMENT_CENTER, 64, 10, hint_color)

## ========== 对外接口 ==========

## 玩家是否在交互范围内（GameWorld._handle_manual_pickup调用）
func is_player_in_range() -> bool:
	return not _interacted and not _vanishing and _is_player_near()

## 玩家交互（GameWorld._handle_manual_pickup在玩家按E时调用）
## 参数：player - 玩家节点
func interact(player: Node) -> void:
	## 已交互/消失中/游戏中断：不响应
	if _interacted or _vanishing:
		return
	if not GameManager.is_playing():
		return

	_interacted = true
	_open_panel()

## ========== 内部方法 ==========

## 玩家是否在交互范围内（内部距离检测）
func _is_player_near() -> bool:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return false
	var player: Node2D = players[0]
	if not is_instance_valid(player):
		return false
	return global_position.distance_to(player.global_position) <= INTERACT_RANGE

## 扫描data/temple/加载全部神庙选项（数据驱动，新增选项即插即用）
func _load_options() -> void:
	_options.clear()
	var dir_path: String = "res://data/temple"
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		push_warning("Temple: 无法打开神庙选项目录 " + dir_path)
		return

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var resource: Resource = load(dir_path + "/" + file_name)
			## 校验资源类型（防止误放其他资源）
			if resource is TempleOptionClass:
				_options.append(resource)
			else:
				push_warning("Temple: " + file_name + " 不是TempleOption类型，已跳过")
		file_name = dir.get_next()
	dir.list_dir_end()

	if _options.is_empty():
		push_warning("Temple: 神庙选项目录为空，神庙将无法提供任何选项")

## 打开选项面板（专用CanvasLayer隔离相机，与升级面板同方案）
func _open_panel() -> void:
	## 创建CanvasLayer挂到root
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "TempleOverlay"
	## layer 越大越在上层显示，升级面板设为50，神庙面板同级=50
	_overlay_layer.layer = 50
	get_tree().root.add_child(_overlay_layer)

	## 创建面板
	_panel = TEMPLE_PANEL_SCRIPT.new()
	_overlay_layer.add_child(_panel)
	_panel.setup(_options)

	## 玩家选定选项
	_panel.option_chosen.connect(_on_option_chosen)

## 玩家选定选项后的处理：应用效果 → 消失
## 参数：option - 被选中的神庙选项
func _on_option_chosen(option: Resource) -> void:
	## 关闭面板
	_close_panel()

	## 应用选项效果
	var players: Array = get_tree().get_nodes_in_group("player")
	var player: Node = players[0] if not players.is_empty() else null
	var applied: bool = option.apply(player)

	## 应用成功：播放音效+消散动画+销毁神庙
	if applied:
		if AudioManager:
			AudioManager.play_2d("upgrade_pick", global_position, 0.9)
		_vanish()
	## 应用失败（如词条池为空）：神庙保留，可重新交互
	else:
		_interacted = false

## 消散动画后销毁神庙（"交互完离开后消失"规则）
func _vanish() -> void:
	if _vanishing:
		return
	_vanishing = true
	queue_redraw()

	## 消散动画：放大+淡出
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "scale", Vector2(1.4, 1.4), 0.35)
	tween.tween_property(self, "modulate:a", 0.0, 0.35)
	tween.chain().tween_callback(queue_free)

## 关闭面板（连同CanvasLayer一起清理）
func _close_panel() -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
		_panel = null
	if _overlay_layer != null and is_instance_valid(_overlay_layer):
		_overlay_layer.queue_free()
		_overlay_layer = null
