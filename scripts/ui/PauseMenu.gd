## PauseMenu.gd - 暂停菜单逻辑脚本
## 职责：管理游戏暂停界面，处理继续游戏、打开设置、返回主菜单三种操作
## 继承：Control（UI控件基类，作为暂停菜单的根节点）
## 数据流：按钮点击 / 导航器cancel_pressed(ESC) → 信号(resume_game/open_settings/quit_to_menu) → Main.gd 监听后执行
## 注意：游戏中按ESC打开暂停菜单由 Main.gd 统一处理；暂停菜单打开时按ESC走导航器取消 = 继续游戏
extends Control

## 图标加载库（状态面板显示核心血/属性/技能/护盾图标用；装备面板解析装备图标用）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

## 槽位中文名（索引与 EquipmentData.Slot 枚举对齐：0=武器 1=护甲 2=鞋子 3=盾牌 4=戒指 5=法宝）
## 说明：空槽位没有 EquipmentData 实例、拿不到 get_slot_text()，故此处保留一份槽位名常量
const SLOT_TEXTS: Array[String] = ["武器", "护甲", "鞋子", "盾牌", "戒指", "法宝"]

## 暂停菜单必须在暂停状态下仍能处理输入，需要 ALWAYS 模式
func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

## ========== 信号定义（用于与其他节点通信） ==========

## 继续游戏信号：当用户点击继续游戏按钮时发出，通知上层恢复游戏
signal resume_game()

## 打开设置信号：当用户点击设置按钮时发出，通知上层打开设置界面
signal open_settings()

## 返回主菜单信号：当用户点击返回主菜单按钮时发出，通知上层返回主菜单
signal quit_to_menu()

## ========== UI节点引用（使用 @onready 延迟初始化） ==========

## 暂停菜单标题标签（显示"暂停"）
@onready var title_label: Label = $VBoxContainer/Title

## 继续游戏按钮
@onready var resume_button: Button = $VBoxContainer/ResumeButton

## 设置按钮（打开设置界面）
@onready var settings_button: Button = $VBoxContainer/SettingsButton

## 查看状态按钮（打开暂停菜单内的状态子面板）
@onready var status_button: Button = $VBoxContainer/StatusButton

## 装备背包按钮（打开暂停菜单内的装备/背包子面板）
@onready var equipment_button: Button = $VBoxContainer/EquipmentButton

## 返回主菜单按钮
@onready var quit_button: Button = $VBoxContainer/QuitButton

## ========== 菜单导航器（用于手柄/键盘导航） ==========

## 菜单导航器脚本（用于处理键盘/手柄的菜单导航）
var MENU_NAVIGATOR_SCRIPT: Script = load("res://scripts/autoload/MenuController.gd")

## 菜单导航器实例
var _navigator: Node = null

## ========== 查看状态子面板（暂停菜单内） ==========

## 状态子面板根容器（隐藏主菜单按钮后显示，返回后隐藏）
var _status_panel: Control = null

## 状态子面板标题标签
var _status_title_label: Label = null

## 状态子面板行容器（属性/技能/护盾逐行展示）
var _status_rows: VBoxContainer = null

## 状态子面板返回按钮
var _status_back_button: Button = null

## ========== 装备/背包子面板（暂停菜单内） ==========

## 装备/背包子面板根容器（隐藏主菜单按钮后显示）
var _equipment_panel: Control = null

## 装备/背包子面板标题标签
var _equipment_title_label: Label = null

## "已装备"栏标题标签（语言切换时需更新）
var _equipment_slots_header: Label = null

## 已装备槽位列表容器（6 个槽位各一个按钮；已装备的可点击卸下）
var _equipment_slots_box: VBoxContainer = null

## 背包装备列表容器（每件装备一个按钮；点击穿戴）
var _equipment_backpack_box: VBoxContainer = null

## 背包容量提示标签（显示"背包 (n/容量)"，满时追加提示）
var _equipment_capacity_label: Label = null

## 装备/背包子面板底部操作提示标签
var _equipment_hint_label: Label = null

