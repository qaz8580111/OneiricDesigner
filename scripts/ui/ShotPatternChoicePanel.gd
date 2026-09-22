## ShotPatternChoicePanel.gd - 弹道构型三选一面板（紧凑底栏样式，不暂停游戏）
## 职责：展示3个随机弹道构型供玩家选择，选定后发出信号
## 设计意图：
##   1. 与技能/护盾三选一完全同款：紧凑底栏、不暂停战斗、水平卡片排列，
##      玩家拾取地面弹道构型书后由"直接替换"改为"自选一种构型"，体验与捡技能宝石一致
##   2. 复用 ChoiceCardStyle 共享样式库：选中态（粗边框+外发光+提亮+放大）与技能/商店/神庙一致
##   3. 数据源为 BulletShotPattern（候选由 UpgradeManager 从 data/bullet/pattern/ 随机抽取）
##   注意：构型不叠层——选定后直接替换玩家当前弹道构型（区别于技能/属性/护盾的叠层语义）
## 输入架构：选择输入全部经 InputManager 网关（复用 LEVEL_UP_CHOICE 上下文，
##           与技能三选一放行规则完全相同：game_choice_prev/next=手柄LT/RT扳机、键盘Q/E，
##           ui_left/right 为备用）；卡片显式 FOCUS_NONE，避免内置焦点导航与手动选中索引双重移动
## 数据流：DropItem.apply(SHOT_PATTERN) → Player.request_shot_pattern_choice
##        → UpgradeManager.open_shot_pattern_choice() → 创建面板 → setup(choices)
##        → 玩家选定 shot_pattern_chosen → UpgradeManager 回调 Player.equip_shot_pattern() 替换弹道 → 销毁面板
extends Control

## ========== 预加载资源 ==========

## 图标加载库（构型书与地面掉落共用同一张"敌人掉落/icon_BC"图标，缺失时回退纯文字卡片）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

## 卡片样式共享工具（与技能三选一/商店/神庙同款：粗边框+外发光+底色提亮的选中态）
const ChoiceCardStyleLib = preload("res://scripts/ui/ChoiceCardStyle.gd")

## ========== 信号定义 ==========

signal shot_pattern_chosen(pattern: Resource)

## 玩家取消本次三选一信号（手柄B/键盘ESC，放弃本次拾取，不替换任何构型）
signal shot_pattern_cancelled()

## ========== 成员变量 ==========

var _choices: Array = []
var _locked: bool = false
var _cards: Array[Button] = []

## 每张卡片的样式集（与 _cards 下标一一对应，来自 ChoiceCardStyleLib.build_card_styles()）
var _card_styles: Array[Dictionary] = []
var _card_container: HBoxContainer = null
var _panel_bg: PanelContainer = null
var _animating: bool = true

## 当前选中卡片索引（鼠标悬停/D-Pad左右共用一个选中态，A键/回车确认）
var _selected_index: int = 0

## ========== 视觉常量 ==========

## 弹道构型主题色（橙黄：区别于技能金、属性/护盾青蓝，一眼可辨）
const ACCENT_COLOR: Color = Color(1.0, 0.6, 0.2)

## 构型书图标 id（对应 IconLibrary.DROP_ICON_MAP 中的 "shot_pattern"）
const DROP_ICON_ID: String = "shot_pattern"

## 选中态切换动画时长（秒，快速响应不拖沓）；选中的具体样式由 ChoiceCardStyle 统一提供
const SELECT_TWEEN_TIME: float = 0.06

## ========== 动画时长常量 ==========

const PANEL_TIME: float = 0.15   ## 面板淡入时长
const CARD_STAGGER: float = 0.04 ## 卡片错峰间隔
const CARD_TIME: float = 0.12    ## 单张卡片入场时长

## ========== 生命周期方法 ==========

