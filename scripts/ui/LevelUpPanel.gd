## LevelUpPanel.gd - 升级三选一面板（紧凑底栏样式，不暂停游戏）
## 职责：展示3个随机词条供玩家选择，选定后发出信号
## 设计意图：
##   1. 紧凑底栏：屏幕底部居中的小面板，不覆盖游戏画面，无全屏蒙层
##   2. 不暂停游戏：玩家可边战斗边选择，战斗节奏不被打断
##   3. 水平卡片排列：3张卡片并排，鼠标点击/数字键1/2/3/手柄LT·RT扳机+A选择
##   4. 描述用tooltip展示：卡片只显示名称，鼠标悬停看详情，减小占用面积
## 输入架构：选择输入全部经InputManager网关（LEVEL_UP_CHOICE上下文放行
##           game_choice_prev/next=手柄LT/RT扳机、键盘Q/E，ui_left/right为备用）；
##           卡片显式FOCUS_NONE，避免Godot内置焦点导航与手动选中索引双重移动
## 数据流：UpgradeManager.open_level_up_choice() → 创建面板 → setup(choices)
##        → 玩家选定 upgrade_chosen → UpgradeManager 应用词条、销毁面板
extends Control

## ========== 预加载资源 ==========

const UpgradeDataClass = preload("res://scripts/resources/upgrade/UpgradeData.gd")

## 图标加载库（按"icon_<id>.png"路径契约自动加载，缺失时回退纯文字卡片）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

## ========== 信号定义 ==========

signal upgrade_chosen(upgrade: Resource)

## 玩家取消本次三选一信号（手柄B/键盘ESC，放弃本次拾取，不应用任何词条）
signal upgrade_cancelled()

## ========== 成员变量 ==========

var _choices: Array = []
var _locked: bool = false
var _cards: Array[Button] = []
var _card_container: HBoxContainer = null
var _panel_bg: PanelContainer = null
var _animating: bool = true

## 当前选中卡片索引（鼠标悬停/D-Pad左右共用一个选中态，A键/回车确认）
var _selected_index: int = 0

## ========== 选中态视觉常量 ==========

## 选中卡片的金色提亮（modulate乘法叠加，>1允许，呈现高亮金属感）
const SELECTED_MODULATE: Color = Color(1.25, 1.15, 0.75, 1.0)
## 未选中卡片的正常颜色
const NORMAL_MODULATE: Color = Color.WHITE
## 选中卡片放大倍数（突出当前选项）
const SELECTED_SCALE: Vector2 = Vector2(1.08, 1.08)
## 选中态切换动画时长（秒，快速响应不拖沓）
const SELECT_TWEEN_TIME: float = 0.06

## ========== 动画时长常量 ==========

const PANEL_TIME: float = 0.15   ## 面板淡入时长
const CARD_STAGGER: float = 0.04 ## 卡片错峰间隔
const CARD_TIME: float = 0.12    ## 单张卡片入场时长

## ========== 生命周期方法 ==========

## _ready() - 构建紧凑底栏UI
func _ready() -> void:
	## 根Control全屏（用于捕获键盘事件），但鼠标穿透不拦截游戏点击
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 底部居中面板容器 ----------
	_panel_bg = PanelContainer.new()
	add_child(_panel_bg)
	## 锚定到屏幕底部居中；面板需要位于底部三组图标栏（属性/技能/护盾）上方，
	## 图标栏顶部约距底边 84px，故面板底边距底边 100px、顶边距底边 156px，与图标栏完全不重叠
	_panel_bg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_panel_bg.offset_top = -156.0  ## 面板自身高度约56px（标题+卡片行）
	_panel_bg.offset_bottom = -100.0  ## 距屏幕底边 100px，位于底部图标栏上方

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