## 装备/背包子面板返回按钮
var _equipment_back_button: Button = null

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 构建状态子面板（先于文本刷新，保证标题/返回按钮引用就绪）
	_build_status_panel()
	## 构建装备/背包子面板（同样先于文本刷新）
	_build_equipment_panel()
	## 更新界面文本（支持多语言）
	_update_text()
	
	## 连接按钮信号到处理方法
	resume_button.pressed.connect(_on_resume_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	status_button.pressed.connect(_on_status_button_pressed)
	equipment_button.pressed.connect(_on_equipment_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	
	## 监听语言变化信号（语言切换时更新界面文本）
	TranslationManager.language_changed.connect(_on_language_changed)

	## 添加菜单导航器为子节点（用于键盘/手柄导航）
	if MENU_NAVIGATOR_SCRIPT != null:
		_navigator = MENU_NAVIGATOR_SCRIPT.new()
		add_child(_navigator)
		## 连接导航器的取消信号到统一取消分发（状态面板打开时先返回主菜单，否则继续游戏）
		_navigator.cancel_pressed.connect(_on_navigator_cancel)
		## 等待一帧确保节点完全加入场景树
		await get_tree().process_frame
		## 激活导航器
		_navigator.activate(self)
	else:
		print("MenuNavigator script not found!")

## _exit_tree() - 节点离开场景树时调用，用于清理
func _exit_tree() -> void:
	## 如果导航器存在，停用导航器
	if _navigator != null:
		_navigator.deactivate()

## ========== 界面文本更新方法 ==========

## 更新界面文本（支持多语言）
func _update_text() -> void:
	title_label.text = TranslationManager.t("PAUSED_TITLE")
	resume_button.text = TranslationManager.t("BUTTON_RESUME")
	settings_button.text = TranslationManager.t("BUTTON_SETTINGS")
	status_button.text = TranslationManager.t("BUTTON_VIEW_STATUS")
	equipment_button.text = TranslationManager.t("BUTTON_EQUIPMENT")
	quit_button.text = TranslationManager.t("BUTTON_QUIT_TO_MENU")
	## 状态子面板标题与返回按钮（构建后存在才更新，避免_ready早期空引用）
	if _status_title_label != null:
		_status_title_label.text = TranslationManager.t("STATUS_TITLE")
	if _status_back_button != null:
		_status_back_button.text = TranslationManager.t("BUTTON_BACK")
	## 装备/背包子面板固定文本（列表内文本由数据驱动，在刷新时生成）
	if _equipment_title_label != null:
		_equipment_title_label.text = TranslationManager.t("EQUIPMENT_TITLE")
	if _equipment_slots_header != null:
		_equipment_slots_header.text = TranslationManager.t("EQUIPMENT_SLOTS")
	if _equipment_hint_label != null:
		_equipment_hint_label.text = TranslationManager.t("EQUIPMENT_HINT")
	if _equipment_back_button != null:
		_equipment_back_button.text = TranslationManager.t("BUTTON_BACK")

## ========== 信号回调方法 ==========

## 语言变化回调：重新更新界面文本
func _on_language_changed(_lang: String) -> void:
	_update_text()
	## 装备面板可见时同步重建列表（列表文本由数据生成，非固定 key，需刷新才随语言变化）
	if _equipment_panel != null and _equipment_panel.visible:
		_refresh_equipment_panel()

## 继续游戏按钮点击回调：发出继续游戏信号
func _on_resume_button_pressed() -> void:
	print("Resuming game...")
	resume_game.emit()

## 设置按钮点击回调：发出打开设置信号
func _on_settings_button_pressed() -> void:
	print("Opening settings from pause...")
	open_settings.emit()

## 返回主菜单按钮点击回调：发出返回主菜单信号
func _on_quit_button_pressed() -> void:
	print("Quitting to menu...")
	quit_to_menu.emit()

## ========== 查看状态子面板 ==========

## 查看状态按钮点击回调：打开状态子面板
func _on_status_button_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	_open_status_panel()

## 状态子面板返回按钮点击回调：关闭状态子面板，回到暂停主菜单
func _on_status_back_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	_close_status_panel()

## 导航器取消分发：子面板打开时先返回主菜单，否则（暂停主菜单）继续游戏
## 分发顺序：装备面板 → 状态面板 → 继续游戏（同时最多只有一个子面板可见）
func _on_navigator_cancel() -> void:
	if _equipment_panel != null and _equipment_panel.visible:
		_close_equipment_panel()
	elif _status_panel != null and _status_panel.visible:
		_close_status_panel()
	else:
		_on_resume_button_pressed()

## 构建状态子面板（纯代码UI，隐藏在主菜单之后，点击查看状态时显示）
## 结构：StatusPanel(Control) → StatusTitle + StatusScroll(ScrollContainer→StatusRows) + StatusBackButton
func _build_status_panel() -> void:
	_status_panel = Control.new()
	_status_panel.name = "StatusPanel"
	_status_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_panel.visible = false
	add_child(_status_panel)

	## 标题（顶部居中）
	_status_title_label = Label.new()
	_status_title_label.name = "StatusTitle"
	_status_title_label.anchor_left = 0.0
	_status_title_label.anchor_right = 1.0
	_status_title_label.offset_top = 40.0
	_status_title_label.offset_bottom = 90.0
	_status_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_title_label.add_theme_font_size_override("font_size", 30)
	_status_title_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_status_title_label.add_theme_constant_override("outline_size", 4)
	_status_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_panel.add_child(_status_title_label)

	## 滚动容器（中部，行数多时可滚动，避免溢出屏幕）
	var scroll := ScrollContainer.new()
	scroll.name = "StatusScroll"
	scroll.anchor_left = 0.5
	scroll.anchor_right = 0.5
	scroll.anchor_top = 0.5
	scroll.anchor_bottom = 0.5
	scroll.offset_left = -520.0
	scroll.offset_right = 520.0
	scroll.offset_top = -420.0
	scroll.offset_bottom = 380.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_status_panel.add_child(scroll)

	_status_rows = VBoxContainer.new()
	_status_rows.name = "StatusRows"
	_status_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_rows.add_theme_constant_override("separation", 8)
	scroll.add_child(_status_rows)

	## 返回按钮（底部居中）
	_status_back_button = Button.new()
	_status_back_button.name = "StatusBackButton"
	_status_back_button.anchor_left = 0.5
	_status_back_button.anchor_right = 0.5
	_status_back_button.anchor_top = 1.0
	_status_back_button.anchor_bottom = 1.0
	_status_back_button.offset_left = -120.0
	_status_back_button.offset_right = 120.0
	_status_back_button.offset_top = -70.0
	_status_back_button.offset_bottom = -30.0
	_status_back_button.pressed.connect(_on_status_back_pressed)
	_status_panel.add_child(_status_back_button)

## 打开状态子面板：隐藏主菜单按钮、刷新状态列表、重建导航焦点
func _open_status_panel() -> void:
	if _status_panel == null:
		return
	$VBoxContainer.visible = false
	_status_panel.visible = true
	_refresh_status_list()
	## 焦点列表刷新：隐藏的主菜单按钮不再可聚焦，仅状态面板返回按钮可导航
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 关闭状态子面板：显示主菜单按钮、重建导航焦点
func _close_status_panel() -> void:
	if _status_panel == null:
		return
	_status_panel.visible = false
	$VBoxContainer.visible = true
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 刷新状态列表：清空后按"核心血/属性/技能/护盾"四组逐行填充
## 装备化口径：属性组=全部已装备装备的基础属性词条；技能组=全部已装备装备携带的子弹特效
##             （原「构型」组随装备化删除，构型改由装备主动技能承载、不再单列）
func _refresh_status_list() -> void:
	if _status_rows == null:
		return
	## 清空旧行：用 free() 立即销毁而非 queue_free()，避免本帧内旧行残留导致
	## 重新打开状态面板时出现一帧"新旧行重叠"的视觉闪烁
	for child in _status_rows.get_children():
		child.free()

	## 核心血组（玩家基础生存值：当前/上限）
	## 设计意图：核心血上限会被装备词条提升，但此前面板只列词条、不列结果值，
	##           玩家看不到"上限真的变大了"；补这一行让血量成长像伤害/护盾一样有具体数字
	_add_status_header(TranslationManager.t("STATUS_HEALTH"))
	_add_core_health_row()

	## 属性组（聚合全部已装备装备的基础属性词条）
	_add_status_header(TranslationManager.t("STATUS_ATTR"))
	if not _add_equipped_affix_rows():
		_add_status_empty()

	## 技能组（聚合全部已装备装备携带的子弹特效）
	_add_status_header(TranslationManager.t("STATUS_SKILL"))
	if not _add_equipped_effect_rows():
		_add_status_empty()

	## 护盾组（当前装备护盾）
	_add_status_header(TranslationManager.t("STATUS_SHIELD"))
	_add_shield_row()

## 添加分组标题（核心血/属性/技能/护盾）
func _add_status_header(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.4))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 3)
	_status_rows.add_child(label)

