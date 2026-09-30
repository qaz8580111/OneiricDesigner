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
## 连发重复间隔（秒）：焦点在滑条/下拉框上做"就地调节"时使用的连发间隔。
## 就地调值需要快速扫过量程（音量0~100每档5，慢间隔会让玩家等到不耐烦），
## 故此处用远小于 initial_delay 的间隔；普通焦点移动仍用 initial_delay，避免选项跳得过快
@export var repeat_delay: float = 0.15
## 无焦点可移动时，上下键直接滚动可见滚动容器的步长（像素）
## 用于"纯文本页"（无可聚焦控件但内容超屏），如暂停菜单的状态页
@export var scroll_step: int = 120

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
## 参数：parent  - 菜单根控件，其子树中的Button/OptionButton/CheckBox/HSlider将纳入导航
##       context - 注册的输入上下文名；默认 "PAUSE_MENU"（暂停菜单/主菜单），
##                 设置界面应传 "SETTINGS"（该上下文不放行 game_pause，
##                 避免在设置页按开始键误触发暂停逻辑）
func activate(parent: Control, context: String = "PAUSE_MENU") -> void:
	is_active = true
	_parent = parent
	set_process(true)
	set_process_unhandled_input(true)
	_collect_focusable_controls(parent)
	## 自动把焦点落到第一个可聚焦控件，手柄玩家无需先按键即可开始导航
	if focusable_controls.size() > 0:
		_set_focus(0)
	## 监听视口焦点变化：鼠标点击/其他逻辑抢走焦点时反向同步 current_index，
	## 否则"就地调节"（左右键调值）会作用到与视觉焦点不一致的控件上
	if not get_viewport().gui_focus_changed.is_connected(_on_viewport_gui_focus_changed):
		get_viewport().gui_focus_changed.connect(_on_viewport_gui_focus_changed)
	# 注册 UI 上下文（屏蔽GAMEPLAY动作，仅放行ui_前缀输入）
	InputManager.push_context(context)

## 停用导航器：关闭处理、清空控件列表并注销输入上下文（菜单关闭时调用，防输入残留）
func deactivate() -> void:
	is_active = false
	_parent = null
	set_process(false)
	set_process_unhandled_input(false)
	focusable_controls.clear()
	current_index = 0
	_reset_joystick_state()
	## 断开视口焦点监听（避免菜单关闭后仍被其他界面的焦点变化回调到）
	var vp: Viewport = get_viewport()
	if vp != null and vp.gui_focus_changed.is_connected(_on_viewport_gui_focus_changed):
		vp.gui_focus_changed.disconnect(_on_viewport_gui_focus_changed)
	# 注销 UI 上下文
	InputManager.pop_context()

## 手动设置焦点到指定索引
func set_focus_index(index: int) -> void:
	if index >= 0 and index < focusable_controls.size():
		_set_focus(index)

## 刷新可聚焦控件列表并把焦点重置到首项（TabContainer 切换标签页后调用）
## 背景：控件列表仅在 activate() 时收集一次；切换标签页后旧页控件被隐藏但仍留在列表中，
##       新页控件可见却不在列表里——不刷新会导致焦点落在隐藏控件上（"选中"了看不见的东西）
## 数据流：设置页 LT/RT（或鼠标点击）切换 Tab → tab_changed → 本方法重新收集 → 焦点回首控件
func refresh_controls() -> void:
	if _parent == null:
		return
	_collect_focusable_controls(_parent)
	if focusable_controls.size() > 0:
		_set_focus(0)

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
			## 必须用is_visible_in_tree()（树内有效可见）而非visible（自身标志）：
			## TabContainer仅隐藏非当前页的"页容器"，页内控件自身visible仍为true——
			## 用visible会把隐藏页的控件也收进导航，切页后焦点落到看不见的控件上
			if child.is_visible_in_tree() and not is_disabled:
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
	## 滚动跟随：让新焦点自动滚入所在滚动容器的可视区（否则列表超屏时"选中项"跑到屏幕外）
	## 延后一帧执行：切页/列表重建当帧控件尺寸尚未结算，立即滚动会按旧尺寸算错偏移
	_scroll_control_into_view.call_deferred(control)

## 把控件滚动到其最近 ScrollContainer 祖先的可视范围内（无滚动祖先时静默返回）
func _scroll_control_into_view(control: Control) -> void:
	if not is_instance_valid(control):
		return
	var scroll: ScrollContainer = _find_scroll_ancestor(control)
	if scroll != null:
		scroll.ensure_control_visible(control)

