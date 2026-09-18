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

## 缓存的右摇杆瞄准向量（手柄双摇杆射击专用，已做径向死区过滤）
var _cached_aim: Vector2 = Vector2.ZERO

## 缓存的动作按下状态（_input 中捕获，_physics_process 中消费后清除）
var _just_pressed_actions: Dictionary = {}

## 扳机轴(LT=axis4/RT=axis5)当前扣下状态：action→bool
## InputEventJoypadMotion没有pressed属性，通用按键分支无法捕获，
## 必须自行维护轴值越阈(0.5)的边沿检测，否则升级面板收不到LT/RT
var _trigger_axis_active: Dictionary = {}

## 扳机扣下判定阈值（与game_choice_prev/next的InputMap deadzone一致）
const TRIGGER_PRESSED_THRESHOLD: float = 0.5

## 扳机两次边沿触发之间的最小间隔（秒）
## 修复：手柄LT/RT是模拟轴，半扣时轴值会在0.5阈值附近抖动，产生多次"松开→扣下"边沿，
##       导致升级三选一/神庙/商店的左右切换"稍微按一下就连续滑到最前/最后"。
##       加冷却后，同一扳机在一次扣下后的0.2秒内不再重复触发，抖动被吞掉。
const TRIGGER_EDGE_COOLDOWN: float = 0.2

## 扳机边沿冷却计时器：action → 剩余冷却秒数（>0 表示该扳机刚触发过，忽略后续边沿）
var _trigger_edge_cooldown: Dictionary = {}

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

	## 扳机边沿冷却倒计时（防LT/RT半扣抖动连滑）
	if not _trigger_edge_cooldown.is_empty():
		for action in _trigger_edge_cooldown.keys():
			_trigger_edge_cooldown[action] = float(_trigger_edge_cooldown[action]) - delta
			if float(_trigger_edge_cooldown[action]) <= 0.0:
				_trigger_edge_cooldown.erase(action)

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
		## 铁律：鼠标左键在 project.godot 中只绑定 game_shoot，绝不能再绑 game_interact——
		## 否则战斗中开枪会同时触发拾取，路过技能书/护盾时被"自动捡走"（玩家没按E却拾取）。
		## 手动拾取的 game_interact 只用 E/空格/Enter/手柄A（见 project.godot 绑定）
		if event.pressed and get_current_context() == "GAMEPLAY":
			_just_pressed_actions["game_shoot"] = true
		## 注意：不使用 return，让事件继续传递给UI系统
	
	# 缓存游戏相关动作的按下事件
	# 注意：不是所有 InputEvent 都有 pressed 和 echo 属性
	# InputEventMouseMotion 没有这些属性，直接跳过；
	# InputEventJoypadMotion 同样没有 pressed，但LT/RT扳机轴需要单独做越阈边沿检测
	if event is InputEventJoypadMotion:
		_handle_trigger_motion(event)
		return
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
			"game_advance", "game_skip", "game_pause",
			# 升级三选一切换：本分支只收键盘Q/E；手柄LT/RT是轴事件无pressed，
			# 由_handle_trigger_motion单独做越阈边沿检测
			"game_choice_prev", "game_choice_next",
			# UI方向动作也统一捕获：D-Pad/方向键在菜单与选择面板中经网关消费，
			# 避免业务层直接读 Input（修复此前 ui_up/down/left/right 未入缓存导致
			# MenuNavigator 与选择面板收不到 D-Pad 按下事件的问题）
			"ui_cancel", "ui_confirm",
			"ui_up", "ui_down", "ui_left", "ui_right"
		]
		for action in game_actions:
			# 先检查动作是否存在于 InputMap 中，避免报错
			if not InputMap.has_action(action):
				continue
			if event.is_action_pressed(action):
				## 双重过滤：动作存在 + 当前上下文允许，才写入缓存等待消费
				if _is_action_allowed_in_context(action):
					_just_pressed_actions[action] = true

## 处理手柄轴事件中的LT/RT扳机（升级三选一切换用）
## 背景：InputEventJoypadMotion无pressed属性，走不了通用按键缓存；
##       这里按轴值是否越过TRIGGER_PRESSED_THRESHOLD自行做"按下/松开"边沿检测，
##       只在松开→扣下的跳变沿写入一次just_pressed缓存（与按键语义一致）
## 参数：event - 手柄轴事件（axis 4=LT / axis 5=RT）
func _handle_trigger_motion(event: InputEventJoypadMotion) -> void:
	## 输入屏蔽期同样丢弃扳机事件（防止面板push瞬间的残留扣动误选）
	if _input_cooldown_timer > 0.0:
		return
	for action in ["game_choice_prev", "game_choice_next"]:
		if not InputMap.has_action(action):
			continue
		## is_action判定轴方向归属（axis4+正向→prev，axis5+正向→next），
		## 再用轴值阈值判定扣下状态
		var now_active: bool = event.is_action(action) \
			and event.axis_value >= TRIGGER_PRESSED_THRESHOLD
		var was_active: bool = bool(_trigger_axis_active.get(action, false))
		## 状态无论是否被上下文放行都要更新，避免上下文切换后边沿状态错乱
		_trigger_axis_active[action] = now_active
		## 仅在"松开→扣下"跳变沿、且当前上下文允许、且不在边沿冷却期内时缓存一次
		if now_active and not was_active and _is_action_allowed_in_context(action):
			if float(_trigger_edge_cooldown.get(action, 0.0)) <= 0.0:
				_just_pressed_actions[action] = true
				_trigger_edge_cooldown[action] = TRIGGER_EDGE_COOLDOWN