## 添加空提示行（该分组无内容时）
func _add_status_empty() -> void:
	var label := Label.new()
	label.text = TranslationManager.t("STATUS_NONE")
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_status_rows.add_child(label)

## 获取玩家装备组件（状态列表聚合"已装备内容"的唯一数据源）
## 返回：EquipmentComponent 节点；无玩家或未初始化时 null
func _get_equipment_component() -> Node:
	var player: Node = _get_player()
	if player != null and player.has_method("get_equipment_component"):
		return player.get_equipment_component()
	return null

## 添加"全部已装备装备的基础属性词条"行
## 数据流：EquipmentComponent.get_all_equipped() → 各 EquipmentData.affixes → 逐条成行
## 返回：true=至少添加了一行（供调用方决定是否显示空提示）
func _add_equipped_affix_rows() -> bool:
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("get_all_equipped"):
		return false
	var added: bool = false
	for data in comp.get_all_equipped():
		if data == null:
			continue
		## 每件装备的图标/颜色随其稀有度；名字用装备名，等级位显示所属槽位
		var icon_tex: Texture2D = IconLibraryLib.get_equipment_icon(data)
		for affix in data.affixes:
			if affix == null:
				continue
			_add_status_row(icon_tex, data.get_rarity_color(), affix.get_display_text(),
				String(data.get_slot_text()), String(data.display_name))
			added = true
	return added