## 从控件向上回溯，查找最近的 ScrollContainer 祖先（没有则返回 null）
func _find_scroll_ancestor(control: Control) -> ScrollContainer:
	var node: Node = control.get_parent()
	while node != null:
		if node is ScrollContainer:
			return node as ScrollContainer
		node = node.get_parent()
	return null

## 滚动当前可见的滚动容器（用于"有大段内容但没有任何可聚焦控件"的页面）
## 场景：暂停菜单"状态"页整页为纯文本 Label，导航列表里只有面板外的返回按钮，
##       上下键无焦点可移动，此时改为直接滚动该页的 ScrollContainer，保证内容可查阅
## 返回：true=本次输入已被滚动消费
func _scroll_visible_region(direction: Direction) -> bool:
	if _parent == null or (direction != Direction.UP and direction != Direction.DOWN):
		return false
	var scroll: ScrollContainer = _find_visible_scroll_container(_parent)
	if scroll == null:
		return false
	var step: int = scroll_step if direction == Direction.DOWN else -scroll_step
	## scroll_vertical 内置钳制，越界赋值会被自动收敛到合法范围
	scroll.scroll_vertical += step
	return true

## 深度优先查找父节点下第一个"树内有效可见"的 ScrollContainer
## 必须用 is_visible_in_tree()：TabContainer 隐藏页内的滚动容器不可见，须跳过
func _find_visible_scroll_container(node: Node) -> ScrollContainer:
	for child in node.get_children():
		if child is ScrollContainer and (child as ScrollContainer).is_visible_in_tree():
			return child as ScrollContainer
		var found: ScrollContainer = _find_visible_scroll_container(child)
		if found != null:
			return found
	return null

## 视口焦点变化回调：把 current_index 同步为实际获得焦点的控件索引
## 触发来源：鼠标点击控件、切页、其他界面主动 grab_focus
## 焦点控件不在本导航列表内（例如别的界面）时保持原索引不变
func _on_viewport_gui_focus_changed(control: Control) -> void:
	if not is_active or control == null:
		return
	var idx: int = focusable_controls.find(control)
	if idx >= 0:
		current_index = idx

## 移动焦点：按屏幕几何方向寻找最近控件（而非简单索引±1），贴合视觉布局
## 返回：true=焦点确实发生了移动
func _move_focus(direction: Direction) -> bool:
	if focusable_controls.is_empty():
		return false

	var old_index: int = current_index
	var current: Control = focusable_controls[current_index]

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
		return true
	return false

## 上下方向输入的统一分发：优先移动焦点；无处可移动时退化为滚动当前可见区域
## 设计意图：状态页等"纯文本内容页"没有可聚焦控件，导航列表里通常只剩面板外的返回按钮，
##           若只做焦点移动则内容永远滚不动——此处补上直接滚动，保证长文本可翻阅
## 返回：true=本次输入已被消费
func _handle_vertical_navigation(direction: Direction) -> bool:
	if _move_focus(direction):
		return true
	return _scroll_visible_region(direction)

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
## 滑条（HSlider）与下拉框（OptionButton）不在此模拟：
##   二者的值由左右方向键/摇杆在焦点上"就地调节"（见_adjust_current_value），
##   手柄无需展开下拉弹窗（弹窗是窗口级Popup，焦点易被抢，主机端通用做法是就地轮换选项）
func _confirm_current() -> void:
	if focusable_controls.is_empty():
		return
	var control: Control = focusable_controls[current_index]
	if control is Button:
		(control as Button).pressed.emit()
	elif control is CheckBox:
		## 先翻转勾选态（不自动发信号），再手动补发toggled：保证监听方收到且只收到一次变更
		(control as CheckBox).set_pressed_no_signal(!(control as CheckBox).is_pressed())
		(control as CheckBox).toggled.emit((control as CheckBox).is_pressed())
	confirm_pressed.emit(control)

## 判断控件是否支持"聚焦后就地调节"（左右键增减数值/切换选项，而非移动焦点）
## HSlider：左右键按 step 增减数值；OptionButton：左右键循环切换选中项
## 参数可能为 null（焦点列表为空/索引失效时），统一返回 false
func _is_in_place_adjustable(control: Control) -> bool:
	return control != null and (control is HSlider or control is OptionButton)