## ==================== 公开接口 ====================

## 获取移动向量（已处理死区+归一化）- 游戏角色移动专用
func get_movement() -> Vector2:
	return _cached_movement

## 获取导航向量（已处理死区+归一化）- UI菜单导航专用
func get_navigation_vector() -> Vector2:
	return _cached_movement


## 获取右摇杆瞄准向量（已做径向死区过滤，未归一时保留摇杆倾斜强度）
## 仅手柄有输入来源；键鼠瞄准走鼠标位置，调用方应先判断 current_device
## 返回：摇杆偏转向量；回中时为 Vector2.ZERO
func get_aim_vector() -> Vector2:
	return _cached_aim


## 右摇杆当前是否处于有效偏转（超出死区）- 手动射击模式下"拨摇杆即开火"
func is_aim_active() -> bool:
	return _cached_aim.length() > 0.0


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


## 缓存移动/瞄准输入向量（每帧刷新）：玩家等业务层读缓存而非直接查Input，
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

	# ---------- 右摇杆瞄准轴（手柄独占；动作缺失时视为零输入） ----------
	var aim_x: float = 0.0
	var aim_y: float = 0.0
	if InputMap.has_action("game_aim_left") and InputMap.has_action("game_aim_right"):
		aim_x = Input.get_axis("game_aim_left", "game_aim_right")
	if InputMap.has_action("game_aim_up") and InputMap.has_action("game_aim_down"):
		aim_y = Input.get_axis("game_aim_up", "game_aim_down")
	# 径向死区二次过滤：InputMap 的逐轴死区只能过滤单轴，斜向推摇杆时
	# 合成向量仍可能残留漂移，按模长再过滤一次保证回中干净
	var aim_vec: Vector2 = Vector2(aim_x, aim_y)
	_cached_aim = aim_vec if aim_vec.length() >= JOYSTICK_DEADZONE else Vector2.ZERO


## 检查动作是否在当前上下文允许
func _is_action_allowed_in_context(action: String) -> bool:
	var current_context: String = get_current_context()

	# 定义上下文允许的动作列表（值为动作名或前缀，如"ui_"放行全部ui_开头的动作）
	var allowed_actions: Dictionary = {
		# game_pause：手柄START/键盘Pause呼出暂停；瞄准为网关内轮询轴，game_aim_仅作文档化标注
		"GAMEPLAY": ["game_move_", "game_interact", "ui_cancel", "game_shoot", "game_pause", "game_aim_"],
		# game_pause：暂停菜单中再按START恢复游戏（ui_cancel=B/ESC由菜单导航器处理恢复）
		# game_choice_prev/next：手柄LT/RT扳机（设置页切换标签页）；键盘Q/E同动作
		"PAUSE_MENU": ["ui_", "game_interact", "game_pause", "game_choice_prev", "game_choice_next"],
		# game_choice_prev/next：死亡结算面板用LT/RT（键盘Q/E同动作）在两个按钮间切换
		"SETTINGS": ["ui_", "game_choice_prev", "game_choice_next"],
		"EVENT_POPUP": ["game_confirm", "game_cancel"],
		"DIALOGUE": ["game_advance", "game_skip"],
		"INVENTORY": ["ui_navigate", "ui_confirm", "ui_cancel"],
		# 升级三选一：不暂停战斗，移动/射击/交互全部保留；
		# 卡片左右切换优先用手柄LT/RT扳机(game_choice_prev/next)，键盘Q/E同义；
		# D-Pad/方向键(ui_left/ui_right)保留为备用，确认用A/Space
		"LEVEL_UP_CHOICE": [
			"game_move_", "game_shoot", "game_interact", "game_aim_",
			"game_choice_prev", "game_choice_next",
			"ui_up", "ui_down", "ui_left", "ui_right", "ui_confirm", "game_confirm", "ui_cancel"
		],
		"TEMPLE_CHOICE": [
			"game_move_", "game_shoot", "game_interact", "game_aim_",
			# 神庙选项左右选择与升级三选一同款：优先手柄LT/RT扳机(game_choice_prev/next)、键盘Q/E同义，
			# D-Pad/方向键(ui_left/ui_right)保留为备用
			"game_choice_prev", "game_choice_next",
			"ui_up", "ui_down", "ui_left", "ui_right", "ui_confirm", "game_confirm", "ui_cancel"
		],
		# 中央商店：进入后游戏暂停，移动/射击自然停止，无需放行移动/交互键；
		# 商品左右选择与升级三选一同款：LT/RT扳机(game_choice_prev/next)、键盘Q/E，
		# D-Pad/方向键(ui_left/ui_right)备用；确认购买用A/Space(game_confirm/ui_confirm)，ESC关闭(ui_cancel)
		"SHOP_CHOICE": [
			"game_choice_prev", "game_choice_next",
			"ui_up", "ui_down", "ui_left", "ui_right", "ui_confirm", "game_confirm", "ui_cancel"
		],
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