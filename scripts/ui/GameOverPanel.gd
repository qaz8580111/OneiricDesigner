## GameOverPanel.gd - 游戏结束结算面板（纯代码构建UI，无需.tscn）
## 职责：死亡过渡后展示本局统计数据，提供"再来一局"和"返回主菜单"入口
## 继承：Control（全屏覆盖层，挂在ui_stack下）
## 设计意图：
##   1. roguelike的"再来一局"驱动力：结算面板量化展示本局成果，
##      让玩家直观看到成长（击杀/等级/难度/词条数），激发破纪录欲望
##   2. 数据来自RunStats单例（每局自动重置），面板只负责展示，不持有状态
##   3. 支持R键快捷重开，减少重开摩擦
##   4. 同一面板复用两种收尾：玩家死亡（victory=false）与击败终极BOSS通关（victory=true），
##      差异仅在标题文案与配色——两条收尾链路的统计数据、按钮行为完全一致
## 数据流：RunStats单例（各系统上报）→ _build_stats_text() → 结算展示；
##        restart_requested / back_to_menu_requested → Main.gd 监听后执行重开或切换主菜单
extends Control

## ========== 信号定义 ==========

## 再来一局信号：玩家点击重开按钮或按R键时发出（Main.gd监听后重启游戏）
signal restart_requested

## 返回主菜单信号：玩家点击返回按钮时发出（Main.gd监听后切换到主菜单）
signal back_to_menu_requested

## ========== 成员变量 ==========

## 是否为通关结算（由 Main.gd 在 add_child 之前赋值）
## false = 玩家死亡结算（默认，红色"梦境终结"）；true = 击败终极 BOSS 通关（金色"通关"）
## 时序约束：必须在入树前赋值——_ready() 会立即据此构建标题与配色
var victory: bool = false

## 待落盘的通关成绩（由 Main.gd 在 add_child 之前从 LeaderboardManager 取暂存值注入）
## < 0 = 无待提交成绩（死亡结算路径或不正常路径），面板不展示昵称输入框；
## ≥ 0 = 有待提交成绩（通关结算路径），面板展示 LineEdit 让玩家输入昵称，
## 按钮回调时调 LeaderboardManager.commit_pending_classic_time 落盘
var pending_classic_time: float = -1.0

## 统计文本标签引用（R键重开时需要判断面板是否已显示）
var _stats_label: Label = null

## 是否已构建完成（防止R键在面板构建前触发）
var _is_ready: bool = false

## ---------- 手柄/键盘导航状态 ----------
## 当前选中按钮索引：0=再来一局，1=返回主菜单
var _selected_index: int = 0

## 两个按钮的引用（导航时需要高亮）
var _restart_btn: Button = null
var _menu_btn: Button = null

## 昵称输入框引用（仅通关结算时构建；按钮回调中读取玩家输入文本）
var _nickname_edit: LineEdit = null

## 昵称输入提示标签引用（与 LineEdit 同生命周期）
var _nickname_hint: Label = null

## 昵称是否已提交（防止玩家在结算面板上重复点击按钮重复落盘同一成绩）
var _nickname_committed: bool = false

## 选中态样式常量
const SELECTED_MODULATE: Color = Color(1.25, 1.15, 0.75)  ## 金色高亮
const NORMAL_MODULATE: Color = Color(1.0, 1.0, 1.0)
const SELECT_TWEEN_TIME: float = 0.06

## 昵称输入框宽度（与按钮等宽，视觉对齐）
const NICKNAME_EDIT_WIDTH: float = 280.0
## 昵称输入框高度（与按钮等高）
const NICKNAME_EDIT_HEIGHT: float = 32.0

## ========== 生命周期方法 ==========