## 添加"全部已装备装备携带的子弹特效"行
## 数据流：EquipmentComponent.get_all_equipped() → 各 EquipmentData.bullet_effects → 逐条成行
## 返回：true=至少添加了一行（供调用方决定是否显示空提示）
func _add_equipped_effect_rows() -> bool:
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("get_all_equipped"):
		return false
	var added: bool = false
	for data in comp.get_all_equipped():
		if data == null:
			continue
		for effect in data.bullet_effects:
			if effect == null:
				continue
			## 特效无独立图标：沿用所属装备图标；名字取特效名（空则回退 effect_id）
			var effect_name: String = str(effect.display_name) if "display_name" in effect else ""
			if effect_name.is_empty() and "effect_id" in effect:
				effect_name = str(effect.effect_id)
			_add_status_row(IconLibraryLib.get_equipment_icon(data), data.get_rarity_color(),
				effect_name, "Lv.%d" % int(effect.stack_count), String(data.display_name))
			added = true
	return added

## 添加核心血行（显示玩家核心血"当前/上限"，数据源 Player.get_survival_state()）
## 说明：核心血是混合生命系统的最后一层（前两层为装备护盾、分段护盾），
##       本行只反映结果值，不参与任何数值计算；描述位留空（血量红血警示已由 HUD 血条承担）
func _add_core_health_row() -> void:
	var state: Dictionary = {}
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0 and players[0].has_method("get_survival_state"):
		state = players[0].get_survival_state()

	## 玩家不存在或控制器缺失：与护盾/构型一致走空提示，不报错
	if state.is_empty():
		_add_status_empty()
		return

	var core_hp: int = int(round(float(state.get("core", 0.0))))
	var max_core: int = int(round(float(state.get("max_core", 0.0))))
	## 图标复用血量上限词条图（白色普通目录的 icon_upg_max_hp）；色块取血量条同款红
	var icon_tex: Texture2D = IconLibraryLib.get_upgrade_icon("upg_max_hp", 0)
	_add_status_row(icon_tex, Color(1.0, 0.4, 0.4), TranslationManager.t("STATUS_HEALTH"),
		"%d/%d" % [core_hp, max_core], "")

