## Temple.gd - 远古神庙世界物体
## 职责：神庙的视觉呈现、玩家交互、选项面板管理、选定后消失
## 继承：Area2D（与PickUp同类的世界交互物体）
## 出现方式：GameWorld.spawn_temple() 在高级怪死亡位置生成（固定概率1%，全局同时仅一座）
## 交互方式：玩家靠近后按E（GameWorld统一处理E键，优先级高于拾取物）→ 调用 interact(player)
## 进入规则：玩家进入神庙后游戏暂停（GameManager.pause_game），关闭面板后恢复
## 替换规则：新神庙出现时，未进入的旧神庙立即消散（GameWorld.spawn_temple → despawn）
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

## 玩家是否在交互范围内（_process中定时探测缓存，_draw只读缓存避免每帧组查询）
var _player_near: bool = false

## 交互范围探测节流计时（0.1秒一次，组查询成本摊薄）
var _near_check_timer: float = 0.0
const NEAR_CHECK_INTERVAL: float = 0.1

## 重绘节流计时（脉冲动画30fps足够，不必每帧queue_redraw）
var _redraw_timer: float = 0.0
const REDRAW_INTERVAL: float = 1.0 / 30.0

## 消失动画中（true后不再响应交互，等待queue_free）
var _vanishing: bool = false

## 本神庙是否主动暂停了游戏（关闭面板时据此恢复，避免误恢复暂停菜单等其他暂停源）
var _paused_by_temple: bool = false

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

## _process() - 视觉脉冲与交互范围探测（均节流，降低多神庙/后期场景开销）
func _process(delta: float) -> void:
	## 消失动画期间不再做范围探测（提示文字也不再需要）
	if not _vanishing and not _interacted:
		_near_check_timer -= delta
		if _near_check_timer <= 0.0:
			_near_check_timer = NEAR_CHECK_INTERVAL
			_player_near = _is_player_near()

	## 脉冲计时与30fps重绘（_draw是纯CPU绘制，节流避免每帧全量重画）
	_pulse_time += delta
	_redraw_timer -= delta
	if _redraw_timer <= 0.0:
		_redraw_timer = REDRAW_INTERVAL
		queue_redraw()

## _exit_tree() - 节点被释放时兜底清理：面板挂在root的CanvasLayer上，
## 不随Temple自动销毁；重开局（Main._clear_game）会free神庙，
## 若此处不关闭，面板与TEMPLE_CHOICE上下文都会残留
func _exit_tree() -> void:
	_close_panel()

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

	## 玩家在交互范围内且未交互：绘制交互提示（_player_near为节流探测缓存）
	if not _interacted and not _vanishing and _player_near:
		var hint_color: Color = Color(0.9, 0.85, 1.0, 0.9)
		draw_string(ThemeDB.fallback_font, Vector2(-32, 40), "按 [E] 进入神庙", \
			HORIZONTAL_ALIGNMENT_CENTER, 64, 10, hint_color)

## ========== 对外接口 ==========

## 玩家是否在交互范围内（GameWorld._handle_manual_pickup调用）
## 返回节流探测缓存（10Hz刷新），避免交互方每帧触发组查询
func is_player_in_range() -> bool:
	return not _interacted and not _vanishing and _player_near

## 玩家交互（GameWorld._handle_manual_pickup在玩家按E时调用）
## 参数：player - 玩家节点
func interact(player: Node) -> void:
	## 已交互/消失中/游戏中断：不响应
	if _interacted or _vanishing:
		return
	if not GameManager.is_playing():
		return
	## 升级三选一面板排队中/正在选择：不允许进入（防止上下文栈与暂停状态交叉）
	if UpgradeManager and UpgradeManager.is_choosing:
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
	## 进入神庙即暂停：覆盖层必须绕过暂停，否则面板自身无法交互
	_overlay_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_overlay_layer)

	## 创建面板
	_panel = TEMPLE_PANEL_SCRIPT.new()
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay_layer.add_child(_panel)
	_panel.setup(_options)

	## 玩家选定选项
	_panel.option_chosen.connect(_on_option_chosen)

	## 暂停战斗（玩家可安心选择；状态机守卫保证只在PLAYING时生效）
	if GameManager and GameManager.is_playing():
		GameManager.pause_game()
		_paused_by_temple = true

	## 注册神庙选择上下文：暂停后移动/射击自然停止，额外放行D-Pad/方向键+确认；
	## push自带0.2s屏蔽期，防止按E交互的同一次按键立刻选中选项（A/E/Space存在键位复用）
	InputManager.push_context("TEMPLE_CHOICE")

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

## 被新神庙替换：未进入的旧神庙立即消散（全局唯一规则）
## 已进入/面板打开中的神庙不消散（此时游戏暂停，正常流程不会有新神庙生成，双保险）
func despawn() -> void:
	if _interacted or _vanishing:
		return
	_vanish()

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
	## 条件注销选择上下文：仅当栈顶确实是神庙上下文时才pop，
	## 防止跨场景重置后误pop破坏新栈
	if InputManager and InputManager.get_current_context() == "TEMPLE_CHOICE":
		InputManager.pop_context()
	## 恢复战斗：仅当暂停由本神庙发起时才恢复（重开局已置PLAYING则resume_game内部守卫会拦）
	if _paused_by_temple and GameManager:
		_paused_by_temple = false
		GameManager.resume_game()
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
		_panel = null
	if _overlay_layer != null and is_instance_valid(_overlay_layer):
		_overlay_layer.queue_free()
		_overlay_layer = null