## _ready() - 构建整个面板UI并填充本局统计
func _ready() -> void:
	## 结算面板需要在暂停状态下也能响应输入（死亡过渡后树已unpause，但保险起见）
	process_mode = Node.PROCESS_MODE_ALWAYS
	## 全屏覆盖：set_anchors_and_offsets_preset同时设置锚点与偏移（等价编辑器Layout菜单）
	## 关键修复：不能用set_anchors_preset——它只改锚点并按"保持当前矩形"重算偏移，
	## 新建Control的矩形是(0,0,0,0)，结果面板塌缩成左上角0x0的点，
	## 表现为结算菜单跑到屏幕左上角、盖不住主场景（1920x1280下尤其明显）
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 拦截鼠标点击，防止穿透到下层（满足"背景主场景无法点击"需求）
	mouse_filter = Control.MOUSE_FILTER_STOP

	## ---------- 全屏暗色背景 ----------
	## 深紫黑色背景：呼应"梦境"主题，营造结算的沉静氛围
	## 顺序：先add_child挂到面板下，再设全屏锚点偏移（确保相对父矩形计算生效）
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.05, 0.02, 0.1, 0.92)
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 背景IGNORE鼠标事件，否则挡住按钮点击（项目教训）
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 居中容器 ----------
	## CenterContainer全屏铺满，子节点按最小尺寸永远居中——
	## 不依赖任何锚点/偏移语义，任意分辨率下都可靠居中（修复左上角问题的兜底保障）
	var center: CenterContainer = CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 容器自身不拦截鼠标（按钮在子级中，事件先命中按钮；未命中的落到面板STOP层）
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 垂直布局容器 ----------
	## 居中交给CenterContainer，vbox作为普通子节点无需任何锚点配置
	var vbox: VBoxContainer = VBoxContainer.new()
	## 紧凑间距（5px），1920x1280下内容居中紧凑显示
	vbox.add_theme_constant_override("separation", 5)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vbox)

	## ---------- 标题 ----------
	var title: Label = Label.new()
	## 通关/死亡两种结算共用面板：通关用金色庆祝文案，死亡用红色哀悼文案
	if victory:
		title.text = "★ 梦境终结 · 通关 ★"
		title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	else:
		title.text = "—— 梦境终结 ——"
		## 红色标题呼应"死亡"主题
		title.add_theme_color_override("font_color", Color(0.95, 0.35, 0.35))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	## ---------- 统计文本 ----------
	## 从RunStats单例读取本局数据，格式化为多行文本
	## 设计意图：数据全部来自RunStats，面板无状态，天然支持每局刷新
	var stats: Label = Label.new()
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.text = _build_stats_text()
	## 统计文本用浅金色，与标题区分层级
	stats.add_theme_color_override("font_color", Color(0.95, 0.9, 0.75))
	vbox.add_child(stats)
	## 保存引用（供判断构建状态）
	_stats_label = stats

	## ---------- 昵称输入区（仅通关结算路径构建） ----------
	## 设计意图：通关玩家可在结算面板留下姓名，写入排行榜；
	##              死亡结算路径 pending_classic_time < 0 不构建，保持原布局不变
	if pending_classic_time >= 0.0:
		_build_nickname_input(vbox)

	## ---------- 按钮水平排列 ----------
	var hbox: HBoxContainer = HBoxContainer.new()
	## 按钮间水平间距
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hbox)

	## 再来一局按钮（主要操作，绿色突出）
	var restart_btn: Button = Button.new()
	restart_btn.text = "再来一局 (R)"
	restart_btn.custom_minimum_size = Vector2(120, 28)
	restart_btn.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	restart_btn.pressed.connect(_on_restart_pressed)
	## 禁用内置焦点导航，改用手动D-Pad逻辑（避免一次按键跳两格）
	restart_btn.focus_mode = Control.FOCUS_NONE
	hbox.add_child(restart_btn)
	_restart_btn = restart_btn

	## 返回主菜单按钮（次要操作，默认色）
	var menu_btn: Button = Button.new()
	menu_btn.text = "返回主菜单"
	menu_btn.custom_minimum_size = Vector2(120, 28)
	menu_btn.pressed.connect(_on_back_pressed)
	menu_btn.focus_mode = Control.FOCUS_NONE
	hbox.add_child(menu_btn)
	_menu_btn = menu_btn

	## 标记构建完成（R键重开生效前提）
	_is_ready = true
	## 默认选中"再来一局"（最高频操作）
	_set_selection(0)

## _unhandled_input() - R键快捷重开
## 设计意图：死亡后重开是最高频操作，快捷键减少点击摩擦
func _unhandled_input(event: InputEvent) -> void:
	## 面板未构建完成时忽略输入
	if not _is_ready:
		return
	## LineEdit 有焦点时禁用 R 键：玩家正在输入昵称，R 是合法字符，
	## 不应被快捷重开消费掉导致玩家还没输入完就重启游戏
	if _nickname_edit != null and _nickname_edit.has_focus():
		return
	## 非按键按下事件忽略（先做类型检查避免访问不存在属性）
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	## R键触发重开
	if event.physical_keycode == KEY_R:
		_on_restart_pressed()