## 添加护盾行（未装备时显示空提示）
func _add_shield_row() -> void:
	var data: Resource = null
	var stack: int = 1
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		var shield_comp: Node = players[0].get_node_or_null("EquipmentShieldComponent")
		if shield_comp != null and shield_comp.has_method("get_shield_data"):
			data = shield_comp.get_shield_data()
			if data != null and shield_comp.has_method("get_shield_stack"):
				stack = shield_comp.get_shield_stack()

	if data == null:
		_add_status_empty()
		return

	var shield_id: String = str(data.shield_id) if "shield_id" in data else ""
	var shield_color: Color = data.shield_color if "shield_color" in data else Color(0.3, 0.6, 1.0)
	var icon_tex: Texture2D = IconLibraryLib.get_shield_icon(shield_id)
	var shield_name: String = str(data.display_name) if "display_name" in data else "护盾"
	var is_special: bool = bool(data.is_special) if "is_special" in data else false
	## 护盾无描述字段，按配置动态生成说明（耐久/单次吸收随叠层放大）
	var desc: String = "耐久 %d · 单次吸收 %d" % [
		int(float(data.max_hp) * float(stack)),
		int(float(data.absorb_per_hit) * float(stack)),
	]
	if is_special:
		desc += " · 特效护盾"
	_add_status_row(icon_tex, shield_color, shield_name, "×%d" % stack, desc)

## 添加一行（图标 + 名称[等级] 描述），用PanelContainer做底框增强可读性
func _add_status_row(icon_tex: Texture2D, color: Color, item_name: String, level_text: String, desc: String) -> void:
	var shell := PanelContainer.new()
	shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.1, 0.6)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	shell.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	shell.add_child(hbox)

	hbox.add_child(_make_status_icon(icon_tex, color))

	var label := Label.new()
	label.text = "%s  [%s]  %s" % [item_name, level_text, desc]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	label.add_theme_constant_override("outline_size", 2)
	hbox.add_child(label)

	_status_rows.add_child(shell)

## 创建28px图标（有贴图用TextureRect，无贴图回退稀有度/护盾色块）
func _make_status_icon(icon_tex: Texture2D, color: Color) -> Control:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(28, 28)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.4)
	panel.add_theme_stylebox_override("panel", style)

	if icon_tex != null:
		var rect := TextureRect.new()
		rect.texture = icon_tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		rect.offset_left = 2
		rect.offset_top = 2
		rect.offset_right = -2
		rect.offset_bottom = -2
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(rect)
	return panel

## ========== 装备/背包子面板 ==========

## 装备背包按钮点击回调：打开装备/背包子面板
func _on_equipment_button_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	_open_equipment_panel()

## 装备/背包子面板返回按钮点击回调：关闭子面板，回到暂停主菜单
func _on_equipment_back_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	_close_equipment_panel()

## 已装备槽位按钮点击回调：把该槽位装备卸下并放回背包
## 参数：slot - 槽位（EquipmentData.Slot）
## 说明：背包已满时卸下会被 BackpackComponent 拒绝（避免装备丢失），刷新后界面保持不变
func _on_equip_slot_pressed(slot: int) -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	var player: Node = _get_player()
	if player != null and player.has_method("unequip_equipment_slot"):
		player.unequip_equipment_slot(slot)
	_refresh_equipment_panel()
	## 列表重建后按钮对象已换新，需让导航器重新收集可聚焦控件
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 背包物品按钮点击回调：穿戴该件装备（同槽位原装备自动回退背包）
## 参数：index - 背包物品下标（0-based，构建按钮时捕获；每次操作后立即重建列表故不会错位）
func _on_backpack_item_pressed(index: int) -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	var player: Node = _get_player()
	if player != null and player.has_method("equip_equipment_from_backpack"):
		player.equip_equipment_from_backpack(index)
	_refresh_equipment_panel()
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 获取玩家节点（装备/背包面板的数据源入口）
## 返回：玩家节点；场景中不存在时返回 null（面板显示空内容而不报错）
func _get_player() -> Node:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0]
	return null

