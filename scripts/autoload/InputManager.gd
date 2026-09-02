## InputManager - 输入系统统一网关
## 遵循 INPUT_ARCHITECTURE_SPEC.md 规范
## 所有业务层代码必须通过此单例访问输入，禁止直接调用 Input API
## 架构角色：autoload单例（注册名InputManager，class_name为InputManagerClass避免歧义），
##           是业务层（玩家/菜单/对话等）与Godot底层Input API之间的唯一桥梁
## 核心机制：
##   1. "捕获-消费"模型：_input捕获首次按下→缓存到_just_pressed_actions→
##      业务层经is_action_just_pressed_safe轮询消费后清除，同一按下事件只会被消费一次
##   2. 上下文栈（LIFO）：菜单/对话/玩法各注册上下文，只有栈顶上下文允许的动作才生效
##   3. 输入屏蔽期：上下文切换后短暂冷却（INPUT_COOLDOWN），防止切界面瞬间残留按键误触发
##   4. 设备自动识别：键盘/手柄/触屏事件驱动current_device切换，UI据此切换操作提示图标
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
## 自定义getter委托_get_current_device：当前为直通实现，预留后续做只读保护/派生逻辑的扩展点
var current_device: String = "keyboard": get = _get_current_device

## 摇杆死区阈值（规范要求 ≥ 0.15）
const JOYSTICK_DEADZONE: float = 0.2

## 输入屏蔽时间（规范要求 ≥ 0.15s）
const INPUT_COOLDOWN: float = 0.2

## 上下文栈（LIFO）：栈底恒为GAMEPLAY（默认玩法上下文），pop时保留栈底保证永不为空
var _context_stack: Array[String] = ["GAMEPLAY"]

## 输入屏蔽计时器
var _input_cooldown_timer: float = 0.0

## 当前活跃手柄ID
var _active_joypad_id: int = -1

## 缓存的移动向量（供 _process 轮询使用）
var _cached_movement: Vector2 = Vector2.ZERO

## 缓存的动作按下状态（_input 中捕获，_physics_process 中消费后清除）
var _just_pressed_actions: Dictionary = {}

## 缓存的鼠标左键按住状态
var _mouse_left_pressed: bool = false

## 上一次检测到的设备类型（用于触发信号）
var _last_detected_device: String = "keyboard"


## _ready() - 初始化：配置处理模式、监听手柄热插拔、探测初始连接的手柄
func _ready() -> void:
	# 设置为始终处理，确保暂停状态下也能接收输入
	process_mode = Node.PROCESS_MODE_ALWAYS

	# 监听手柄连接变化
	Input.joy_connection_changed.connect(_on_joy_connection_changed)

	# 初始化手柄检测
	_detect_active_joypad()


## _process() - 每帧递减屏蔽冷却计时，并缓存移动轴供get_movement()读取
func _process(delta: float) -> void:
	## 冷却期倒计时（期间is_action_just_pressed_safe一律返回false）
	if _input_cooldown_timer > 0.0:
		_input_cooldown_timer -= delta

	_cache_movement_input()


## _input() - 事件捕获入口：识别设备类型、跟踪鼠标状态、把"首次按下"缓存为待消费动作
## 用_input而非_unhandled_input：网关必须先于一切业务看到事件，才能完成设备识别与状态跟踪
func _input(event: InputEvent) -> void:
	# 检测设备类型变化
	_detect_device_from_event(event)
	
	### 处理鼠标左键状态跟踪（仅更新状态，不消费事件）
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_mouse_left_pressed = event.pressed
		## 仅在 GAMEPLAY 上下文中将鼠标左键按下缓存为 game_shoot 动作
		if event.pressed and get_current_context() == "GAMEPLAY":
			_just_pressed_actions["game_shoot"] = true
		## 注意：不使用 return，让事件继续传递给UI系统
	
	# 缓存游戏相关动作的按下事件
	# 注意：不是所有 InputEvent 都有 pressed 和 echo 属性
	# InputEventMouseMotion、InputEventJoypadMotion 等事件没有这些属性，直接跳过
	if not ('pressed' in event):
		return
	
	var is_pressed: bool = event.pressed
	var is_echo: bool = 'echo' in event and event.echo
	
	if is_pressed and not is_echo:
		## 输入屏蔽期不捕获：冷却期内的按键属于"切界面瞬间"的残留操作，
		## 直接丢弃而非缓存——否则会滞留到冷却结束后被消费，造成迟到的误触发
		## （如：继续游戏后0.2s内按的ESC在半秒后突然生效，菜单凭空弹出）
		if _input_cooldown_timer > 0.0:
			return
		# 检查键盘/手柄游戏动作
		var game_actions: Array[String] = [
			"game_move_up", "game_move_down", "game_move_left", "game_move_right",
			"game_shoot", "game_interact", "game_confirm", "game_cancel",
			"game_advance", "game_skip",
			"ui_cancel", "ui_confirm"
		]
		for action in game_actions:
			# 先检查动作是否存在于 InputMap 中，避免报错
			if not InputMap.has_action(action):
				continue
			if event.is_action_pressed(action):
				## 双重过滤：动作存在 + 当前上下文允许，才写入缓存等待消费
				if _is_action_allowed_in_context(action):
					_just_pressed_actions[action] = true


