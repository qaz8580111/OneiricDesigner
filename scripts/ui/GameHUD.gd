## GameHUD.gd - 游戏 HUD 界面脚本
## 职责：显示玩家健康状态（血量）、梦境碎片数量、难度、装备护盾状态等实时游戏信息
## 继承：Control（Godot 4的UI控制节点，作为HUD容器）
## 数据流（被动刷新，HUD不持有游戏逻辑状态）：
##   Player.dream_fragment_changed / HealthController(health_changed, player_died) → 血量与碎片显示
##   DifficultyManager(difficulty_changed) → 难度文字
##   EquipmentShieldComponent(shield_equipped/shield_hit/...) → 护盾类型图标与耐久显示
extends Control

## 图标加载库（按"icon_<id>.png"路径契约自动加载，缺失时回退文字图标）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 血量条节点，用于显示玩家核心血量
@onready var health_bar: ProgressBar = $HealthBar

## 梦境碎片标签节点，用于显示玩家当前拥有的梦境碎片数量
@onready var fragment_label: Label = $FragmentLabel

## 难度标签节点，显示当前难度等级（随时间提升）
@onready var diff_label: Label = $DiffLabel

## ========== Buff图标栏（按稀有度三行分区展示） ==========

## 三行图标容器缓存：key=稀有度枚举值(2史诗/1稀有/0普通)，value=该行的HBoxContainer
## 设计意图：按稀有度分行且从高到低排列（史诗最上、普通最下），
##           玩家扫一眼左上角即可判断当前build的强度构成
var _buff_rows: Dictionary = {}

## Buff图标缓存字典：key=effect_id, value=对应图标节点
var _buff_icons: Dictionary = {}

## 单个Buff图标的尺寸（正方形，像素）
const BUFF_ICON_SIZE: float = 36.0

## Buff图标之间的间距（像素）
const BUFF_ICON_GAP: float = 6.0

## 三行图标区的起始y（护盾显示区84~120之下，与经验条/碎片统计彻底分离不遮挡）
const BUFF_ROWS_START_Y: float = 130.0

## 行间距 = 图标高度 + 图标间距（三行紧凑排列）
const BUFF_ROW_SPACING: float = BUFF_ICON_SIZE + BUFF_ICON_GAP

## ========== 装备护盾显示（左上角：类型图标 + 耐久度） ==========

## 护盾显示面板容器（图标+名称耐久文字+耐久条，未装备护盾时整体隐藏）
var _shield_panel: HBoxContainer = null
## 护盾图标底板（Panel，底色随护盾颜色，图标缺失时作为类型色块兜底）
var _shield_icon_holder: Panel = null
## 护盾图标纹理矩形（真实图标贴图，缺失时隐藏）
var _shield_icon_rect: TextureRect = null
## 护盾名称+耐久数值标签（如"冰霜护盾 45/60"）
var _shield_name_label: Label = null
## 护盾耐久条（颜色随护盾类型）
var _shield_durability_bar: ProgressBar = null
## 装备护盾组件引用（数据源：Player下的EquipmentShieldComponent节点）
var _equipment_shield: Node = null
## 当前显示的护盾id（防止节流刷新时重复重建图标/颜色）
var _shield_display_id: String = ""

## ========== 成员变量（运行时数据） ==========

## 玩家引用，用于获取玩家状态和连接信号
var _player: Node2D = null

## 当前梦境碎片数量（用于显示）
var _dream_fragment: int = 0

## 健康控制器引用，用于监听玩家健康状态变化
var _health_controller: Node = null

## ---------- FPS 计数器（可选显示模块） ----------
## 是否启用FPS显示（从 settings.cfg 读取 show_fps）
var _show_fps: bool = false

## 动态创建的FPS标签（未启用时为null，节省节点/绘制开销）
var _fps_label: Label = null

## FPS 采样定时器：与 _fps_frame_count 配合每 0.25s 刷新一次文字
var _fps_timer: float = 0.0
var _fps_frame_count: int = 0
const FPS_REFRESH_INTERVAL: float = 0.25  # 每秒4次刷新：流畅 + 低CPU