## _process() - 手柄/键盘导航：LT/RT扳机与D-Pad左右切换按钮 + A键确认
## 设计意图：结算面板是死亡后唯一交互入口，必须支持手柄全操作；
## 复用InputManager网关保证与升级/神庙面板一致的输入过滤；
## LT/RT走InputManager的扳机轴越阈边沿检测（game_choice_prev/next，SETTINGS上下文放行），
## 与升级三选一切换语义完全一致——同一套肌肉记忆覆盖所有选择面板
func _process(_delta: float) -> void:
	## 构建未完成时不响应
	if not _is_ready:
		return
	## LineEdit 有焦点时禁用手柄导航：玩家正在输入昵称，
	## 手柄按键会被 LineEdit 当作字符插入（A 键插入 'a'），不应触发按钮切换/确认
	if _nickname_edit != null and _nickname_edit.has_focus():
		return
	## LT扳机/方向键左：选中"再来一局"（索引0）
	if InputManager.is_action_just_pressed_safe("game_choice_prev") \
			or InputManager.is_action_just_pressed_safe("ui_left"):
		_set_selection(0)
	## RT扳机/方向键右：选中"返回主菜单"（索引1）
	elif InputManager.is_action_just_pressed_safe("game_choice_next") \
			or InputManager.is_action_just_pressed_safe("ui_right"):
		_set_selection(1)
	## A键/空格/回车：确认当前选中按钮
	elif InputManager.is_action_just_pressed_safe("ui_confirm") \
			or InputManager.is_action_just_pressed_safe("game_confirm"):
		_activate_current()

## ========== 导航辅助方法 ==========

## 设置选中索引（去重 + clamp保护）
func _set_selection(index: int) -> void:
	index = clampi(index, 0, 1)
	if index == _selected_index and _is_ready:
		return
	_selected_index = index
	_refresh_selection_visual()

## 刷新选中按钮的视觉高亮
func _refresh_selection_visual() -> void:
	if _restart_btn == null or _menu_btn == null:
		return
	## 用单个tween同时高亮选中按钮、淡化未选中按钮
	var tw: Tween = create_tween().set_parallel(true)
	var selected: Button = _restart_btn if _selected_index == 0 else _menu_btn
	var unselected: Button = _menu_btn if _selected_index == 0 else _restart_btn
	tw.tween_property(selected, "modulate", SELECTED_MODULATE, SELECT_TWEEN_TIME).set_ease(Tween.EASE_OUT)
	tw.tween_property(unselected, "modulate", NORMAL_MODULATE, SELECT_TWEEN_TIME).set_ease(Tween.EASE_OUT)

## 激活当前选中的按钮
func _activate_current() -> void:
	if _selected_index == 0:
		_on_restart_pressed()
	else:
		_on_back_pressed()

## ========== 内部方法 ==========

## 从RunStats构建本局统计文本
## 返回：多行统计文本（存活时间/击杀/碎片/难度/词条数）
##       通关结算路径额外追加"终极BOSS战用时"行（数据来自 pending_classic_time）
func _build_stats_text() -> String:
	## 数据流：RunStats单例（各系统上报）→ 此方法 → 展示
	var lines: Array[String] = []
	lines.append("存活时间：%s" % RunStats.get_formatted_time())
	lines.append("击杀敌人：%d" % RunStats.kills)
	lines.append("梦境碎片：%d" % RunStats.fragments_total)
	lines.append("最终难度：%d" % RunStats.difficulty_reached)
	lines.append("获得词条：%d" % RunStats.upgrades_taken)
	## 通关结算路径追加 BOSS 战用时（待落盘的成绩，由 StageDirector 暂存）
	if pending_classic_time >= 0.0:
		lines.append("终极BOSS战用时：%s" % LeaderboardManager.format_time(pending_classic_time))
	return "\n".join(lines)