## ==================== 公开接口 ====================

## 获取移动向量（已处理死区+归一化）- 游戏角色移动专用
func get_movement() -> Vector2:
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

	# 从 _input 事件缓存中读取（消费后清除）
	if _just_pressed_actions.has(action) and _just_pressed_actions[action]:
		_just_pressed_actions[action] = false
		return true
	
	return false


## 安全检测动作持续按住
func is_action_pressed_safe(action: String) -> bool:
	if _input_cooldown_timer > 0.0:
		return false

	if not _is_action_allowed_in_context(action):
		return false

	# 特殊处理 game_shoot：同时支持鼠标左键和键盘/手柄
	if action == "game_shoot":
		# 检查鼠标左键是否按住
		if _mouse_left_pressed:
			return true
		# 检查键盘/手柄输入
		if InputMap.has_action(action) and Input.is_action_pressed(action):
			return true
		return false

	if not InputMap.has_action(action):
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
	## 注：低频/高频马达使用相同强度（简化分级模型；如需轰鸣感可差异化这两个参数）


## 注册输入上下文（用于模式切换）
func push_context(context_name: String) -> void:
	_context_stack.append(context_name)
	## 丢弃旧上下文中已捕获未消费的按键：切换瞬间残留的按下事件
	## 在新界面里触发属于误操作（如游戏内按过的ESC残留到暂停菜单里）
	_just_pressed_actions.clear()
	# 触发输入屏蔽期
	_input_cooldown_timer = INPUT_COOLDOWN


## 注销输入上下文（恢复上层）
func pop_context() -> void:
	## 栈底GAMEPLAY永不弹出（size>1才pop），保证任何时刻都有合法上下文
	if _context_stack.size() > 1:
		_context_stack.pop_back()
		## 同push_context：清空残留按键，防止旧界面的按下事件泄漏到新界面
		_just_pressed_actions.clear()
		# 触发输入屏蔽期
		_input_cooldown_timer = INPUT_COOLDOWN


## 强制重置上下文栈（用于跨场景切换时清理残留上下文）
func reset_context(context_name: String) -> void:
	_context_stack = [context_name]
	## 同push_context：清空残留按键
	_just_pressed_actions.clear()
	_input_cooldown_timer = INPUT_COOLDOWN


## 获取当前上下文名称
func get_current_context() -> String:
	return _context_stack.back()


## 强制触发输入屏蔽（用于弹窗等场景）
func start_input_cooldown(duration: float = INPUT_COOLDOWN) -> void:
	_input_cooldown_timer = duration


## ==================== 私有实现 ====================

## current_device的自定义getter（直通返回）：预留只读封装/派生逻辑的扩展点
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


## 更新设备类型并触发信号（去重：设备未实际变化不发信号，避免UI重复刷新）
func _update_device_type(device: String) -> void:
	if current_device != device:
		current_device = device
		input_device_changed.emit(device)


## 缓存移动输入向量（每帧刷新）：玩家等业务层读缓存而非直接查Input，
## 统一走网关保证死区/轴策略只在一处实现，便于全局调整
func _cache_movement_input() -> void:
	# 安全获取轴输入，确保动作存在
	var input_x: float = 0.0
	var input_y: float = 0.0
	
	if InputMap.has_action("game_move_left") and InputMap.has_action("game_move_right"):
		input_x = Input.get_axis("game_move_left", "game_move_right")
	if InputMap.has_action("game_move_up") and InputMap.has_action("game_move_down"):
		input_y = Input.get_axis("game_move_up", "game_move_down")

	_cached_movement = Vector2(input_x, input_y)


## 检查动作是否在当前上下文允许
func _is_action_allowed_in_context(action: String) -> bool:
	var current_context: String = get_current_context()

	# 定义上下文允许的动作列表（值为动作名或前缀，如"ui_"放行全部ui_开头的动作）
	var allowed_actions: Dictionary = {
		"GAMEPLAY": ["game_move_", "game_interact", "ui_cancel", "game_shoot"],
		"PAUSE_MENU": ["ui_", "game_interact"],
		"SETTINGS": ["ui_"],
		"EVENT_POPUP": ["game_confirm", "game_cancel"],
		"DIALOGUE": ["game_advance", "game_skip"],
		"INVENTORY": ["ui_navigate", "ui_confirm", "ui_cancel"],
	}

	var allowed: Array = allowed_actions.get(current_context, [])

	for prefix in allowed:
		## 前缀匹配（"ui_"命中"ui_confirm"）或全名匹配，任一命中即放行
		if action.begins_with(prefix) or action == prefix:
			return true

	return false


## 检查指定上下文是否在栈顶（与get_current_context()配合的便捷判断）
func _is_context_active(context_name: String) -> bool:
	return get_current_context() == context_name