## 构建装备/背包子面板（纯代码UI，隐藏在主菜单之后）
## 结构：EquipmentPanel(Control) → Title + Body(HBox[已装备列, 背包列]) + Hint + BackButton
func _build_equipment_panel() -> void:
	_equipment_panel = Control.new()
	_equipment_panel.name = "EquipmentPanel"
	_equipment_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_equipment_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_equipment_panel.visible = false
	add_child(_equipment_panel)

	## 标题（顶部居中）
	_equipment_title_label = Label.new()
	_equipment_title_label.name = "EquipmentTitle"
	_equipment_title_label.anchor_left = 0.0
	_equipment_title_label.anchor_right = 1.0
	_equipment_title_label.offset_top = 40.0
	_equipment_title_label.offset_bottom = 90.0
	_equipment_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_equipment_title_label.add_theme_font_size_override("font_size", 30)
	_equipment_title_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_equipment_title_label.add_theme_constant_override("outline_size", 4)
	_equipment_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_equipment_panel.add_child(_equipment_title_label)

	## 两栏主体（左栏已装备较窄、右栏背包自适应更宽）
	var body := HBoxContainer.new()
	body.name = "EquipmentBody"
	body.anchor_left = 0.5
	body.anchor_right = 0.5
	body.anchor_top = 0.5
	body.anchor_bottom = 0.5
	body.offset_left = -520.0
	body.offset_right = 520.0
	body.offset_top = -410.0
	body.offset_bottom = 340.0
	body.add_theme_constant_override("separation", 24)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_equipment_panel.add_child(body)

	## 左栏：已装备 6 槽位
	var left := VBoxContainer.new()
	left.name = "EquipmentSlotsColumn"
	left.custom_minimum_size = Vector2(430.0, 0.0)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	body.add_child(left)

	_equipment_slots_header = Label.new()
	_equipment_slots_header.add_theme_font_size_override("font_size", 20)
	_equipment_slots_header.add_theme_color_override("font_color", Color(0.9, 0.85, 0.4))
	_equipment_slots_header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_equipment_slots_header.add_theme_constant_override("outline_size", 3)
	left.add_child(_equipment_slots_header)

	var slots_scroll := ScrollContainer.new()
	slots_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slots_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(slots_scroll)

	_equipment_slots_box = VBoxContainer.new()
	_equipment_slots_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_equipment_slots_box.add_theme_constant_override("separation", 8)
	slots_scroll.add_child(_equipment_slots_box)

	## 右栏：背包列表（容量提示 + 可滚动装备按钮列表）
	var right := VBoxContainer.new()
	right.name = "EquipmentBackpackColumn"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	body.add_child(right)

	_equipment_capacity_label = Label.new()
	_equipment_capacity_label.add_theme_font_size_override("font_size", 20)
	_equipment_capacity_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.4))
	_equipment_capacity_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_equipment_capacity_label.add_theme_constant_override("outline_size", 3)
	right.add_child(_equipment_capacity_label)

	var bag_scroll := ScrollContainer.new()
	bag_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bag_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(bag_scroll)

	_equipment_backpack_box = VBoxContainer.new()
	_equipment_backpack_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_equipment_backpack_box.add_theme_constant_override("separation", 8)
	bag_scroll.add_child(_equipment_backpack_box)

	## 底部操作提示（返回按钮上方，居中）
	_equipment_hint_label = Label.new()
	_equipment_hint_label.anchor_left = 0.0
	_equipment_hint_label.anchor_right = 1.0
	_equipment_hint_label.anchor_top = 1.0
	_equipment_hint_label.anchor_bottom = 1.0
	_equipment_hint_label.offset_top = -112.0
	_equipment_hint_label.offset_bottom = -80.0
	_equipment_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_equipment_hint_label.add_theme_font_size_override("font_size", 14)
	_equipment_hint_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	_equipment_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_equipment_panel.add_child(_equipment_hint_label)

	## 返回按钮（底部居中）
	_equipment_back_button = Button.new()
	_equipment_back_button.name = "EquipmentBackButton"
	_equipment_back_button.anchor_left = 0.5
	_equipment_back_button.anchor_right = 0.5
	_equipment_back_button.anchor_top = 1.0
	_equipment_back_button.anchor_bottom = 1.0
	_equipment_back_button.offset_left = -120.0
	_equipment_back_button.offset_right = 120.0
	_equipment_back_button.offset_top = -70.0
	_equipment_back_button.offset_bottom = -30.0
	_equipment_back_button.pressed.connect(_on_equipment_back_pressed)
	_equipment_panel.add_child(_equipment_back_button)

