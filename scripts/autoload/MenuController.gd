## 通用菜单导航控制器
## 遵循 INPUT_ARCHITECTURE_SPEC.md 规范
## 所有输入检测通过 InputManager 接口
## 架构角色：菜单导航组件（非autoload），由各菜单场景实例化挂载，通过activate()/deactivate()
##           随菜单开关启停；全局唯一单例InputManager负责输入过滤，本类只关心焦点移动与确认
## 设计意图：
##   1. 为键盘/手柄提供统一的菜单焦点导航（方向移动焦点、确认/取消），弥补Godot默认焦点系统
##      对摇杆导航与"最近控件"几何寻路支持的不足
##   2. 支持摇杆拨动连发（首次延迟+重复触发），长按可流畅滚动选项
##   3. 输入全部经InputManager网关（上下文/冷却期过滤），菜单激活时自动屏蔽GAMEPLAY动作

class_name MenuNavigator
extends Node

# 导航方向枚举
enum Direction { UP, DOWN, LEFT, RIGHT }

# 摇杆导航配置
## 摇杆方向判定死区（幅值小于此视为未拨动，防止手柄漂移误触发）
@export var joystick_deadzone: float = 0.2
## 首次拨动方向后的持续触发延迟（秒）：长按超过此时间才进入连发，防止轻拨连跳选项
@export var initial_delay: float = 0.4
## 连发重复间隔（秒）：预留调参项，当前_process连发直接复用initial_delay作为间隔
@export var repeat_delay: float = 0.15

# 当前管理的可聚焦控件列表（activate时递归收集，按场景树顺序排列）
var focusable_controls: Array[Control] = []
## 当前焦点在focusable_controls中的索引
var current_index: int = 0
## 导航器是否激活（未激活时_process/_unhandled_input直接返回，零开销待机）
var is_active: bool = false
## 激活时传入的菜单根控件（用于递归扫描可聚焦子控件）
var _parent: Control = null

# 摇杆导航状态
## 当前方向已持续按住的时间（秒），用于首延迟与连发计时
var _joystick_hold_time: float = 0.0
## 上一次触发的方向（-1=无），方向变化时立即移动并重新计时
var _joystick_last_direction: int = -1

# 信号
## 玩家按下确认键时发出：参数为当前焦点控件（菜单可据此做按钮原生行为之外的自定义响应）
signal confirm_pressed(control: Control)
## 玩家按下取消键时发出（菜单据此关闭自身/返回上级界面）
signal cancel_pressed()

## _ready() - 初始化处理模式与默认关闭状态（等待activate()按需开启）
func _ready() -> void:
	## ALWAYS：菜单/面板普遍伴随树暂停（get_tree().paused=true），必须绕过暂停才能响应导航
	process_mode = Node.PROCESS_MODE_ALWAYS
	## 默认关闭处理：未激活时不产生任何轮询/输入开销
	set_process(false)
	set_process_unhandled_input(false)

## 激活导航器：开启输入处理、收集可聚焦控件、注册输入上下文
## 参数：parent - 菜单根控件，其子树中的Button/OptionButton/CheckBox/HSlider将纳入导航
func activate(parent: Control) -> void:
	is_active = true
	_parent = parent
	set_process(true)
	set_process_unhandled_input(true)
	_collect_focusable_controls(parent)
	## 自动把焦点落到第一个可聚焦控件，手柄玩家无需先按键即可开始导航
	if focusable_controls.size() > 0:
		_set_focus(0)
	# 注册 UI 上下文（屏蔽GAMEPLAY动作，仅放行ui_前缀输入）
	InputManager.push_context("PAUSE_MENU")

## 停用导航器：关闭处理、清空控件列表并注销输入上下文（菜单关闭时调用，防输入残留）
func deactivate() -> void:
	is_active = false
	_parent = null
	set_process(false)
	set_process_unhandled_input(false)
	focusable_controls.clear()
	current_index = 0
	_reset_joystick_state()
	# 注销 UI 上下文
	InputManager.pop_context()

## 手动设置焦点到指定索引
func set_focus_index(index: int) -> void:
	if index >= 0 and index < focusable_controls.size():
		_set_focus(index)

## 手动设置焦点到指定控件
func set_focus_control(control: Control) -> void:
	var idx: int = focusable_controls.find(control)
	if idx >= 0:
		_set_focus(idx)

## 获取当前焦点控件
func get_current_control() -> Control:
	if current_index >= 0 and current_index < focusable_controls.size():
		return focusable_controls[current_index]
	return null