## ---------- 顶部常驻状态栏（直播增强：观众可读性） ----------
## 存活时间标签（顶部居中左）
var _time_label: Label = null
## 击杀数标签（顶部居中中）
var _kills_label: Label = null
## 最高连击标签（顶部居中右）
var _max_combo_label: Label = null
## 状态栏刷新节流计时器（0.5秒刷新一次，避免每帧读单例）
var _stat_refresh_timer: float = 0.0
const STAT_REFRESH_INTERVAL: float = 0.5

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 尝试查找玩家，如果找不到则延迟查找
	if not _find_player():
		call_deferred("_deferred_find_player")

	## ========== 难度/词条系统信号连接 ==========

	## 监听难度变化信号：更新难度文字（颜色随难度加深，制造紧迫感）
	if DifficultyManager:
		DifficultyManager.difficulty_changed.connect(_on_difficulty_changed)

	## 监听已获得词条变化：新增技能/层数提升时刷新左上角buff图标栏
	## 数据流：UpgradeManager.apply_upgrade → upgrades_changed → 此回调
	if UpgradeManager:
		UpgradeManager.upgrades_changed.connect(_on_upgrades_changed)

	## 初始化经验条/等级/难度显示（读取单例当前值，兜底中途创建HUD的情况）
	_refresh_progress_displays()

	## ========== Buff图标栏初始化 ==========
	## 设计意图：左上角按稀有度三行排列已获得的技能图标（史诗/稀有/普通自上而下，
	## 含层数角标），让玩家直观看到当前持有哪些词条、各自几级与强度构成
	_build_buff_bar()
	## ========== 装备护盾显示初始化 ==========
	## 护盾类型图标+耐久条（未装备时隐藏，装备后常驻左上角经验条下方）
	_build_shield_display()
	## 面板就绪后立即刷新一次（兜底HUD在护盾已装备后才创建的情况；
	## _find_player中的那次刷新因面板未构建被空引用保护跳过）
	_refresh_shield_display()
	## 容器就绪后立即刷新一次（HUD可能在已有词条后才创建）
	if UpgradeManager:
		_refresh_buff_icons(UpgradeManager.get_acquired_upgrades())

	## 最后：根据 Settings 保存的 show_fps 初始化 FPS 标签
	_init_fps_display()

	## ========== 连击HUD挂载 ==========
	## ComboHUD 作为子节点挂到 GameHUD 下，自动跟随 GameHUD 生命周期
	var ComboHUDClass = preload("res://scripts/ui/ComboHUD.gd")
	var combo_hud: Control = Control.new()
	combo_hud.name = "ComboHUD"
	combo_hud.set_script(ComboHUDClass)
	combo_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(combo_hud)

	## ========== 顶部状态栏（直播增强：观众可读性） ==========
	## 设计意图：非操作观众一眼看到"活了多久/杀了多少/最高连击"，
	## 位置在屏幕顶部居中（原底部栏整体上移，替代原顶部计时标签的位置，
	## 避免时间信息在顶部/底部重复出现）
	_build_top_status_bar()

	## ========== 右上角小地图挂载 ==========
	## 实时显示玩家位置 + 商店/神庙标记（存在时），作为 GameHUD 子节点跟随生命周期
	var MinimapClass = preload("res://scripts/ui/Minimap.gd")
	var minimap: Control = MinimapClass.new()
	minimap.name = "Minimap"
	add_child(minimap)

## ========== FPS 计数器：读取设置 + 动态创建/刷新标签 ==========

## 读取 settings.cfg 中的 show_fps 值：true 就创建 Label 并启动 _process 计数，false 则什么都不做
func _init_fps_display() -> void:
	var config := ConfigFile.new()
	var err: int = config.load("user://settings.cfg")
	if err == OK:
		_show_fps = bool(config.get_value("Settings", "show_fps", false))
	else:
		_show_fps = false  # 默认不显示（避免影响首次游戏体验）

	if _show_fps:
		## 动态创建 FPS 标签（放在 HUD 左上角、buff三行图标区下方，不遮挡其他信息）
		## buff三行图标区在y=130~250，故FPS从y=256开始
		_fps_label = Label.new()
		_fps_label.name = "FPSLabel"
		_fps_label.text = "FPS: --"
		_fps_label.position = Vector2(20, 256)
		_fps_label.size = Vector2(200, 24)
		_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		## 样式：白色半透明加粗字体 + 青色数值，性能调试友好
		_fps_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0, 0.95))
		_fps_label.add_theme_font_size_override("font_size", 18)
		add_child(_fps_label)
		## 重置采样计数
		_fps_timer = 0.0
		_fps_frame_count = 0
		## 设置 process_mode 启用 _process 帧计数（HUD 根节点默认已是 INHERIT，这里仅记录）
		set_process(true)