## _ready() - 构建紧凑底栏UI（与技能/护盾三选一面板保持完全一致的结构与尺寸）
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

	## 面板背景样式：半透明深色 + 主题色细边框 + 圆角
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.1, 0.92)
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_color = Color(ACCENT_COLOR.r, ACCENT_COLOR.g, ACCENT_COLOR.b, 0.5)
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

	## 标题（弹道构型主题色：橙黄）
	var title: Label = Label.new()
	title.text = "✦ 选择弹道构型 ✦"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", ACCENT_COLOR)
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
	_card_styles.clear()
	## 选中索引置-1：入场动画结束时_set_selection(0)才会真正刷新高亮（同索引会被去重跳过）
	_selected_index = -1
	for i in range(choices.size()):
		var card: Button = _create_card(choices[i], i)
		card.modulate.a = 0.0
		_card_container.add_child(card)
		_cards.append(card)
	_play_enter_animation()

## ========== 内部构建方法 ==========

## 创建单个弹道构型卡片按钮（紧凑样式：[构型]+名称，说明走tooltip）
## 参数：pattern - 弹道构型资源（运行时为 BulletShotPattern）；index - 卡片下标（0起）
func _create_card(pattern: Resource, index: int) -> Button:
	var card: Button = Button.new()
	var pattern_id: String = pattern.pattern_id if "pattern_id" in pattern else ""
	## 显示名优先取构型自身 display_name，未配置时回退 pattern_id（保证卡片永不空白）
	var display_name: String = pattern.display_name if "display_name" in pattern else ""
	if display_name.is_empty():
		display_name = pattern_id
	var desc: String = pattern.description if "description" in pattern else ""
	card.text = "%d.[构型] %s" % [index + 1, display_name]
	## tooltip 展示构型说明（面板只留名称，减小占用面积，与技能三选一一致）
	card.tooltip_text = "%s（弹道构型）\n%s" % [display_name, desc]
	card.custom_minimum_size = Vector2(150, 32)
	## 构型图标：与地面掉落物共用同一张"敌人掉落/icon_BC"图标（按 item_id 走路径契约），
	## 图标缺失时保持纯文字卡片（容错，游戏不因缺图报错）
	var icon_tex: Texture2D = IconLibraryLib.get_drop_icon(DROP_ICON_ID)
	if icon_tex != null:
		card.icon = icon_tex
		## 限制图标宽度22px并等比缩放（原图1024px，直接显示会撑爆卡片）
		card.add_theme_constant_override("icon_max_width", 22)
	## 显式关闭引擎焦点导航：选中态由本面板通过_selected_index统一管理，
	## 否则D-Pad/方向键会同时触发Godot内置焦点移动，导致一次按键跳两格
	card.focus_mode = Control.FOCUS_NONE
	card.add_theme_color_override("font_color", ACCENT_COLOR)
	card.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.5))
	## 卡片样式：由共享工具统一生成（强调色=构型主题色）
	## 这里先套"未选中"组（1px 细边框）；选中态由 _refresh_selection_visual 切换为粗边框+外发光
	var styles: Dictionary = ChoiceCardStyleLib.build_card_styles(ACCENT_COLOR)
	ChoiceCardStyleLib.apply_card_styles(card, styles, false)
	_card_styles.append(styles)
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

## 刷新全部卡片的选中态视觉（选中=粗边框+外发光+底色提亮+放大，其余=1px 细边框常态）
## 具体样式由 ChoiceCardStyle 统一提供，构型/技能/护盾/商店/神庙表现完全一致
func _refresh_selection_visual() -> void:
	for i in range(_cards.size()):
		var card: Button = _cards[i]
		if i >= _card_styles.size():
			continue
		ChoiceCardStyleLib.refresh_card(card, _card_styles[i], i == _selected_index, SELECT_TWEEN_TIME)

## 选择构型（统一入口：鼠标点击/数字键/D-Pad导航后A键确认都走这里）
func _choose(index: int) -> void:
	if _locked or _animating:
		return
	if index < 0 or index >= _choices.size():
		return
	_locked = true
	if AudioManager:
		AudioManager.play("upgrade_confirm", 0.8)
	shot_pattern_chosen.emit(_choices[index])

## 取消本次三选一（手柄B/键盘ESC）
## 与 _choose 共用 _locked 防重入；取消不替换任何构型，由 UpgradeManager 负责关闭面板并放弃本次拾取
func _cancel() -> void:
	if _locked:
		return
	_locked = true
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	shot_pattern_cancelled.emit()

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