## 打开装备/背包子面板：隐藏主菜单按钮、重建列表、刷新导航焦点
func _open_equipment_panel() -> void:
	if _equipment_panel == null:
		return
	$VBoxContainer.visible = false
	_equipment_panel.visible = true
	_refresh_equipment_panel()
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 关闭装备/背包子面板：显示主菜单按钮、重建导航焦点
func _close_equipment_panel() -> void:
	if _equipment_panel == null:
		return
	_equipment_panel.visible = false
	$VBoxContainer.visible = true
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 刷新装备/背包子面板：重建 6 个槽位按钮与背包列表按钮
## 数据源：Player.get_equipment_component()（已装备） / Player.get_backpack()（背包）
func _refresh_equipment_panel() -> void:
	if _equipment_slots_box == null or _equipment_backpack_box == null:
		return
	## 清空旧内容：free() 立即销毁，避免重开面板时出现一帧新旧重叠
	for child in _equipment_slots_box.get_children():
		child.free()
	for child in _equipment_backpack_box.get_children():
		child.free()

	var equipment: Node = null
	var backpack: Node = null
	var player: Node = _get_player()
	if player != null:
		if player.has_method("get_equipment_component"):
			equipment = player.get_equipment_component()
		if player.has_method("get_backpack"):
			backpack = player.get_backpack()

	## 左栏：6 个槽位（已装备可点击卸下；空槽禁用，不参与导航）
	for slot in range(SLOT_TEXTS.size()):
		var data: EquipmentData = null
		if equipment != null:
			data = equipment.get_equipped(slot)
		var btn: Button = _make_equipment_button(_build_slot_button_text(slot, data), data)
		btn.disabled = data == null
		btn.pressed.connect(_on_equip_slot_pressed.bind(slot))
		_equipment_slots_box.add_child(btn)

	## 右栏：背包装备（点击穿戴）
	var count: int = 0
	var cap: int = 0
	if backpack != null:
		var items: Array = backpack.get_items()
		count = items.size()
		cap = int(backpack.capacity)
		for i in range(items.size()):
			var item: EquipmentData = items[i]
			if item == null:
				continue
			var bag_btn: Button = _make_equipment_button(_build_backpack_button_text(item), item)
			bag_btn.pressed.connect(_on_backpack_item_pressed.bind(i))
			_equipment_backpack_box.add_child(bag_btn)
	if count == 0:
		_equipment_backpack_box.add_child(_make_equipment_plain_label(TranslationManager.t("EQUIPMENT_EMPTY")))

	## 容量提示（满时追加警告，提示"卸下会被拒绝"的原因）
	if _equipment_capacity_label != null:
		var cap_text: String = "%s (%d/%d)" % [TranslationManager.t("EQUIPMENT_BACKPACK"), count, cap]
		if backpack != null and backpack.is_full():
			cap_text += "  ·  " + TranslationManager.t("EQUIPMENT_FULL")
		_equipment_capacity_label.text = cap_text