## _process：FPS 计数 + 周期性刷新顶部状态栏与护盾显示
## FPS 只在 _show_fps=true 时跑计数逻辑；状态栏与护盾显示始终刷新（节流0.5秒）
func _process(delta: float) -> void:
	## ---------- 顶部状态栏与护盾显示刷新（节流0.5秒） ----------
	if GameManager.is_playing():
		_stat_refresh_timer += delta
		if _stat_refresh_timer >= STAT_REFRESH_INTERVAL:
			_stat_refresh_timer = 0.0
			_refresh_top_status()
			## 护盾耐久回盾是持续过程（无信号通知），靠节流轮询同步进度条
			_refresh_shield_display()

	## ---------- FPS 计数 ----------
	if not _show_fps or _fps_label == null:
		return

	## 每帧 +1 帧计数 + 累计时间
	_fps_frame_count += 1
	_fps_timer += delta

	## 到达刷新阈值（默认0.25s）：计算平均FPS并刷新文字
	if _fps_timer >= FPS_REFRESH_INTERVAL:
		var avg_fps: float = float(_fps_frame_count) / maxf(_fps_timer, 0.0001)
		## 高帧率绿色 / 正常白色 / 低帧率红色警示
		var fps_text: String
		if avg_fps >= 55.0:
			fps_text = "FPS: %d  ✓" % int(round(avg_fps))
			_fps_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5, 0.95))
		elif avg_fps >= 30.0:
			fps_text = "FPS: %d" % int(round(avg_fps))
			_fps_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95, 0.95))
		else:
			fps_text = "FPS: %d  !" % int(round(avg_fps))
			_fps_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45, 0.95))
		_fps_label.text = fps_text

		## 清零进入下一采样窗口
		_fps_timer = 0.0
		_fps_frame_count = 0

## 刷新难度显示（读取DifficultyManager的当前状态）
func _refresh_progress_displays() -> void:
	## 难度文字
	if diff_label and DifficultyManager:
		diff_label.text = DifficultyManager.get_difficulty_label()

## 延迟查找玩家（第一次查找失败后调用）
func _deferred_find_player() -> void:
	## 如果仍然找不到玩家，通过 process_frame 信号持续查找
	if not _find_player():
		get_tree().process_frame.connect(_on_process_frame_once)

## process_frame 回调（只触发一次）
## 用于在玩家节点创建后立即找到并连接信号
func _on_process_frame_once() -> void:
	## 断开信号（只需要查找一次）
	get_tree().process_frame.disconnect(_on_process_frame_once)
	## 再次尝试查找玩家
	_find_player()

## ========== 玩家查找与信号连接 ==========