## 收集父节点下所有可聚焦的控件
## 每次激活时重新收集（而非缓存），保证菜单动态增删控件（如切换标签页）后列表始终最新
func _collect_focusable_controls(parent: Control) -> void:
	focusable_controls.clear()
	_scan_children(parent)

## 深度优先递归扫描子节点，把可交互控件加入导航列表
func _scan_children(node: Node) -> void:
	for child in node.get_children():
		## 仅纳入四类常用控件；隐藏与禁用的控件跳过（不可操作，导航过去会困惑玩家）
		if child is Button or child is OptionButton or child is CheckBox or child is HSlider:
			var is_disabled: bool = false
			## 用has_method探测而非硬转类型：兼容禁用接口不同的控件子类
			if child.has_method("is_disabled"):
				is_disabled = child.is_disabled()
			if child.visible and not is_disabled:
				focusable_controls.append(child as Control)
		## 无条件继续下钻：容器/嵌套面板内部的控件也要被找到
		_scan_children(child)

## 设置焦点到指定索引（索引越界自动收敛到边界）
## 用Godot原生grab_focus驱动：焦点高亮样式、键盘Enter触发按钮等都复用内置机制
func _set_focus(index: int) -> void:
	if focusable_controls.is_empty():
		return
	current_index = clamp(index, 0, focusable_controls.size() - 1)
	var control: Control = focusable_controls[current_index]
	control.grab_focus()

## 移动焦点：按屏幕几何方向寻找最近控件（而非简单索引±1），贴合视觉布局
func _move_focus(direction: Direction) -> void:
	if focusable_controls.is_empty():
		return

	var old_index: int = current_index
	var current: Control = focusable_controls[current_index]

	# 如果当前焦点在 TabContainer 上，先尝试切换标签
	if current is TabContainer and (direction == Direction.LEFT or direction == Direction.RIGHT):
		if _handle_tab_container_navigation(current, direction):
			return

	match direction:
		Direction.UP:
			current_index = _find_nearest_in_direction(current, Vector2.UP)
		Direction.DOWN:
			current_index = _find_nearest_in_direction(current, Vector2.DOWN)
		Direction.LEFT:
			current_index = _find_nearest_in_direction(current, Vector2.LEFT)
		Direction.RIGHT:
			current_index = _find_nearest_in_direction(current, Vector2.RIGHT)
	
	if current_index != old_index and current_index >= 0:
		_set_focus(current_index)

## 在指定方向上查找最近的控件
## 参数：from - 当前焦点控件，direction - 单位方向向量
## 返回：目标控件索引；找不到同方向控件时回退到顺序切换（见尾部），异常时保持当前索引
func _find_nearest_in_direction(from: Control, direction: Vector2) -> int:
	if focusable_controls.is_empty():
		return 0

	var from_center: Vector2 = _get_control_center(from)
	var best_index: int = -1
	var best_score: float = INF

	for i in range(focusable_controls.size()):
		if i == current_index:
			continue
		var target: Control = focusable_controls[i]
		var target_center: Vector2 = _get_control_center(target)
		var diff: Vector2 = target_center - from_center

		# 检查目标是否在指定方向上
		var dot: float = diff.normalized().dot(direction)
		if dot < 0.3:
			continue

		# 计算距离分数（方向分量权重更高）
		var distance: float = diff.length()
		## 分数=距离/方向对齐度：越正对方向（dot→1）代价越低，斜向控件自然被排后
		var score: float = distance / max(dot, 0.01)

		if score < best_score:
			best_score = score
			best_index = i

	# 如果没找到同方向的，回退到简单的上下索引切换
	if best_index < 0:
		if direction == Vector2.UP or direction == Vector2.DOWN:
			var step: int = 1 if direction == Vector2.DOWN else -1
			return (current_index + step) % focusable_controls.size()
		return current_index

	return best_index

## 获取控件在全局坐标系中的中心点
func _get_control_center(control: Control) -> Vector2:
	if control is Control:
		var global_rect: Rect2 = control.get_global_rect()
		return global_rect.position + global_rect.size / 2.0
	return Vector2.ZERO

