## PickupConfirmPanel.gd - 专家模式拾取二次确认面板（紧凑底栏样式，不暂停游戏）
## 职责：拾取类别型道具后弹出"是/否"确认，玩家选定后发出信号
## 设计意图：
##   1. 紧凑底栏：屏幕底部居中的小面板，覆盖在底部图标栏上方，无全屏蒙层，不打断战斗节奏
##   2. 不暂停游戏：与三选一一致，玩家可边战斗边确认
##   3. 两个按钮：是（确认→按类别随机升级并消耗道具）/ 否（取消→道具保留原地）
## 输入架构：确认/取消输入全部经InputManager网关（EVENT_POPUP上下文仅放行
##           game_confirm=回车/手柄A、game_cancel=ESC/手柄B，push时自带0.2s防抖）；
##           按钮显式 FOCUS_NONE，避免Godot内置焦点导航与手柄确认双触发
## 数据流：PickUp.pickup（专家模式+类别型道具）→ UpgradeManager.request_expert_pickup
##        → 创建本面板 setup(item_name) → 玩家选是/否 → confirmed/cancelled
##        → UpgradeManager 发放随机升级并销毁道具 / 保留道具解除锁定
extends Control

## ========== 信号定义 ==========

## 玩家选择"是"：确认拾取（UpgradeManager据此发放随机升级并消耗道具）
signal confirmed()

## 玩家选择"否"：取消拾取（UpgradeManager据此保留道具，解除拾取锁定）
signal cancelled()

## ========== 成员变量 ==========

## 是否已锁定选择（确认/取消后置true，防重复触发）
var _locked: bool = false

## 底部居中的面板容器
var _panel_bg: PanelContainer = null

## 拾取物显示名称
var _item_name: String = ""

## 名称标签（setup时刷新文本）
var _name_label: Label = null

## ========== 动画时长常量 ==========

## 面板淡入时长（秒，快速响应不拖沓）
const PANEL_TIME: float = 0.15

## ========== 生命周期方法 ==========

## _ready() - 构建紧凑底栏UI
func _ready() -> void:
	## 根Control全屏（用于承接布局），鼠标穿透不拦截游戏点击（按钮自身仍可点击）
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 底部居中面板容器 ----------
	_panel_bg = PanelContainer.new()
	add_child(_panel_bg)
	## 锚定到屏幕底部居中；面板需要位于底部三组图标栏（属性/技能/护盾）上方，
	## 图标栏顶部约距底边 84px，故面板底边距底边 100px、顶边距底边 186px（高约86px：标题+名称+按钮行）
	_panel_bg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_panel_bg.offset_top = -186.0  ## 面板顶边距屏幕底边 186px（面板自身高度约86px）
	_panel_bg.offset_bottom = -100.0  ## 面板底边距屏幕底边 100px

	## 面板背景样式：半透明深色 + 金色细边框 + 圆角（与三选一同款视觉）
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

	## ---------- 内部垂直布局：标题 + 名称 + 按钮行 ----------
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	_panel_bg.add_child(vbox)

	## 标题
	var title: Label = Label.new()
	title.text = "✦ 确认拾取？ ✦"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vbox.add_child(title)

	## 拾取物名称（居中，白色便于阅读）
	_name_label = Label.new()
	_name_label.text = ""
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.add_theme_color_override("font_color", Color(0.92, 0.92, 0.98))
	vbox.add_child(_name_label)

	## 按钮行（水平居中排列"是 / 否"）
	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	## "是"按钮：确认拾取（手柄A/回车）
	var yes_btn: Button = _create_button("是 (A/回车)", true)
	yes_btn.pressed.connect(_confirm)
	hbox.add_child(yes_btn)

	## "否"按钮：取消拾取（手柄B/ESC）
	var no_btn: Button = _create_button("否 (B/ESC)", false)
	no_btn.pressed.connect(_cancel)
	hbox.add_child(no_btn)

	## 动画初始状态（透明，随后淡入）
	_panel_bg.modulate.a = 0.0

## _process() - 经InputManager网关轮询确认/取消（每帧最多消费一次"刚按下"事件）
func _process(_delta: float) -> void:
	## 已锁定（确认/取消）后不再响应任何输入，防重复触发
	if _locked:
		return
	## 回车/手柄A：确认拾取
	if InputManager.is_action_just_pressed_safe("game_confirm"):
		_confirm()
		return
	## ESC/手柄B：取消拾取（道具保留原地）
	if InputManager.is_action_just_pressed_safe("game_cancel"):
		_cancel()

## ========== 对外接口 ==========

## 初始化面板显示（UpgradeManager创建面板后调用）
## 参数：item_name - 拾取物显示名称（为空时回退"道具"）
func setup(item_name: String) -> void:
	_item_name = item_name if item_name != "" else "道具"
	if _name_label != null:
		_name_label.text = _item_name
	_play_enter_animation()

## ========== 内部构建方法 ==========

## 创建确认/取消按钮（统一尺寸与样式，显式关闭焦点导航）
## 参数：text - 按钮文本；is_primary - 是否主按钮（"是"用金色强调，"否"用灰色）
func _create_button(text: String, is_primary: bool) -> Button:
	var btn: Button = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(110, 30)
	## 显式关闭引擎焦点导航：确认/取消由本面板统一处理，避免焦点系统额外消费方向键/确认键
	btn.focus_mode = Control.FOCUS_NONE
	if is_primary:
		btn.add_theme_color_override("font_color", Color(1.0, 0.9, 0.45))
	else:
		btn.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	return btn

## ========== 选择方法（统一入口） ==========

## 确认拾取（鼠标点击"是" / 手柄A / 回车）
## 参数：无
## 说明：只发信号，具体升级发放与道具销毁由 UpgradeManager 负责
func _confirm() -> void:
	if _locked:
		return
	_locked = true
	if AudioManager:
		AudioManager.play("upgrade_confirm", 0.8)
	confirmed.emit()

## 取消拾取（鼠标点击"否" / 手柄B / ESC）
## 与 _confirm 共用 _locked 防重入；取消不升级、不消耗，道具保留在原地
func _cancel() -> void:
	if _locked:
		return
	_locked = true
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	cancelled.emit()

## ========== 入场动画 ==========

## 简洁入场动画：面板自底部淡入（快速、不拖沓）
func _play_enter_animation() -> void:
	## 等一帧让布局完成
	await get_tree().process_frame
	if not is_instance_valid(_panel_bg):
		return

	## 面板淡入
	var panel_tween: Tween = create_tween()
	panel_tween.tween_property(_panel_bg, "modulate:a", 1.0, PANEL_TIME)