## 查找玩家并连接相关信号
## 返回：true表示找到玩家，false表示未找到
func _find_player() -> bool:
	## 从"player"组查找玩家
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() <= 0:
		return false
	
	## 获取玩家引用
	_player = players[0] as Node2D

	## ========== 装备护盾显示接管 ==========
	## 获取装备护盾组件引用（护盾统计显示的数据源）
	_equipment_shield = _player.get_node_or_null("EquipmentShieldComponent")
	if _equipment_shield != null:
		## 装备变更信号：拾取/替换/卸下护盾时立即刷新显示（含显隐切换）
		if _equipment_shield.has_signal("shield_equipped"):
			_equipment_shield.connect("shield_equipped", _on_shield_equipped_changed)
		## 受击信号：耐久扣减立即刷新（避免等待节流轮询的视觉延迟）
		if _equipment_shield.has_signal("shield_hit"):
			_equipment_shield.connect("shield_hit", _on_shield_vital_changed)
		## 破碎/回满信号：状态突变立即同步
		if _equipment_shield.has_signal("shield_broken"):
			_equipment_shield.connect("shield_broken", _on_shield_state_changed)
		if _equipment_shield.has_signal("shield_regen_full"):
			_equipment_shield.connect("shield_regen_full", _on_shield_state_changed)
	
	## 连接梦境碎片变化信号：当玩家收集梦境碎片时触发回调
	if _player.has_signal("dream_fragment_changed"):
		_player.connect("dream_fragment_changed", _on_dream_fragment_changed)
	
	## 获取玩家的健康控制器节点
	_health_controller = _player.get_node_or_null("HealthController")
	
	## 如果有健康控制器，连接健康相关信号
	if _health_controller != null:
		## 连接健康状态变化信号：当护盾/核心血变化时触发回调
		if _health_controller.has_signal("health_changed"):
			_health_controller.connect("health_changed", _on_health_changed)
		## 连接玩家死亡信号：当玩家死亡时触发回调
		if _health_controller.has_signal("player_died"):
			_health_controller.connect("player_died", _on_player_killed)
	## 如果没有健康控制器（备用方案），连接玩家自身的信号
	elif _player.has_signal("damaged"):
		_player.connect("damaged", _on_player_damaged)
		if _player.has_signal("killed"):
			_player.connect("killed", _on_player_killed)
	
	## 初始化梦境碎片显示
	_dream_fragment = _player.dream_fragment
	_update_fragment_display()
	
	## 初始化血量显示
	if _health_controller != null:
		## 通过健康控制器获取当前生存状态并更新显示
		var state: Dictionary = _health_controller.get_survival_state()
		_update_health_display(state)
	## 备用方案：直接读取玩家的 health 和 max_health 属性
	elif "health" in _player and "max_health" in _player:
		update_health(_player.health, _player.max_health)

	## 首次连接后立即刷新一次护盾显示（兜底HUD在护盾已装备后才创建的情况）
	## 面板未构建时该调用被内部空引用保护跳过，_ready构建面板后会再次刷新
	_refresh_shield_display()

	return true

## ========== 血量更新方法 ==========

## 更新血量显示（简单版本，备用方案）
## 参数：current - 当前血量，max - 最大血量
func update_health(current: int, max: int) -> void:
	if health_bar:
		health_bar.max_value = max
		health_bar.value = current

## 更新梦境碎片显示
func _update_fragment_display() -> void:
	if fragment_label:
		fragment_label.text = "梦境碎片: %d" % _dream_fragment

## 更新健康显示（通过生存状态字典）
## 参数：state - 包含护盾、核心血、红血状态等信息的字典
func _update_health_display(state: Dictionary) -> void:
	if health_bar:
		## 获取核心血量和最大核心血量
		var core_hp: float = state.get("core", 0.0)
		var max_core: float = state.get("max_core", 100.0)
		## 设置血量条的最大值和当前值
		health_bar.max_value = max_core
		health_bar.value = core_hp
		
		## 如果处于红血状态，将血量条设为红色警示
		if state.get("is_critical", false):
			health_bar.modulate = Color(1, 0.3, 0.3, 1)
		else:
			## 正常状态下使用白色
			health_bar.modulate = Color.WHITE

## ========== 信号回调方法 ==========

## 健康状态变化回调：当护盾/核心血变化时调用
## 参数：state - 最新的生存状态字典
func _on_health_changed(state: Dictionary) -> void:
	_update_health_display(state)

## 玩家受伤回调（备用方案，无健康控制器时使用）
## 参数：amount - 受到的伤害数值
func _on_player_damaged(amount: int) -> void:
	## 如果玩家有 health 和 max_health 属性，更新血量显示
	if _player and "health" in _player and "max_health" in _player:
		update_health(_player.health, _player.max_health)

## 梦境碎片变化回调：当玩家收集梦境碎片时调用
## 参数：amount - 新的梦境碎片数量
func _on_dream_fragment_changed(amount: int) -> void:
	## 更新当前碎片数量
	_dream_fragment = amount
	## 更新显示
	_update_fragment_display()

