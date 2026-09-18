## PauseMenu.gd - 暂停菜单逻辑脚本
## 职责：管理游戏暂停界面，处理继续游戏、打开设置、返回主菜单三种操作
## 继承：Control（UI控件基类，作为暂停菜单的根节点）
## 数据流：按钮点击 / 导航器cancel_pressed(ESC) → 信号(resume_game/open_settings/quit_to_menu) → Main.gd 监听后执行
## 注意：游戏中按ESC打开暂停菜单由 Main.gd 统一处理，且会被 UpgradeManager.is_choosing 屏蔽
##      （升级三选一期间禁止再叠加暂停菜单）；暂停菜单打开时按ESC走导航器取消 = 继续游戏
extends Control

## 图标加载库（状态面板显示属性/技能/护盾图标用）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

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

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 构建状态子面板（先于文本刷新，保证标题/返回按钮引用就绪）
	_build_status_panel()
	## 更新界面文本（支持多语言）
	_update_text()
	
	## 连接按钮信号到处理方法
	resume_button.pressed.connect(_on_resume_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	status_button.pressed.connect(_on_status_button_pressed)
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
	quit_button.text = TranslationManager.t("BUTTON_QUIT_TO_MENU")
	## 状态子面板标题与返回按钮（构建后存在才更新，避免_ready早期空引用）
	if _status_title_label != null:
		_status_title_label.text = TranslationManager.t("STATUS_TITLE")
	if _status_back_button != null:
		_status_back_button.text = TranslationManager.t("BUTTON_BACK")

## ========== 信号回调方法 ==========

## 语言变化回调：重新更新界面文本
func _on_language_changed(_lang: String) -> void:
	_update_text()

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

## 导航器取消分发：状态子面板打开时先返回主菜单，否则（暂停主菜单）继续游戏
func _on_navigator_cancel() -> void:
	if _status_panel != null and _status_panel.visible:
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

## 刷新状态列表：清空后按"属性/技能/护盾"三组逐行填充
func _refresh_status_list() -> void:
	if _status_rows == null:
		return
	## 清空旧行：用 free() 立即销毁而非 queue_free()，避免本帧内旧行残留导致
	## 重新打开状态面板时出现一帧"新旧行重叠"的视觉闪烁
	for child in _status_rows.get_children():
		child.free()

	var acquired: Array = []
	if UpgradeManager:
		acquired = UpgradeManager.get_acquired_upgrades()

	## 属性组（is_effect=false 的纯数值词条）
	_add_status_header(TranslationManager.t("STATUS_ATTR"))
	var has_attr: bool = false
	for info in acquired:
		if bool(info.get("is_effect", false)):
			continue
		_add_upgrade_row(info)
		has_attr = true
	if not has_attr:
		_add_status_empty()

	## 技能组（is_effect=true 的子弹特效词条）
	_add_status_header(TranslationManager.t("STATUS_SKILL"))
	var has_skill: bool = false
	for info in acquired:
		if not bool(info.get("is_effect", false)):
			continue
		_add_upgrade_row(info)
		has_skill = true
	if not has_skill:
		_add_status_empty()

	## 护盾组（当前装备护盾）
	_add_status_header(TranslationManager.t("STATUS_SHIELD"))
	_add_shield_row()

## 添加分组标题（属性/技能/护盾）
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

## 添加一条词条行（属性或技能）
func _add_upgrade_row(info: Dictionary) -> void:
	var rarity: int = int(info.get("rarity", 0))
	var icon_tex: Texture2D = IconLibraryLib.get_upgrade_icon(String(info.get("id", "")), rarity)
	var level_text: String = "Lv.%d/%d" % [int(info.get("stacks", 1)), int(info.get("max_stacks", 5))]
	var desc: String = String(info.get("description", ""))
	_add_status_row(icon_tex, _rarity_color(rarity), String(info.get("name", "")), level_text, desc)

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

## 稀有度对应的图标底色（与三选一/底部图标栏配色一致）
func _rarity_color(rarity: int) -> Color:
	match rarity:
		1:
			return Color(0.4, 0.7, 1.0)    ## 稀有：蓝色
		2:
			return Color(0.8, 0.4, 1.0)    ## 史诗：紫色
		_:
			return Color(0.85, 0.85, 0.9)  ## 普通：浅灰白