## 就地调节当前焦点控件的数值/选项（方向仅取 LEFT/RIGHT，其余忽略）
## 返回：true=已完成就地调节（调用方应消费本次输入，不再移动焦点）
func _adjust_current_value(direction: Direction) -> bool:
	if focusable_controls.is_empty():
		return false
	var control: Control = focusable_controls[current_index]
	if not _is_in_place_adjustable(control):
		return false

	## 方向→步进符号：RIGHT=+1（增大/下一项），LEFT=-1（减小/上一项）
	var sign_step: int = 0
	if direction == Direction.RIGHT:
		sign_step = 1
	elif direction == Direction.LEFT:
		sign_step = -1
	if sign_step == 0:
		return false

	if control is HSlider:
		## 滑条：按 step 增减并钳制到量程；set_value 会发出 value_changed，
		## 消费方（如设置页音量滑块）据此实时应用，无需在此额外发信号
		var slider: HSlider = control as HSlider
		slider.set_value(clamp(slider.value + slider.step * sign_step, slider.min_value, slider.max_value))
	elif control is OptionButton:
		## 下拉框：循环切换选中项（到边界回卷）。
		## select() 为程序化接口，不会自发 item_selected，故手动补发让监听方（如主题下拉）同步生效
		var option: OptionButton = control as OptionButton
		var count: int = option.item_count
		if count <= 0:
			return false
		option.select((option.selected + sign_step + count) % count)
		option.item_selected.emit(option.selected)
	return true

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

	# 获取"摇杆专用"向量：键盘方向键/D-Pad 已由 _unhandled_input（ui_*）单次处理，
	# 这里只负责摇杆的持续输入，避免同一按键被"事件 + 轮询"各处理一次（按一下走两格）
	var nav_vector: Vector2 = InputManager.get_stick_vector()
	var joy_x: float = nav_vector.x
	var joy_y: float = nav_vector.y

	var current_direction: Direction = -1

	# 检测方向（InputManager 已处理死区，直接判断方向）
	if abs(joy_y) > joystick_deadzone:
		current_direction = Direction.DOWN if joy_y > 0 else Direction.UP
	elif abs(joy_x) > joystick_deadzone:
		current_direction = Direction.RIGHT if joy_x > 0 else Direction.LEFT

	if current_direction >= 0:
		## 判断本次拨动是否为"就地调节"（焦点在滑条/下拉框上且方向为左右）：
		## 是则连续增减数值/轮换选项，连发间隔用更快的 repeat_delay；
		## 否则为普通焦点移动，仍用 initial_delay 防止选项跳得过快
		var in_place: bool = (current_direction == Direction.LEFT or current_direction == Direction.RIGHT) \
			and _is_in_place_adjustable(get_current_control())
		var repeat_interval: float = repeat_delay if in_place else initial_delay

		if current_direction != _joystick_last_direction:
			## 方向刚变化：立即响应一次并清零计时（首次响应零延迟，手感关键）
			_joystick_last_direction = current_direction
			_joystick_hold_time = 0.0
			if in_place:
				_adjust_current_value(current_direction)
			else:
				_handle_vertical_navigation(current_direction)
		else:
			## 同方向持续按住：累计时间，超过阈值后进入连发
			_joystick_hold_time += delta
			if _joystick_hold_time >= repeat_interval:
				if in_place:
					_adjust_current_value(current_direction)
				else:
					_handle_vertical_navigation(current_direction)
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
		_handle_vertical_navigation(Direction.UP)
		get_viewport().set_input_as_handled()
		
	elif InputManager.is_action_just_pressed_safe("ui_down"):
		_handle_vertical_navigation(Direction.DOWN)
		get_viewport().set_input_as_handled()
		
	elif InputManager.is_action_just_pressed_safe("ui_left"):
		## 焦点在滑条/下拉框上：左右键就地调节数值或选项；否则按几何方向移动焦点
		if not _adjust_current_value(Direction.LEFT):
			_move_focus(Direction.LEFT)
		get_viewport().set_input_as_handled()
		
	elif InputManager.is_action_just_pressed_safe("ui_right"):
		if not _adjust_current_value(Direction.RIGHT):
			_move_focus(Direction.RIGHT)
		get_viewport().set_input_as_handled()
	
	elif InputManager.is_action_just_pressed_safe("ui_confirm"):
		_confirm_current()
		get_viewport().set_input_as_handled()
	
	elif InputManager.is_action_just_pressed_safe("ui_cancel"):
		cancel_pressed.emit()
		get_viewport().set_input_as_handled()