## 构建昵称输入区（仅通关结算路径调用）
## 参数：parent - 父容器（vbox）
## 设计意图：用一个垂直容器包"提示+输入框"，保持水平居中布局；
##              LineEdit 默认填"佚名"，玩家可清空后输入自己的昵称
func _build_nickname_input(parent: Container) -> void:
	## ---------- 垂直容器包提示 + 输入框 ----------
	var nick_vbox: VBoxContainer = VBoxContainer.new()
	nick_vbox.add_theme_constant_override("separation", 4)
	nick_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	nick_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(nick_vbox)

	## ---------- 昵称输入提示标签 ----------
	_nickname_hint = Label.new()
	_nickname_hint.text = "留下你的昵称（计入通关榜）："
	_nickname_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_nickname_hint.add_theme_color_override("font_color", Color(0.95, 0.85, 0.55))
	nick_vbox.add_child(_nickname_hint)

	## ---------- 昵称输入框 ----------
	_nickname_edit = LineEdit.new()
	## 默认填"佚名"：玩家可直接回车保留默认值，或清空后输入自定义昵称
	_nickname_edit.text = LeaderboardManager.DEFAULT_NICKNAME
	## 限制最大字符数：与 LeaderboardManager.MAX_NICKNAME_LENGTH 对齐，
	## 玩家在 LineEdit 内就不能输入超过限制的字符，无需在 commit 时再截断兜底
	_nickname_edit.max_length = LeaderboardManager.MAX_NICKNAME_LENGTH
	## 占位提示：玩家清空后看到此提示
	_nickname_edit.placeholder_text = "输入昵称（最多 %d 字）" % LeaderboardManager.MAX_NICKNAME_LENGTH
	_nickname_edit.custom_minimum_size = Vector2(NICKNAME_EDIT_WIDTH, NICKNAME_EDIT_HEIGHT)
	## 居中对齐输入框（VBox 默认左对齐，需要用 ALIGNMENT_CENTER 居中）
	nick_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	## 提交后自动失焦：玩家按回车后 LineEdit.text_submitted 信号触发，
	## 自动让出焦点避免回车后再误输入字符（不直接 commit：玩家可能还想选按钮）
	_nickname_edit.text_submitted.connect(_on_nickname_text_submitted)
	nick_vbox.add_child(_nickname_edit)

## ========== 信号回调 ==========

## 再来一局按钮回调（R键也走这里）
func _on_restart_pressed() -> void:
	## 通关结算路径：先 commit 昵称再退出面板
	## 时序约束：必须在 emit 之前调用——emit 后 Main 会立即 _start_game()，
	## _start_game 内部会 _clear_ui() 把本面板 free 掉，此时 _nickname_edit 引用失效
	_commit_pending_nickname_if_any()
	## 播放UI点击音效
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	## 发出重开信号（Main.gd负责重启流程）
	restart_requested.emit()

## 返回主菜单按钮回调
func _on_back_pressed() -> void:
	## 通关结算路径：同上，先 commit 昵称再退出
	_commit_pending_nickname_if_any()
	## 播放UI点击音效
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	## 发出返回信号（Main.gd负责切换场景）
	back_to_menu_requested.emit()

## LineEdit 回车提交回调：玩家按回车后只让输入框失焦，不直接 commit
## 设计意图：玩家按回车可能只是想"确认昵称"，不应误触开始下一局；
##              正式提交仍走按钮回调——按钮同时表达"我选好了"和"我选哪个操作"
func _on_nickname_text_submitted(_new_text: String) -> void:
	if _nickname_edit != null:
		## release_focus 释放输入焦点，让 LineEdit 不再接收键盘事件
		## 副作用：按下回车后键盘事件重新走 _process 的导航逻辑
		_nickname_edit.release_focus()

## 内部辅助：如果面板有待提交的通关成绩，调 LeaderboardManager 落盘
## 防重入：用 _nickname_committed flag 保证一局成绩只 commit 一次
## 设计意图：玩家在面板上点"再来一局"和"返回主菜单"都可能触发（理论上只会点一个），
##              若两个按钮都点了（极端情况下信号重入），flag 防止重复写入
func _commit_pending_nickname_if_any() -> void:
	## 无 pending 或已提交：直接返回
	if pending_classic_time < 0.0 or _nickname_committed:
		return
	## 读取玩家输入的昵称（LineEdit 一定已被构建，但兜底判空）
	var nickname: String = ""
	if _nickname_edit != null:
		nickname = _nickname_edit.text
	## 落盘：commit_pending_classic_time 内部会调用 _sanitize_nickname 处理空/超长
	LeaderboardManager.commit_pending_classic_time(nickname)
	## 标记已提交，防止重复写入
	_nickname_committed = true