## 难度变化回调：更新难度文字与颜色（响应DifficultyManager.difficulty_changed）
## 参数：new_level - 新难度等级
func _on_difficulty_changed(new_level: int) -> void:
	if diff_label == null:
		return
	## 更新难度文字
	diff_label.text = "难度 %d" % new_level
	## 颜色随难度渐进变化：1-2级灰色 → 3-4级黄色 → 5级以上红色（紧迫感）
	if new_level >= 5:
		diff_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	elif new_level >= 3:
		diff_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	else:
		diff_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))

## ========== Buff图标栏 ==========

## 构建Buff图标三行容器（左上角护盾显示区下方，按稀有度从高到低）
## 行序：史诗(rarity=2)最上 → 稀有(1) → 普通(0)最下；空行不渲染任何内容
func _build_buff_bar() -> void:
	## 固定三行槽位：保证不同稀有度图标位置稳定（不会因获得顺序跳行）
	for rarity: int in [2, 1, 0]:
		var row: HBoxContainer = HBoxContainer.new()
		## 行命名便于调试定位（Epic/Rare/Common）
		row.name = "BuffRow_%s" % ["Epic", "Rare", "Common"][2 - rarity]
		row.add_theme_constant_override("separation", int(BUFF_ICON_GAP))
		## 行y坐标 = 起始y + 行索引×行距（史诗第0行/稀有第1行/普通第2行）
		var row_index: int = 2 - rarity
		row.position = Vector2(20, BUFF_ROWS_START_Y + BUFF_ROW_SPACING * float(row_index))
		## 不拦截鼠标（纯展示）
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)
		_buff_rows[rarity] = row

## 稀有度对应的图标底色（普通灰白/稀有蓝/史诗紫，与三选一面板配色一致）
func _get_rarity_color(rarity: int) -> Color:
	match rarity:
		1:
			return Color(0.4, 0.7, 1.0)    ## 稀有：蓝色
		2:
			return Color(0.8, 0.4, 1.0)    ## 史诗：紫色
		_:
			return Color(0.85, 0.85, 0.9)  ## 普通：浅灰白

## 刷新Buff图标栏（响应UpgradeManager.upgrades_changed信号）
## 设计意图：增量更新——已存在的词条id保留节点（仅更新层数角标，避免闪烁），
##           新增的创建图标并放入其稀有度对应行，已移除的销毁节点
## 参数：acquired - get_acquired_upgrades()返回的词条信息字典数组
func _refresh_buff_icons(acquired: Array) -> void:
	if _buff_rows.is_empty():
		return

	## 构建当前词条id集合（用于判断哪些图标需要保留）
	var current_ids: Dictionary = {}
	for info in acquired:
		current_ids[info["id"]] = info

	## 移除不再激活的buff图标
	for eid in _buff_icons.keys():
		if not current_ids.has(eid):
			var old: Control = _buff_icons[eid]
			if old != null and is_instance_valid(old):
				old.queue_free()
			_buff_icons.erase(eid)

	## 新增激活的buff图标；已存在的仅同步层数角标
	for eid in current_ids.keys():
		var info: Dictionary = current_ids[eid]
		if _buff_icons.has(eid):
			_update_buff_badge(_buff_icons[eid], int(info["stacks"]), int(info["max_stacks"]))
			continue
		var icon: Control = _create_buff_icon(info)
		## 按词条稀有度放入对应行（史诗最上/稀有中/普通最下；同一id稀有度固定不会换行）
		var row: HBoxContainer = _buff_rows[int(info["rarity"])]
		row.add_child(icon)
		_buff_icons[eid] = icon

