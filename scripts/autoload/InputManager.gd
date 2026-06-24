## InputManager - 输入系统统一网关
## 遵循 INPUT_ARCHITECTURE_SPEC.md 规范
## 所有业务层代码必须通过此单例访问输入，禁止直接调用 Input API
class_name InputManagerClass
extends Node

## 震动类型枚举
enum VibrationType {
	LIGHT,    # 轻微震动（如UI反馈）
	MEDIUM,   # 中等震动（如普通交互）
	HEAVY     # 强烈震动（如重要事件）
}

## 设备变更信号
signal input_device_changed(device: String)

## 当前活跃输入设备（"keyboard" | "joypad" | "touch"）
var current_device: String = "keyboard": get = _get_current_device

## 摇杆死区阈值（规范要求 ≥ 0.15）
const JOYSTICK_DEADZONE: float = 0.2

## 输入屏蔽时间（规范要求 ≥ 0.15s）
const INPUT_COOLDOWN: float = 0.2

## 上下文栈（LIFO）
var _context_stack: Array[String] = ["GAMEPLAY"]

## 输入屏蔽计时器
var _input_cooldown_timer: float = 0.0

## 当前活跃手柄ID
var _active_joypad_id: int = -1

## 缓存的移动向量（供 _process 轮询使用）
var _cached_movement: Vector2 = Vector2.ZERO

## 上一次检测到的设备类型（用于触发信号）
var _last_detected_device: String = "keyboard"


func _ready() -> void:
	# 设置为始终处理，确保暂停状态下也能接收输入
	process_mode = Node.PROCESS_MODE_ALWAYS

	# 监听手柄连接变化
	Input.joy_connection_changed.connect(_on_joy_connection_changed)

	# 初始化手柄检测
	_detect_active_joypad()


func _process(delta: float) -> void:
	# 更新输入屏蔽计时器
	if _input_cooldown_timer > 0.0:
		_input_cooldown_timer -= delta

	# 缓存移动向量（GAMEPLAY 上下文 或 UI 导航上下文都需要）
	if _is_context_active("GAMEPLAY") or _is_context_active("PAUSE_MENU") or _is_context_active("SETTINGS"):
		_cache_movement_input()


func _input(event: InputEvent) -> void:
	# 检测设备类型变化
	_detect_device_from_event(event)


## ==================== 公开接口 ====================

## 获取移动向量（已处理死区+归一化）- 游戏角色移动专用
func get_movement() -> Vector2:
	if not _is_context_active("GAMEPLAY"):
		return Vector2.ZERO
	return _cached_movement

## 获取导航向量（已处理死区+归一化）- UI菜单导航专用
func get_navigation_vector() -> Vector2:
	return _cached_movement


## 安全检测动作按下（自动屏蔽输入冷却期）
func is_action_just_pressed_safe(action: String) -> bool:
	if _input_cooldown_timer > 0.0:
		return false

	# 检查动作是否在当前上下文允许列表中
	if not _is_action_allowed_in_context(action):
		return false

	return Input.is_action_just_pressed(action)


## 安全检测动作持续按住
func is_action_pressed_safe(action: String) -> bool:
	if _input_cooldown_timer > 0.0:
		return false

	if not _is_action_allowed_in_context(action):
		return false

	return Input.is_action_pressed(action)


## 触发分级震动（自动判断设备能力）
func vibrate(type: VibrationType) -> void:
	if _active_joypad_id < 0:
		return  # 无手柄连接，跳过震动

	var strength: float
	var duration: float

	match type:
		VibrationType.LIGHT:
			strength = 0.3
			duration = 0.1
		VibrationType.MEDIUM:
			strength = 0.6
			duration = 0.2
		VibrationType.HEAVY:
			strength = 1.0
			duration = 0.5

	Input.start_joy_vibration(_active_joypad_id, strength, strength, duration)


## 注册输入上下文（用于模式切换）
func push_context(context_name: String) -> void:
	_context_stack.append(context_name)
	# 触发输入屏蔽期
	_input_cooldown_timer = INPUT_COOLDOWN


## 注销输入上下文（恢复上层）
func pop_context() -> void:
	if _context_stack.size() > 1:
		_context_stack.pop_back()
		# 触发输入屏蔽期
		_input_cooldown_timer = INPUT_COOLDOWN


## 获取当前上下文名称
func get_current_context() -> String:
	return _context_stack.back()


## 强制触发输入屏蔽（用于弹窗等场景）
func start_input_cooldown(duration: float = INPUT_COOLDOWN) -> void:
	_input_cooldown_timer = duration


## ==================== 私有实现 ====================

func _get_current_device() -> String:
	return current_device


## 检测当前活跃手柄
func _detect_active_joypad() -> void:
	var joypads: Array = Input.get_connected_joypads()
	if joypads.is_empty():
		_active_joypad_id = -1
		_update_device_type("keyboard")
	else:
		_active_joypad_id = joypads[0]
		_update_device_type("joypad")


## 手柄连接变化回调
func _on_joy_connection_changed(device_id: int, connected: bool) -> void:
	if connected:
		_active_joypad_id = device_id
		_update_device_type("joypad")
	elif device_id == _active_joypad_id:
		# 当前手柄断开，重新检测
		_detect_active_joypad()


## 从输入事件检测设备类型
func _detect_device_from_event(event: InputEvent) -> void:
	var detected: String = ""

	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		detected = "joypad"
	elif event is InputEventKey:
		detected = "keyboard"
	elif event is InputEventMouseButton or event is InputEventScreenTouch:
		detected = "touch"

	if detected != "" and detected != _last_detected_device:
		_last_detected_device = detected
		_update_device_type(detected)


## 更新设备类型并触发信号
func _update_device_type(device: String) -> void:
	if current_device != device:
		current_device = device
		input_device_changed.emit(device)


## 缓存移动输入向量
func _cache_movement_input() -> void:
	var input_x: float = Input.get_axis("game_move_left", "game_move_right")
	var input_y: float = Input.get_axis("game_move_up", "game_move_down")

	# 应用死区过滤
	if abs(input_x) < JOYSTICK_DEADZONE:
		input_x = 0.0
	if abs(input_y) < JOYSTICK_DEADZONE:
		input_y = 0.0

	# 归一化向量（避免斜向移动速度过快）
	var raw_vector: Vector2 = Vector2(input_x, input_y)
	if raw_vector.length() > 1.0:
		raw_vector = raw_vector.normalized()

	_cached_movement = raw_vector


## 检查动作是否在当前上下文允许
func _is_action_allowed_in_context(action: String) -> bool:
	var current_context: String = get_current_context()

	# 定义上下文允许的动作列表
	var allowed_actions: Dictionary = {
		"GAMEPLAY": ["game_move_", "game_interact", "ui_cancel"],
		"PAUSE_MENU": ["ui_", "game_interact"],
		"SETTINGS": ["ui_"],
		"EVENT_POPUP": ["game_confirm", "game_cancel"],
		"DIALOGUE": ["game_advance", "game_skip"],
		"INVENTORY": ["ui_navigate", "ui_confirm", "ui_cancel"],
	}

	var allowed: Array = allowed_actions.get(current_context, [])

	for prefix in allowed:
		if action.begins_with(prefix) or action == prefix:
			return true

	return false


## 检查指定上下文是否在栈顶
func _is_context_active(context_name: String) -> bool:
	return get_current_context() == context_name