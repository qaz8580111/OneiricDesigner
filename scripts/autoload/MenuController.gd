## 通用菜单导航控制器
## 遵循 INPUT_ARCHITECTURE_SPEC.md 规范
## 所有输入检测通过 InputManager 接口

class_name MenuNavigator
extends Node

# 导航方向枚举
enum Direction { UP, DOWN, LEFT, RIGHT }

# 摇杆导航配置
@export var joystick_deadzone: float = 0.2
@export var initial_delay: float = 0.4
@export var repeat_delay: float = 0.15

# 当前管理的可聚焦控件列表
var focusable_controls: Array[Control] = []
var current_index: int = 0
var is_active: bool = false
var _parent: Control = null

# 摇杆导航状态
var _joystick_hold_time: float = 0.0
var _joystick_last_direction: int = -1

# 信号
signal confirm_pressed(control: Control)
signal cancel_pressed()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	set_process_unhandled_input(false)

## 激活导航器
func activate(parent: Control) -> void:
	is_active = true
	_parent = parent
	set_process(true)
	set_process_unhandled_input(true)
	_collect_focusable_controls(parent)
	if focusable_controls.size() > 0:
		_set_focus(0)
	# 注册 UI 上下文
	InputManager.push_context("PAUSE_MENU")

## 停用导航器
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
func _collect_focusable_controls(parent: Control) -> void:
	focusable_controls.clear()
	_scan_children(parent)

func _scan_children(node: Node) -> void:
	for child in node.get_children():
		if child is Button or child is OptionButton or child is CheckBox or child is HSlider:
			if child.visible and not child.disabled:
				focusable_controls.append(child as Control)
		_scan_children(child)

## 设置焦点到指定索引
func _set_focus(index: int) -> void:
	if focusable_controls.is_empty():
		return
	current_index = clamp(index, 0, focusable_controls.size() - 1)
	var control: Control = focusable_controls[current_index]
	control.grab_focus()

## 移动焦点
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

## 确认当前焦点控件
func _confirm_current() -> void:
	if focusable_controls.is_empty():
		return
	var control: Control = focusable_controls[current_index]
	if control is Button:
		(control as Button).pressed.emit()
	elif control is OptionButton:
		if (control as OptionButton).popup.visible:
			(control as OptionButton).popup.select(control.selected)
			(control as OptionButton).id_pressed.emit(control.selected)
		else:
			(control as OptionButton).grab_focus()
	elif control is CheckBox:
		(control as CheckBox).set_pressed_no_signal(!(control as CheckBox).is_pressed())
		(control as CheckBox).toggled.emit((control as CheckBox).is_pressed())
	elif control is HSlider:
		pass
	elif control is TabContainer:
		pass
	confirm_pressed.emit(control)

## 处理 TabContainer 的左右切换
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

## 处理摇杆持续输入（每帧调用）
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
			_joystick_last_direction = current_direction
			_joystick_hold_time = 0.0
			_move_focus(current_direction)
		else:
			_joystick_hold_time += delta
			if _joystick_hold_time >= initial_delay:
				_move_focus(current_direction)
				_joystick_hold_time = 0.0
	else:
		_reset_joystick_state()

## 处理单次按键输入
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

## 检测是否有手柄连接
func _has_connected_joypad() -> bool:
	return InputManager.current_device == "joypad"