## 确认当前焦点控件：按控件类型模拟"点击"（手柄A键等价于鼠标点击按钮）
## HSlider与TabContainer不在此模拟：滑条拖动/标签切换由各自的原生焦点/输入机制处理
func _confirm_current() -> void:
	if focusable_controls.is_empty():
		return
	var control: Control = focusable_controls[current_index]
	if control is Button:
		(control as Button).pressed.emit()
	elif control is OptionButton:
		## 下拉已展开：直接确认当前选中项；未展开：先抓焦点（展开选项列表）由玩家再选
		if (control as OptionButton).popup.visible:
			(control as OptionButton).popup.select(control.selected)
			(control as OptionButton).id_pressed.emit(control.selected)
		else:
			(control as OptionButton).grab_focus()
	elif control is CheckBox:
		## 先翻转勾选态（不自动发信号），再手动补发toggled：保证监听方收到且只收到一次变更
		(control as CheckBox).set_pressed_no_signal(!(control as CheckBox).is_pressed())
		(control as CheckBox).toggled.emit((control as CheckBox).is_pressed())
	elif control is HSlider:
		pass
	elif control is TabContainer:
		pass
	confirm_pressed.emit(control)

## 处理 TabContainer 的左右切换（已到边界标签时返回false，交回通用几何导航移动焦点）
## 返回：true=已消耗本次方向输入（成功切换了标签）
func _handle_tab_container_navigation(control: Control, direction: Direction) -> bool:
	if control is TabContainer:
		var tab = control as TabContainer
		if direction == Direction.LEFT:
			if tab.current_tab > 0:
				tab.current_tab -= 1
				return true
		elif direction == Direction.RIGHT:
			if tab.current_tab < tab.get_tab_count() - 1:
				tab.current_tab += 1
				return true
	return false

## 重置摇杆状态
func _reset_joystick_state() -> void:
	_joystick_hold_time = 0.0
	_joystick_last_direction = -1

## 处理摇杆持续输入（每帧调用）：首次拨动立即响应，持续按住进入连发
func _process(delta: float) -> void:
	if not is_active or focusable_controls.is_empty():
		return

	# 通过 InputManager 获取当前活跃手柄
	if InputManager.current_device != "joypad":
		return

	# 使用 InputManager 公共接口获取导航向量
	var nav_vector: Vector2 = InputManager.get_navigation_vector()
	var joy_x: float = nav_vector.x
	var joy_y: float = nav_vector.y

	var current_direction: Direction = -1

	# 检测方向（InputManager 已处理死区，直接判断方向）
	if abs(joy_y) > joystick_deadzone:
		current_direction = Direction.DOWN if joy_y > 0 else Direction.UP
	elif abs(joy_x) > joystick_deadzone:
		current_direction = Direction.RIGHT if joy_x > 0 else Direction.LEFT

	if current_direction >= 0:
		if current_direction != _joystick_last_direction:
			## 方向刚变化：立即移动一次并清零计时（首次响应零延迟，手感关键）
			_joystick_last_direction = current_direction
			_joystick_hold_time = 0.0
			_move_focus(current_direction)
		else:
			## 同方向持续按住：累计时间，超过首延迟后进入连发（间隔复用initial_delay）
			_joystick_hold_time += delta
			if _joystick_hold_time >= initial_delay:
				_move_focus(current_direction)
				_joystick_hold_time = 0.0
	else:
		## 摇杆回中：清空状态，下次拨动视为全新输入
		_reset_joystick_state()

## 处理单次按键输入（D-pad/方向键/确认/取消）
## 用_unhandled_input而非_input：控件自身的键盘处理优先，避免与控件默认行为双触发
## 每个分支set_input_as_handled：一个按键只驱动一次焦点移动，阻止事件继续冒泡
func _unhandled_input(_event: InputEvent) -> void:
	if not is_active or focusable_controls.is_empty():
		return

	# 使用 InputManager 安全检测输入
	if InputManager.is_action_just_pressed_safe("ui_up"):
		_move_focus(Direction.UP)
		get_viewport().set_input_as_handled()
		
	elif InputManager.is_action_just_pressed_safe("ui_down"):
		_move_focus(Direction.DOWN)
		get_viewport().set_input_as_handled()
		
	elif InputManager.is_action_just_pressed_safe("ui_left"):
		_move_focus(Direction.LEFT)
		get_viewport().set_input_as_handled()
		
	elif InputManager.is_action_just_pressed_safe("ui_right"):
		_move_focus(Direction.RIGHT)
		get_viewport().set_input_as_handled()
	
	elif InputManager.is_action_just_pressed_safe("ui_confirm"):
		_confirm_current()
		get_viewport().set_input_as_handled()
	
	elif InputManager.is_action_just_pressed_safe("ui_cancel"):
		cancel_pressed.emit()
		get_viewport().set_input_as_handled()

## 检测是否有手柄连接（委托InputManager统一判定，避免各处自行查询设备状态）
func _has_connected_joypad() -> bool:
	return InputManager.current_device == "joypad"
