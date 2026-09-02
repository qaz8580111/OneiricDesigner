## LevelUpPanel.gd - 升级三选一面板（紧凑底栏样式，不暂停游戏）
## 职责：展示3个随机词条供玩家选择，选定后发出信号
## 设计意图：
##   1. 紧凑底栏：屏幕底部居中的小面板，不覆盖游戏画面，无全屏蒙层
##   2. 不暂停游戏：玩家可边战斗边选择，战斗节奏不被打断
##   3. 水平卡片排列：3张卡片并排，鼠标点击或数字键1/2/3选择
##   4. 描述用tooltip展示：卡片只显示名称，鼠标悬停看详情，减小占用面积
## 数据流：UpgradeManager.open_level_up_choice() → 创建面板 → setup(choices)
##        → 玩家选定 upgrade_chosen → UpgradeManager 应用词条、销毁面板
extends Control

## ========== 预加载资源 ==========

const UpgradeDataClass = preload("res://scripts/resources/upgrade/UpgradeData.gd")

## ========== 信号定义 ==========

signal upgrade_chosen(upgrade: Resource)

## ========== 成员变量 ==========

var _choices: Array = []
var _locked: bool = false
var _cards: Array[Button] = []
var _card_container: HBoxContainer = null
var _panel_bg: PanelContainer = null
var _animating: bool = true

## ========== 动画时长常量 ==========

const PANEL_TIME: float = 0.15   ## 面板淡入时长
const CARD_STAGGER: float = 0.04 ## 卡片错峰间隔
const CARD_TIME: float = 0.12    ## 单张卡片入场时长
const HOVER_TIME: float = 0.06   ## 悬停放大时长

## ========== 生命周期方法 ==========

## _ready() - 构建紧凑底栏UI
func _ready() -> void:
	## 根Control全屏（用于捕获键盘事件），但鼠标穿透不拦截游戏点击
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 底部居中面板容器 ----------
	_panel_bg = PanelContainer.new()
	add_child(_panel_bg)
	## 锚定到屏幕底部居中，底部留出 56px 安全区（底部状态栏高度28px + 上下边距28px）
	## 避免与 GameHUD 底部常驻状态栏重叠，同时保证面板完整显示不贴边
	_panel_bg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_panel_bg.offset_top = -112.0  ## 面板自身高度约54px
	_panel_bg.offset_bottom = -58.0  ## 距屏幕底边 58px（状态栏高28px+额外间距30px）

	## 面板背景样式：半透明深色 + 金色细边框 + 圆角
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.1, 0.92)
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_color = Color(1.0, 0.85, 0.3, 0.5)
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	_panel_bg.add_theme_stylebox_override("panel", sb)

	## ---------- 内部垂直布局：标题 + 卡片行 ----------
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	_panel_bg.add_child(vbox)

	## 标题
	var title: Label = Label.new()
	title.text = "✦ 选择强化 ✦"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vbox.add_child(title)

	## 卡片水平容器
	_card_container = HBoxContainer.new()
	_card_container.add_theme_constant_override("separation", 6)
	_card_container.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(_card_container)

	## 动画初始状态
	_panel_bg.modulate.a = 0.0

## _unhandled_input() - 处理数字键1/2/3快捷选择
func _unhandled_input(event: InputEvent) -> void:
	if _animating or _locked:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var index: int = -1
	match event.physical_keycode:
		KEY_1: index = 0
		KEY_2: index = 1
		KEY_3: index = 2
	if index >= 0 and index < _choices.size():
		_choose(index)

## ========== 对外接口 ==========

## 初始化面板显示（UpgradeManager创建面板后调用）
func setup(choices: Array) -> void:
	_choices = choices
	_cards.clear()
	for i in range(choices.size()):
		var card: Button = _create_card(choices[i], i)
		card.modulate.a = 0.0
		_card_container.add_child(card)
		_cards.append(card)
	_play_enter_animation()

## ========== 内部构建方法 ==========

## 创建单个词条卡片按钮（紧凑样式：名称+稀有度，描述走tooltip）
func _create_card(upgrade: Resource, index: int) -> Button:
	var card: Button = Button.new()
	var rarity_names: Array = ["普通", "稀有", "史诗"]
	var rarity_colors: Array = [
		Color(0.85, 0.85, 0.85),
		Color(0.35, 0.65, 1.0),
		Color(0.8, 0.4, 1.0),
	]
	var rarity: int = upgrade.rarity if "rarity" in upgrade else 0
	var display_name: String = upgrade.display_name if "display_name" in upgrade else "???"
	var desc: String = upgrade.description if "description" in upgrade else ""
	card.text = "%d.[%s] %s" % [index + 1, rarity_names[rarity], display_name]
	card.tooltip_text = desc
	card.custom_minimum_size = Vector2(150, 32)
	card.add_theme_color_override("font_color", rarity_colors[rarity])
	card.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.5))
	card.pressed.connect(_choose.bind(index))
	## 悬停放大反馈
	card.mouse_entered.connect(func() -> void:
		card.pivot_offset = card.size * 0.5
		var t: Tween = card.create_tween()
		t.tween_property(card, "scale", Vector2(1.05, 1.05), HOVER_TIME).set_ease(Tween.EASE_OUT)
	)
	card.mouse_exited.connect(func() -> void:
		var t: Tween = card.create_tween()
		t.tween_property(card, "scale", Vector2.ONE, HOVER_TIME)
	)
	return card

## 选择词条（统一入口：鼠标点击与键盘快捷键都走这里）
func _choose(index: int) -> void:
	if _locked or _animating:
		return
	if index < 0 or index >= _choices.size():
		return
	_locked = true
	if AudioManager:
		AudioManager.play("upgrade_confirm", 0.8)
	upgrade_chosen.emit(_choices[index])

## ========== 入场动画 ==========

## 简洁入场动画：面板淡入 + 卡片错峰淡入（快速、不拖沓）
func _play_enter_animation() -> void:
	## 等一帧让布局完成
	await get_tree().process_frame
	if not is_instance_valid(_panel_bg):
		return

	## 面板淡入
	var panel_tween: Tween = create_tween()
	panel_tween.tween_property(_panel_bg, "modulate:a", 1.0, PANEL_TIME)

	## 卡片错峰淡入
	for i in range(_cards.size()):
		var card: Button = _cards[i]
		var ct: Tween = create_tween()
		ct.tween_interval(i * CARD_STAGGER)
		ct.tween_property(card, "modulate:a", 1.0, CARD_TIME)

	## 动画结束 → 解锁输入
	var total_time: float = max(0, _cards.size() - 1) * CARD_STAGGER + CARD_TIME
	var unlock_tween: Tween = create_tween()
	unlock_tween.tween_interval(total_time)
	unlock_tween.tween_callback(func() -> void: _animating = false)