## 创建单个Buff图标（稀有度底色+技能名首2字+右下角层数角标）
## 参数：info - 词条信息字典（id/name/rarity/stacks/max_stacks）
## 返回：Buff图标节点
func _create_buff_icon(info: Dictionary) -> Control:
	## 外层Panel作为底色方块
	var icon: Panel = Panel.new()
	icon.custom_minimum_size = Vector2(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 用StyleBoxFlat设置稀有度底色与白色描边
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = _get_rarity_color(int(info["rarity"]))
	style.set_content_margin_all(0.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.4)
	icon.add_theme_stylebox_override("panel", style)

	## 内层显示内容：优先真实图标（IconLibrary按id+稀有度加载），
	## 图标缺失时回退技能名首2字文字（容错，游戏不因缺图报错）
	var icon_tex: Texture2D = IconLibraryLib.get_upgrade_icon(String(info["id"]), int(info["rarity"]))
	if icon_tex != null:
		## 真实图标：TextureRect等比铺满（内缩1px露出稀有度边框色）
		var tex_rect: TextureRect = TextureRect.new()
		tex_rect.texture = icon_tex
		## EXPAND_IGNORE_SIZE：忽略纹理原始1024px尺寸，按容器大小显示
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		## KEEP_ASPECT_CENTERED：等比缩放居中，不拉伸变形
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		## 四边内缩1px：露出底层Panel的白色描边与稀有度底色边线
		tex_rect.offset_left = 1
		tex_rect.offset_top = 1
		tex_rect.offset_right = -1
		tex_rect.offset_bottom = -1
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.add_child(tex_rect)
	else:
		## 回退：Label显示技能名称首2字符（中文游戏名的快速识别方式）
		var label: Label = Label.new()
		var skill_name_fallback: String = String(info["name"])
		label.text = skill_name_fallback.substr(0, 2)
		label.add_theme_color_override("font_color", Color(0, 0, 0, 0.85))
		label.add_theme_font_size_override("font_size", 13)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.add_child(label)

	## 层数角标（右下角，Lv.2起显示；满级5用金色）
	var badge: Label = Label.new()
	badge.name = "LevelBadge"
	badge.add_theme_font_size_override("font_size", 11)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.offset_left = -10
	badge.offset_top = -12
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.add_child(badge)
	_update_buff_badge(icon, int(info["stacks"]), int(info["max_stacks"]))

	## Tooltip显示完整技能名与层数（鼠标悬停查看）
	icon.tooltip_text = "%s  Lv.%d/%d" % [String(info["name"]), int(info["stacks"]), int(info["max_stacks"])]

	return icon

## 更新图标右下角的层数角标（1级不显示，2级起白字，满级金字）
## 参数：icon - 图标节点；stacks - 当前层数；max_stacks - 上限
func _update_buff_badge(icon: Control, stacks: int, max_stacks: int) -> void:
	var badge: Label = icon.get_node_or_null("LevelBadge")
	if badge == null:
		return
	if stacks <= 1:
		badge.text = ""
		return
	badge.text = "×%d" % stacks
	if stacks >= max_stacks:
		badge.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))  ## 满级金色
	else:
		badge.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))  ## 普通白色
	## 描边保证深色底图上也清晰可读
	badge.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	badge.add_theme_constant_override("outline_size", 3)

## 已获得词条变化回调（响应UpgradeManager.upgrades_changed）
## 参数：acquired - 最新的词条信息数组
func _on_upgrades_changed(acquired: Array) -> void:
	_refresh_buff_icons(acquired)

## ========== 装备护盾显示（类型图标 + 健康度） ==========