## 创建一个装备条目按钮（左侧图标 + 左对齐多行文本；有装备时按稀有度着色）
## 参数：text - 多行按钮文本；data - 对应装备（为 null 表示空槽，不配图标/配色）
func _make_equipment_button(text: String, data: EquipmentData) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size = Vector2(0.0, 72.0)
	btn.add_theme_font_size_override("font_size", 15)
	btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	btn.add_theme_constant_override("outline_size", 2)
	if data != null:
		btn.icon = IconLibraryLib.get_equipment_icon(data)
		btn.icon_max_width = 48
		btn.add_theme_color_override("font_color", data.get_rarity_color())
	return btn

## 创建一个面板内的普通文本标签（空提示等）
func _make_equipment_plain_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	return label

## 拼接"已装备槽位"按钮文本（多行：槽位名 + 装备名[稀有度] / 词条 / 特效 / 护盾 / 主动技）
## 参数：slot - 槽位；data - 该槽位装备（null 表示空槽）
func _build_slot_button_text(slot: int, data: EquipmentData) -> String:
	var slot_name: String = SLOT_TEXTS[slot] if slot >= 0 and slot < SLOT_TEXTS.size() else "?"
	if data == null:
		return "%s · %s" % [slot_name, TranslationManager.t("EQUIPMENT_EMPTY")]

	var lines: Array[String] = []
	lines.append("%s · %s  [%s]" % [slot_name, data.display_name, data.get_rarity_text()])
	## 基础属性词条（每条一行，展示键名+数值）
	for affix: EquipmentAffix in data.affixes:
		if affix != null:
			lines.append("  " + affix.get_display_text())
	## 子弹特效（显示名 + 层数）
	for effect: BulletEffect in data.bullet_effects:
		if effect == null:
			continue
		var eff_name: String = effect.display_name if effect.display_name != "" else effect.effect_id
		var eff_line: String = "  %s：%s" % [TranslationManager.t("EQUIPMENT_EFFECT"), eff_name]
		if effect.stack_count > 1:
			eff_line += " Lv.%d" % effect.stack_count
		lines.append(eff_line)
	## 护盾蓝图（仅盾牌槽携带）
	if data.shield_data != null:
		lines.append("  %s：%d / %d" % [
			TranslationManager.t("EQUIPMENT_SHIELD_LABEL"),
			int(data.shield_data.max_hp),
			int(data.shield_data.absorb_per_hit),
		])
	## 主动技能（名称 + 冷却）
	if data.has_active_skill():
		lines.append("  %s：%s (CD %.1fs)" % [
			TranslationManager.t("EQUIPMENT_ACTIVE"),
			data.active_skill.display_name,
			float(data.active_skill.cooldown),
		])
	return "\n".join(PackedStringArray(lines))

## 拼接"背包物品"按钮文本（装备名[稀有度] + 内容简报 + 首条词条明细）
## 参数：data - 背包装备实例
func _build_backpack_button_text(data: EquipmentData) -> String:
	if data == null:
		return TranslationManager.t("EQUIPMENT_EMPTY")

	var lines: Array[String] = []
	lines.append("%s  [%s]" % [data.display_name, data.get_rarity_text()])
	## 内容简报（词条数/特效数/是否带护盾/是否带主动技），让玩家一眼分辨价值
	var parts: Array[String] = []
	if data.affixes.size() > 0:
		parts.append("%s×%d" % [TranslationManager.t("STATUS_ATTR"), data.affixes.size()])
	if data.bullet_effects.size() > 0:
		parts.append("%s×%d" % [TranslationManager.t("EQUIPMENT_EFFECT"), data.bullet_effects.size()])
	if data.shield_data != null:
		parts.append(TranslationManager.t("EQUIPMENT_SHIELD_LABEL"))
	if data.has_active_skill():
		parts.append(TranslationManager.t("EQUIPMENT_ACTIVE"))
	if parts.size() > 0:
		lines.append("  " + " · ".join(PackedStringArray(parts)))
	## 首条词条明细（背包内即可看到最关键的一条属性）
	if data.affixes.size() > 0 and data.affixes[0] != null:
		lines.append("  " + data.affixes[0].get_display_text())
	return "\n".join(PackedStringArray(lines))