## _process() - 手柄LT/RT扳机(或D-Pad/键盘左右)导航与确认（经InputManager网关轮询消费）
## 每帧最多消费一次"刚按下"事件，天然支持连按但不会一帧跳多格
func _process(_delta: float) -> void:
	## 已锁定选择（确认/取消）后不再响应任何输入，防重复触发
	if _locked:
		return
	## B/ESC：取消本次三选一，放弃这次拾取（入场动画期间同样有效）
	if InputManager.is_action_just_pressed_safe("ui_cancel"):
		_cancel()
		return
	## 入场动画期间不响应导航，避免误触
	if _animating or _cards.is_empty():
		return
	## 左移一张：手柄LT扳机 / 键盘Q / 备用D-Pad左·键盘左方向键（边界夹取，不循环）
	if InputManager.is_action_just_pressed_safe("game_choice_prev") \
			or InputManager.is_action_just_pressed_safe("ui_left"):
		_set_selection(_selected_index - 1)
	## 右移一张：手柄RT扳机 / 键盘E / 备用D-Pad右·键盘右方向键
	elif InputManager.is_action_just_pressed_safe("game_choice_next") \
			or InputManager.is_action_just_pressed_safe("ui_right"):
		_set_selection(_selected_index + 1)
	## A键/Space/Enter：确认当前选中卡片
	if InputManager.is_action_just_pressed_safe("ui_confirm"):
		_choose(_selected_index)

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
	## 选中索引置-1：入场动画结束时_set_selection(0)才会真正刷新高亮（同索引会被去重跳过）
	_selected_index = -1
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
	## 已获得过的词条显示当前等级（第二次拾取起即为Lv.2，满级5后不会再出现在候选中）
	var level_tag: String = ""
	var uid: String = upgrade.upgrade_id if "upgrade_id" in upgrade else ""
	if uid != "" and UpgradeManager:
		var cur_stacks: int = UpgradeManager.get_upgrade_stacks(uid)
		if cur_stacks > 0:
			level_tag = "  [Lv.%d→%d]" % [cur_stacks, cur_stacks + 1]
	card.text = "%d.[%s] %s%s" % [index + 1, rarity_names[rarity], display_name, level_tag]
	card.tooltip_text = desc
	card.custom_minimum_size = Vector2(150, 32)
	## 词条图标：按id+稀有度从IconLibrary加载（assets/art/ui/icons/ 路径契约），
	## 图标缺失时保持纯文字卡片（容错，游戏不因缺图报错）
	var icon_tex: Texture2D = IconLibraryLib.get_upgrade_icon(uid, rarity)
	if icon_tex != null:
		card.icon = icon_tex
		## 限制图标宽度22px并等比缩放（原图1024px，直接显示会撑爆卡片）
		card.add_theme_constant_override("icon_max_width", 22)
	## 显式关闭引擎焦点导航：选中态由本面板通过_selected_index统一管理，
	## 否则D-Pad/方向键会同时触发Godot内置焦点移动，导致一次按键跳两格
	card.focus_mode = Control.FOCUS_NONE
	card.add_theme_color_override("font_color", rarity_colors[rarity])
	card.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.5))
	card.pressed.connect(_choose.bind(index))
	## 缩放以卡片中心为原点（选中放大时不偏移）
	card.pivot_offset = card.custom_minimum_size * 0.5
	## 鼠标悬停即同步选中索引：键鼠与手柄共用同一套选中高亮/确认逻辑
	card.mouse_entered.connect(_set_selection.bind(index))
	return card

## 设置当前选中卡片（鼠标悬停与D-Pad导航的唯一入口）
## 参数：index - 目标索引，自动夹取到[0,卡片数)边界，不循环（线性选择符合直觉）
func _set_selection(index: int) -> void:
	if _cards.is_empty():
		return
	var new_index: int = clampi(index, 0, _cards.size() - 1)
	if new_index == _selected_index:
		return
	_selected_index = new_index
	_refresh_selection_visual()

## 刷新全部卡片的选中态视觉（选中=金色提亮+放大，其余=正常）
func _refresh_selection_visual() -> void:
	for i in range(_cards.size()):
		var card: Button = _cards[i]
		var is_selected: bool = i == _selected_index
		var target_modulate: Color = SELECTED_MODULATE if is_selected else NORMAL_MODULATE
		var target_scale: Vector2 = SELECTED_SCALE if is_selected else Vector2.ONE
		## 保留入场淡入的透明度（只改RGB，动画期间alpha由入场tween接管）
		target_modulate.a = card.modulate.a
		## 短tween过渡，选中反馈干脆利落
		var t: Tween = card.create_tween()
		t.set_parallel(true)
		t.tween_property(card, "modulate", target_modulate, SELECT_TWEEN_TIME)
		t.tween_property(card, "scale", target_scale, SELECT_TWEEN_TIME).set_ease(Tween.EASE_OUT)

## 选择词条（统一入口：鼠标点击/数字键/D-Pad导航后A键确认都走这里）
func _choose(index: int) -> void:
	if _locked or _animating:
		return
	if index < 0 or index >= _choices.size():
		return
	_locked = true
	if AudioManager:
		AudioManager.play("upgrade_confirm", 0.8)
	upgrade_chosen.emit(_choices[index])

## 取消本次三选一（手柄B/键盘ESC）
## 与 _choose 共用 _locked 防重入；取消不应用任何词条，由 UpgradeManager 负责关闭面板并放弃本次拾取
func _cancel() -> void:
	if _locked:
		return
	_locked = true
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	upgrade_cancelled.emit()

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

	## 动画结束 → 解锁输入并高亮第一张卡片（手柄玩家无需先按键即可确认默认项）
	var total_time: float = max(0, _cards.size() - 1) * CARD_STAGGER + CARD_TIME
	var unlock_tween: Tween = create_tween()
	unlock_tween.tween_interval(total_time)
	unlock_tween.tween_callback(func() -> void:
		_animating = false
		_set_selection(0)
	)