## 构建护盾显示面板（左上角经验条下方，未装备时整体隐藏）
## 结构：护盾面板(HBox) → 图标底板(Panel，底色随护盾色) + 信息列(VBox：名称耐久文字+耐久条)
func _build_shield_display() -> void:
	_shield_panel = HBoxContainer.new()
	_shield_panel.name = "ShieldDisplay"
	_shield_panel.add_theme_constant_override("separation", 6)
	## 位置：经验条(72px+8高)下方，与碎片统计、经验条彻底分离
	_shield_panel.position = Vector2(20, 84)
	_shield_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.visible = false  ## 初始无护盾，装备后由刷新逻辑显示
	add_child(_shield_panel)

	## 图标底板：36x36方块（尺寸与buff图标一致），底色随护盾颜色
	_shield_icon_holder = Panel.new()
	_shield_icon_holder.custom_minimum_size = Vector2(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
	_shield_icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(_shield_icon_holder)

	## 信息列：名称耐久文字 + 耐久条（垂直排列）
	var info_box: VBoxContainer = VBoxContainer.new()
	info_box.add_theme_constant_override("separation", 2)
	info_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(info_box)

	## 名称+耐久数值标签（如"冰霜护盾 45/60"），描边保证任意背景可读
	_shield_name_label = Label.new()
	_shield_name_label.add_theme_font_size_override("font_size", 12)
	_shield_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_shield_name_label.add_theme_constant_override("outline_size", 3)
	_shield_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_box.add_child(_shield_name_label)

	## 耐久条（8px细条，颜色随护盾类型，关闭默认百分比文字）
	_shield_durability_bar = ProgressBar.new()
	_shield_durability_bar.custom_minimum_size = Vector2(150, 8)
	_shield_durability_bar.show_percentage = false
	_shield_durability_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_box.add_child(_shield_durability_bar)

## 刷新护盾显示（显隐/图标/名称/耐久条全面同步）
## 数据流：EquipmentShieldComponent(get_shield_data/get_current_hp) → 本方法写UI
## 调用时机：护盾信号立即刷新 + _process节流轮询（回盾是持续过程无信号）
func _refresh_shield_display() -> void:
	## 面板未构建时直接返回（_find_player先于_ready构建面板执行的兜底）
	if _shield_panel == null:
		return
	## 懒获取装备护盾组件（玩家可能在HUD之后创建）
	if _equipment_shield == null and _player != null:
		_equipment_shield = _player.get_node_or_null("EquipmentShieldComponent")

	## 读取护盾数据与耐久（有护盾数据就显示，耐久为0也保持显示——等待5秒回盾）
	var data: Resource = null
	var hp: float = 0.0
	var max_hp: float = 0.0
	var stack: int = 1
	if _equipment_shield != null and _equipment_shield.has_method("get_shield_data"):
		data = _equipment_shield.get_shield_data()
		if data != null:
			hp = _equipment_shield.get_current_hp()
			max_hp = _equipment_shield.get_max_hp()
			if _equipment_shield.has_method("get_shield_stack"):
				stack = _equipment_shield.get_shield_stack()
	## 有护盾数据就显示面板（即使耐久为0也保持——护盾会在5秒后回盾满值）
	_shield_panel.visible = data != null
	if data == null:
		_shield_display_id = ""
		return

	## 护盾颜色（缺属性时兜底默认青蓝色，与掉落物视觉一致）
	var shield_color: Color = data.shield_color if "shield_color" in data else Color(0.3, 0.6, 1.0)
	var shield_id: String = str(data.shield_id) if "shield_id" in data else ""

	## 护盾类型变化时才重建图标与配色（节流轮询下避免每0.5秒重建节点）
	if shield_id != _shield_display_id:
		_shield_display_id = shield_id
		## 图标底板底色=护盾颜色（白色细描边，与buff图标框风格统一）
		var holder_style: StyleBoxFlat = StyleBoxFlat.new()
		holder_style.bg_color = shield_color
		holder_style.set_content_margin_all(0.0)
		holder_style.corner_radius_top_left = 4
		holder_style.corner_radius_top_right = 4
		holder_style.corner_radius_bottom_left = 4
		holder_style.corner_radius_bottom_right = 4
		holder_style.border_width_left = 1
		holder_style.border_width_right = 1
		holder_style.border_width_top = 1
		holder_style.border_width_bottom = 1
		holder_style.border_color = Color(1, 1, 1, 0.4)
		_shield_icon_holder.add_theme_stylebox_override("panel", holder_style)
		## 名称与耐久条颜色随护盾类型
		_shield_name_label.add_theme_color_override("font_color", shield_color)
		_shield_durability_bar.tint_over = shield_color
		_shield_durability_bar.tint_under = Color(0.3, 0.3, 0.3, 0.5)
		## 类型图标：IconLibrary按icon_<shield_id>.png契约加载；缺失时隐藏贴图露出色块
		var icon_tex: Texture2D = IconLibraryLib.get_shield_icon(shield_id)
		if icon_tex != null:
			## 首次用到时创建贴图矩形（等比缩放居中，内缩1px露出底板描边）
			if _shield_icon_rect == null:
				_shield_icon_rect = TextureRect.new()
				_shield_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				_shield_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				_shield_icon_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				_shield_icon_rect.offset_left = 1
				_shield_icon_rect.offset_top = 1
				_shield_icon_rect.offset_right = -1
				_shield_icon_rect.offset_bottom = -1
				_shield_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_shield_icon_holder.add_child(_shield_icon_rect)
			_shield_icon_rect.texture = icon_tex
			_shield_icon_rect.visible = true
		elif _shield_icon_rect != null:
			_shield_icon_rect.visible = false

	## 名称+耐久数值与耐久条进度（每次刷新都更新——耐久是高频变化数据）
	## 叠层显示：2层以上在名称后加×N；耐久为0时显示"回盾中"提示
	var display_name: String = str(data.display_name) if "display_name" in data else "护盾"
	if stack > 1:
		display_name += " ×%d" % stack
	if hp <= 0.0:
		## 护盾破碎等待回盾：显示"回盾中"替代数值
		_shield_name_label.text = "%s 回盾中..." % display_name
		_shield_durability_bar.value = 0.0
	else:
		_shield_name_label.text = "%s %d/%d" % [display_name, int(ceilf(hp)), int(max_hp)]
		_shield_durability_bar.max_value = max_hp
		_shield_durability_bar.value = hp

## 装备变更信号回调（拾取/替换/卸下护盾时触发）
func _on_shield_equipped_changed(_data: Resource) -> void:
	_refresh_shield_display()

## 护盾受击信号回调（耐久扣减立即同步，参数不使用仅触发刷新）
func _on_shield_vital_changed(_remaining_hp: float, _absorbed: float) -> void:
	_refresh_shield_display()

## 护盾破碎/回满信号回调（无参信号）
func _on_shield_state_changed() -> void:
	_refresh_shield_display()

## 玩家死亡回调：当玩家死亡时调用
func _on_player_killed() -> void:
	## 隐藏 HUD（游戏结束时不再显示）
	visible = false

## ========== 顶部常驻状态栏（直播增强：观众可读性） ==========

## 构建顶部常驻状态栏（屏幕顶部居中：存活时间 | 击杀数 | 最高连击）
## 设计意图：非操作观众一眼看到本局核心数据，创造"主播很猛"的印象
## 位置：屏幕顶部居中，距顶边 12px（原底部栏上移至此，时间信息不再重复出现）
func _build_top_status_bar() -> void:
	## 状态栏配置：[标签前缀, 颜色]
	var configs: Array = [
		["⏱", Color(0.75, 0.9, 1.0)],      ## 存活时间：淡蓝色
		["💀", Color(1.0, 0.5, 0.4)],       ## 击杀数：淡红色
		["🔥", Color(1.0, 0.85, 0.3)],      ## 最高连击：金色
	]
	var labels: Array = []

	## 三栏等宽，每栏 120px，总宽 360px，居中
	var bar_width: float = 360.0
	var bar_height: float = 28.0
	var column_width: float = bar_width / 3.0

	for i in range(3):
		var label: Label = Label.new()
		label.name = "TopStat_%d" % i
		label.text = "%s --" % configs[i][0]
		label.add_theme_color_override("font_color", configs[i][1])
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		label.add_theme_constant_override("outline_size", 4)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		## 位置：顶部居中，三栏水平排列（距顶12px）
		var center_x: float = get_viewport_rect().size.x * 0.5
		var col_x: float = center_x - bar_width * 0.5 + column_width * float(i)
		label.position = Vector2(col_x, 12.0)
		label.size = Vector2(column_width, bar_height)
		add_child(label)
		labels.append(label)

	_time_label = labels[0]
	_kills_label = labels[1]
	_max_combo_label = labels[2]

## 刷新顶部状态栏文字（节流0.5秒调用一次，避免每帧读单例）
func _refresh_top_status() -> void:
	## 存活时间：从 RunStats 读取，格式 "MM:SS"
	if _time_label and RunStats:
		var total_sec: int = int(RunStats.elapsed_time)
		var mins: int = total_sec / 60
		var secs: int = total_sec % 60
		_time_label.text = "⏱ %02d:%02d" % [mins, secs]

	## 击杀数：从 RunStats 读取
	if _kills_label and RunStats:
		_kills_label.text = "💀 %d" % RunStats.kills

	## 最高连击：从 ComboManager 读取
	if _max_combo_label and ComboManager:
		var max_combo: int = ComboManager.get_max_combo()
		if max_combo > 0:
			_max_combo_label.text = "🔥 %d" % max_combo
		else:
			_max_combo_label.text = "🔥 --"