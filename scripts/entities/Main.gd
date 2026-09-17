## Main.gd - 游戏主控制脚本
## 职责：管理游戏状态切换（主菜单/游戏/暂停/设置/游戏结束）、场景加载、UI管理
## 继承：Node2D（Godot 4的2D节点，作为游戏根节点）
## 节点结构：Main(Node2D, 场景根) → CanvasLayer → UIStack(菜单/HUD的UI栈) + DeathOverlay(死亡黑屏遮罩)；GameWorld(游戏元素容器)
## 系统交互：
##   - 信号：GameManager 的 game_started/game_ended/game_paused/game_resumed → 驱动界面切换
##   - 连接：玩家 shot → GameWorld 创建子弹；HealthController.player_died → GameWorld 结束游戏
##   - 输入：_process 全局监听 ui_cancel(ESC) 暂停；process_mode=ALWAYS 保证暂停中仍能响应与更新死亡动画
## 数据流：主菜单 → 开始游戏 → GameManager.start_new_game → game_started → 生成世界+玩家+HUD →
##         玩家死亡 → game_ended → 黑屏渐隐2秒+停1秒 → 解除场景树暂停 → 结算面板 → 再来一局/回主菜单
## 设计意图：Main是唯一的场景级屏幕状态机(Screen枚举)，UI生命周期/切换集中于此；
##           游戏逻辑下放给 GameWorld 与 GameManager，UI场景只做展示与信号转发
extends Node2D

## ========== 游戏屏幕状态枚举 ==========

## 定义游戏的所有屏幕状态
enum Screen {
	MAIN_MENU,  ## 主菜单：游戏开始前的界面
	GAME,       ## 游戏中：玩家进行游戏的界面
	SETTINGS,   ## 设置：游戏设置界面
	PAUSED,     ## 暂停：游戏暂停界面
	GAME_OVER   ## 游戏结束：玩家死亡后的界面
}

## ========== 成员变量（运行时数据） ==========

## 当前屏幕状态
var current_screen: Screen = Screen.MAIN_MENU

## 玩家引用
var player: CharacterBody2D

## 游戏世界引用（包含敌人、子弹、拾取物等）
var game_world: Node2D

## 当前活跃的UI界面（如菜单、设置等）
var active_ui: Control

## 上一个屏幕状态（用于从设置界面返回）
var previous_screen: Screen

## 是否正在执行死亡动画（用于_process中更新透明度）
var _is_death_fading: bool = false
## 死亡动画开始时间（毫秒）
var _death_fade_start_time: int = 0

## ---------- 死亡慢动作计时器（直播增强：死亡瞬间0.5s慢动作） ----------
## 是否正在执行死亡慢动作
var _is_death_slowmo: bool = false
## 死亡慢动作开始的墙钟时间戳（毫秒，用 Time.get_ticks_msec() 不受 time_scale 影响）
var _slowmo_start_msec: int = 0
## 慢动作时的时间缩放（0.2 = 20%速度，兼顾画面清晰度和音效可闻）
const DEATH_SLOWMO_SCALE: float = 0.2
## 慢动作持续时间（秒，按真实时间计算而非 delta）
const DEATH_SLOWMO_DURATION: float = 0.5

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## UI栈容器，用于显示菜单、设置、HUD等UI界面
@onready var ui_stack: Control = $CanvasLayer/UIStack

## 游戏世界容器，用于放置玩家和游戏世界
@onready var game_world_container: Node2D = $GameWorld

## 死亡过渡黑屏遮罩（ColorRect），用于玩家死亡时的黑屏过渡动画
@onready var death_overlay: ColorRect = $CanvasLayer/DeathOverlay

## ========== 场景预加载（避免运行时重复加载） ==========

## 主菜单场景
var MAIN_MENU_SCENE: PackedScene = preload("res://scenes/ui/MainMenu.tscn")

## 设置界面场景
var SETTINGS_SCENE: PackedScene = preload("res://scenes/ui/Settings.tscn")

## 暂停菜单场景
var PAUSE_MENU_SCENE: PackedScene = preload("res://scenes/ui/PauseMenu.tscn")

## 游戏HUD场景（显示血量、碎片等）
var GAME_HUD_SCENE: PackedScene = preload("res://scenes/ui/GameHUD.tscn")

## 结算面板脚本（纯代码构建UI，死亡后展示本局统计与重开入口）
var GAME_OVER_PANEL_SCRIPT: GDScript = preload("res://scripts/ui/GameOverPanel.gd")

## 玩家场景
var PLAYER_SCENE: PackedScene = preload("res://scenes/gameplay/Player.tscn")

## 游戏世界场景（包含敌人生成、子弹管理等逻辑）
var WORLD_SCENE: PackedScene = preload("res://scenes/gameplay/GameWorld.tscn")

## ========== HUD引用 ==========

## 游戏HUD引用（独立于其他UI，在游戏过程中始终显示）
var game_hud: Control = null

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 设置此节点为PROCESS_MODE_ALWAYS（暂停状态下仍可更新，确保死亡动画正常运行）
	## 注意：Main自身ALWAYS，但游戏世界容器必须显式设为PAUSABLE，
	## 否则Player/Enemy/Camera2D会继承ALWAYS导致暂停无效（已发生的线上事故根因）
	process_mode = Node.PROCESS_MODE_ALWAYS
	## 游戏世界容器及其所有子节点（玩家/敌人/子弹/相机）在暂停时应冻结
	game_world_container.process_mode = Node.PROCESS_MODE_PAUSABLE
	
	## 连接游戏管理器的信号（GameManager是全局单例）
	if GameManager:
		## 游戏开始信号：当游戏开始时触发回调
		GameManager.game_started.connect(_on_game_started)
		## 游戏结束信号：当玩家死亡时触发回调
		GameManager.game_ended.connect(_on_game_ended)
		## 游戏暂停信号：当游戏暂停时触发回调
		GameManager.game_paused.connect(_on_game_paused)
		## 游戏恢复信号：当游戏恢复时触发回调
		GameManager.game_resumed.connect(_on_game_resumed)

	## 显示主菜单（游戏启动后进入主菜单）
	_show_main_menu()

## ========== 界面显示方法 ==========

## 显示主菜单
func _show_main_menu() -> void:
	## 清除当前所有UI界面
	_clear_ui()
	## 设置当前屏幕状态为MAIN_MENU
	current_screen = Screen.MAIN_MENU

	## 切换输入上下文到SETTINGS（允许UI操作，如点击按钮）
	InputManager.reset_context("SETTINGS")

	## 实例化主菜单场景
	active_ui = MAIN_MENU_SCENE.instantiate()
	## 连接主菜单按钮信号
	active_ui.start_game.connect(_on_start_game)        ## 开始游戏按钮
	active_ui.open_settings.connect(_on_open_settings_from_menu)  ## 打开设置按钮
	active_ui.quit_game.connect(_on_quit_game)          ## 退出游戏按钮
	## 将主菜单添加到UI栈
	ui_stack.add_child(active_ui)
	## 清除游戏元素（玩家、敌人等）
	_clear_game()

## 显示设置界面
func _show_settings() -> void:
	## 保存当前屏幕状态（用于返回）
	previous_screen = current_screen
	## 清除当前所有UI界面
	_clear_ui()
	## 设置当前屏幕状态为SETTINGS
	current_screen = Screen.SETTINGS
	## 实例化设置界面场景
	active_ui = SETTINGS_SCENE.instantiate()
	## 连接设置界面按钮信号
	active_ui.go_back.connect(_on_settings_back)        ## 返回按钮
	active_ui.settings_applied.connect(_on_settings_applied)  ## 设置应用按钮

	## 如果从暂停界面打开设置，设置UI为PROCESS_MODE_ALWAYS
	## 原因：暂停状态下普通节点不会处理输入和更新
	if previous_screen == Screen.PAUSED:
		active_ui.process_mode = Node.PROCESS_MODE_ALWAYS

	## 将设置界面添加到UI栈
	ui_stack.add_child(active_ui)

## 显示暂停菜单
func _show_pause_menu() -> void:
	## 清除当前所有UI界面（保留HUD）
	_clear_ui()
	## 设置当前屏幕状态为PAUSED
	current_screen = Screen.PAUSED
	## 立即暂停（同步，不等UI）——关键修复：
	## 原实现 await 一帧后才暂停，该帧内"菜单已显示但游戏仍在运行"，
	## 帧率波动时（大量敌人/直播推流）窗口拉长到肉眼可见；
	## 菜单节点为 PROCESS_MODE_ALWAYS，先暂停完全不影响其构建与交互
	GameManager.pause_game()
	## 实例化暂停菜单场景
	active_ui = PAUSE_MENU_SCENE.instantiate()
	## 连接暂停菜单按钮信号
	active_ui.resume_game.connect(_on_resume_game)      ## 继续游戏按钮
	active_ui.open_settings.connect(_on_open_settings_from_pause)  ## 打开设置按钮
	active_ui.quit_to_menu.connect(_on_quit_to_menu)    ## 返回主菜单按钮

	## 设置暂停菜单为PROCESS_MODE_ALWAYS（暂停状态下仍可交互）
	active_ui.process_mode = Node.PROCESS_MODE_ALWAYS

	## 将暂停菜单添加到UI栈（暂停中 _ready 照常执行，导航器下帧激活）
	ui_stack.add_child(active_ui)

## 显示游戏结束结算面板（死亡黑屏过渡完成后调用）
## 设计意图：roguelike的"再来一局"驱动力——结算面板量化展示本局成果
func _show_game_over_panel() -> void:
	## 清除当前所有UI界面（HUD已在玩家死亡时自行隐藏，会随_clear_ui保留但不可见）
	_clear_ui()
	## 设置当前屏幕状态为GAME_OVER
	current_screen = Screen.GAME_OVER
	## 切换输入上下文到UI操作模式（允许按钮点击）
	InputManager.reset_context("SETTINGS")
	## 用脚本创建结算面板（纯代码UI，无.tscn）
	active_ui = GAME_OVER_PANEL_SCRIPT.new()
	## 面板必须ALWAYS处理模式（死亡瞬间场景树可能仍处于暂停）
	active_ui.process_mode = Node.PROCESS_MODE_ALWAYS
	## 连接结算面板信号：再来一局 / 返回主菜单
	active_ui.restart_requested.connect(_on_restart_from_game_over)
	active_ui.back_to_menu_requested.connect(_on_back_to_menu_from_game_over)
	## 添加到UI栈显示
	ui_stack.add_child(active_ui)

## ========== 游戏控制方法 ==========

## 开始游戏
func _start_game() -> void:
	## ---------- 全局状态重置 ----------
	## 确保死亡慢动作残留不会影响新一局
	_is_death_slowmo = false
	_slowmo_start_msec = 0
	Engine.time_scale = 1.0
	## 兜底解除暂停：神庙进入会暂停场景树，极端路径下（重开/回主菜单）
	## 若Temple的_exit_tree清理未覆盖到，这里保证新一局一定是运行状态
	get_tree().paused = false

	## 清除当前所有UI界面（保留HUD）
	_clear_ui()
	## 清除上一局残留的游戏元素（旧玩家/旧游戏世界/旧HUD）
	## 修复bug：从结算面板"再来一局"时不经过主菜单（主菜单路径才会调用_clear_game），
	## 若不在此清理，已死亡（血量0）的旧玩家仍留在"player"组中，新HUD按组查找玩家
	## 会错误绑定旧玩家，导致左上角血量显示0，同时旧GameWorld还会继续生成敌人
	_clear_game()
	## 设置当前屏幕状态为GAME
	current_screen = Screen.GAME
	## 强制重置输入上下文到GAMEPLAY，避免菜单残留的PAUSE_MENU阻塞游戏输入
	InputManager.reset_context("GAMEPLAY")
	## 重置死亡遮罩状态（确保游戏开始时屏幕正常）
	_reset_death_overlay()
	## 调用GameManager开始新游戏
	GameManager.start_new_game()

## 生成游戏元素（玩家、游戏世界、HUD）
func _spawn_game_elements() -> void:
	## 实例化游戏世界场景
	game_world = WORLD_SCENE.instantiate()
	## 将游戏世界添加到容器中
	game_world_container.add_child(game_world)

	## 实例化玩家场景
	player = PLAYER_SCENE.instantiate() as CharacterBody2D
	if player == null:
		push_error("Player 场景实例化失败或根节点不是 CharacterBody2D")
		return
	
	## 应用保存的自动射击设置
	_apply_saved_auto_shoot_setting(player)
	
	## 设置玩家初始位置：竞技场正中心(0,0)（固定竞技场5760×3840的几何中心，
	## 相机limit以此为对称中心；旧屏幕中心(960,640)会让开局相机即被钳在右下角）
	player.position = Vector2.ZERO
	## 将玩家添加到容器中
	game_world_container.add_child(player)

	## 将玩家引用传递给游戏世界（供敌人查找玩家使用）
	game_world.player = player
	
	## 连接玩家射击信号到游戏世界（游戏世界负责创建子弹）
	if player.has_signal("shot"):
		player.connect("shot", game_world._on_player_shot)
	
	## 获取玩家的健康控制器并连接死亡信号
	var health_controller: Node = player.get_node_or_null("HealthController")
	if health_controller != null and health_controller.has_signal("player_died"):
		health_controller.connect("player_died", game_world._on_player_killed)

	## 实例化游戏HUD
	game_hud = GAME_HUD_SCENE.instantiate()
	## 将HUD添加到UI栈
	ui_stack.add_child(game_hud)

## 清除游戏元素（玩家、游戏世界、HUD）
## 注意：必须用free()立即销毁而非queue_free()延迟销毁——
## queue_free要等当前帧结束才真正移除节点，而_start_game的调用链是同步的
## （清理后立刻start_new_game→game_started→生成新玩家），若延迟销毁，
## 同帧内"player"组中仍存在旧死亡玩家，新HUD按组查找会绑定到旧玩家（血量显示0）
## 调用时机均为UI输入回调（按钮点击/R键），不在物理回调中，free()是安全的
func _clear_game() -> void:
	## 遍历游戏世界容器的所有子节点并销毁（立即生效，同步移出"player"等组）
	for child in game_world_container.get_children():
		child.free()
	## 清空玩家引用
	player = null
	## 清空游戏世界引用
	game_world = null

	## 如果HUD存在，销毁HUD（旧HUD在死亡时已隐藏，直接free避免残留在UI栈中）
	if game_hud != null:
		game_hud.free()
		game_hud = null

## 清除UI界面（保留HUD）
func _clear_ui() -> void:
	## 遍历UI栈的所有子节点
	for child in ui_stack.get_children():
		## 保留HUD，销毁其他UI
		if child != game_hud:
			child.queue_free()
	## 清空活跃UI引用
	active_ui = null

## ========== 信号回调方法 ==========

## 开始游戏按钮回调
func _on_start_game() -> void:
	_start_game()

## 从主菜单打开设置回调
func _on_open_settings_from_menu() -> void:
	_show_settings()

## 从暂停界面打开设置回调
func _on_open_settings_from_pause() -> void:
	_show_settings()

## 退出游戏按钮回调
func _on_quit_game() -> void:
	## 退出游戏
	get_tree().quit()

## 继续游戏按钮回调
func _on_resume_game() -> void:
	## 调用GameManager恢复游戏
	GameManager.resume_game()
	## 清除暂停菜单UI
	_clear_ui()
	## 设置当前屏幕状态为GAME
	current_screen = Screen.GAME

## 返回主菜单按钮回调
func _on_quit_to_menu() -> void:
	## 调用GameManager恢复游戏（确保游戏状态正常）
	GameManager.resume_game()
	## 显示主菜单
	_show_main_menu()

## 结算面板"再来一局"回调（响应GameOverPanel.restart_requested，R键同效）
func _on_restart_from_game_over() -> void:
	## 直接重启新局（死亡流程已解除暂停，_start_game内部会重置状态并重新生成元素）
	_start_game()

## 结算面板"返回主菜单"回调（响应GameOverPanel.back_to_menu_requested）
func _on_back_to_menu_from_game_over() -> void:
	## 显示主菜单（游戏树已解除暂停，GameManager状态由start_new_game/菜单流程接管）
	_show_main_menu()

## 设置返回按钮回调
func _on_settings_back() -> void:
	## 如果从暂停界面打开设置，返回暂停界面
	if previous_screen == Screen.PAUSED:
		_show_pause_menu()
	else:
		## 否则返回主菜单
		_show_main_menu()

## 设置应用回调：将设置应用到游戏元素
func _on_settings_applied(settings: Dictionary) -> void:
	## 如果玩家存在，传递自动射击设置
	if player != null and player.has_method("set_auto_shoot"):
		player.set_auto_shoot(settings.get("auto_shoot", true))

## 游戏开始信号回调（响应GameManager.game_started）
func _on_game_started() -> void:
	## 生成游戏元素
	_spawn_game_elements()

## 游戏结束信号回调（响应GameManager.game_ended）
## 直播增强：死亡瞬间先0.5秒慢动作让观众看清"怎么死的"，再进入黑屏渐隐
func _on_game_ended() -> void:
	## 设置当前屏幕状态为GAME_OVER
	current_screen = Screen.GAME_OVER
	## 播放游戏结束音效（全局播放，宣告死亡）
	if AudioManager:
		AudioManager.play("game_over", 0.9)

	## ---------- 死亡慢动作启动 ----------
	## 场景树已在 CoreHealthComponent.take_damage 中暂停（get_tree().paused = true），
	## 但 Main.gd 是 PROCESS_MODE_ALWAYS，_process 仍在跑。
	## 慢动作效果：Engine.time_scale = 0.1，画面以 10% 速度播放死亡瞬间
	Engine.time_scale = DEATH_SLOWMO_SCALE
	_is_death_slowmo = true
	_slowmo_start_msec = Time.get_ticks_msec()
	## 先不启动死亡渐隐，等慢动作结束后再启动

## 游戏暂停信号回调（响应GameManager.game_paused）
func _on_game_paused() -> void:
	pass

## 游戏恢复信号回调（响应GameManager.game_resumed）
func _on_game_resumed() -> void:
	pass

## ========== 帧更新方法 ==========

## 从配置文件读取并应用保存的自动射击设置
## 参数：player_node - 玩家节点
func _apply_saved_auto_shoot_setting(player_node: CharacterBody2D) -> void:
	if not player_node.has_method("set_auto_shoot"):
		return
	
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")
	if err == OK:
		var auto_shoot: bool = config.get_value("Settings", "auto_shoot", true)
		player_node.set_auto_shoot(auto_shoot)
		print("Auto shoot setting loaded: ", auto_shoot)

## 开始死亡黑屏过渡动画
## 使用_process方法更新透明度，确保在暂停状态下也能运行
func _start_death_fade() -> void:
	## 如果黑屏遮罩不存在，直接返回主菜单
	if death_overlay == null:
		_show_main_menu()
		return
	
	## 设置黑屏遮罩为可见
	death_overlay.visible = true
	## 重置遮罩透明度为0（完全透明）
	death_overlay.color.a = 0.0
	
	## 标记正在执行死亡动画
	_is_death_fading = true
	## 记录动画开始时间
	_death_fade_start_time = Time.get_ticks_msec()
	
	## 设置死亡遮罩为PROCESS_MODE_ALWAYS（暂停状态下仍可更新）
	death_overlay.process_mode = Node.PROCESS_MODE_ALWAYS

## 重置死亡遮罩状态（游戏开始前调用）
func _reset_death_overlay() -> void:
	if death_overlay != null:
		death_overlay.color.a = 0.0
		death_overlay.visible = true

## 更新死亡黑屏过渡动画
## 在_process中每帧调用，处理透明度渐变和返回主菜单逻辑
func _update_death_fade() -> void:
	## 如果不在死亡动画状态，直接返回
	if not _is_death_fading or death_overlay == null:
		return
	
	## 渐变持续时间（秒）
	var fade_duration: float = 2.0
	## 计算经过的时间（转换为秒）
	var elapsed: float = (Time.get_ticks_msec() - _death_fade_start_time) / 1000.0
	
	## 如果动画已完成（黑屏完全显示）
	if elapsed >= fade_duration:
		## 设置透明度为1（完全不透明）
		death_overlay.color.a = 1.0
		## 等待1秒后显示结算面板
		if elapsed >= fade_duration + 1.0:
			## 重置死亡动画状态
			_is_death_fading = false
			## 恢复游戏（取消暂停状态——玩家死亡时CoreHealthComponent暂停了场景树）
			get_tree().paused = false
			## 重置死亡遮罩透明度（否则结算面板会被黑屏挡住）
			death_overlay.color.a = 0.0
			## 显示结算面板（展示本局统计 + 再来一局/返回主菜单）
			_show_game_over_panel()
		return
	
	## 计算当前透明度（使用线性插值）
	var alpha: float = elapsed / fade_duration
	## 更新遮罩颜色透明度
	death_overlay.color.a = alpha

## _process() - 每帧调用一次，用于处理全局输入和死亡动画
func _process(delta: float) -> void:
	## ---------- 死亡慢动作计时（用墙钟时间，不受 time_scale 缩放影响） ----------
	if _is_death_slowmo:
		var elapsed: float = (Time.get_ticks_msec() - _slowmo_start_msec) / 1000.0
		if elapsed >= DEATH_SLOWMO_DURATION:
			## 慢动作结束：恢复正常时间缩放 → 启动死亡渐隐
			_is_death_slowmo = false
			Engine.time_scale = 1.0
			_start_death_fade()
		## 慢动作期间不执行死亡渐隐（等慢动作结束再开始）
		return

	## 处理死亡黑屏过渡动画
	_update_death_fade()
	
	## 检测暂停/取消按钮：
	##   game_pause = 手柄START / 键盘PauseBreak（呼出与关闭暂停都走它）
	##   ui_cancel  = 键盘ESC / 手柄B（游戏中可呼出；暂停中由PauseMenu导航器消费关闭）
	var pause_pressed: bool = InputManager.is_action_just_pressed_safe("game_pause")
	var cancel_pressed: bool = InputManager.is_action_just_pressed_safe("ui_cancel")
	if pause_pressed or cancel_pressed:
		## 升级三选一进行中屏蔽暂停（防止暂停菜单叠加在选择面板上造成UI冲突）
		## 数据流：升级触发 → UpgradeManager.is_choosing=true → 此处拦截
		if UpgradeManager and UpgradeManager.is_choosing:
			return
		## 神庙选择面板打开期间同样屏蔽暂停（用上下文判断，无需Temple暴露状态）
		if InputManager.get_current_context() == "TEMPLE_CHOICE":
			return
		## 游戏中：显示暂停菜单
		if current_screen == Screen.GAME:
			_show_pause_menu()
		## 暂停中：START恢复游戏（B/ESC通常已被暂停菜单导航器消费，走不到这里，此处为兜底）
		elif current_screen == Screen.PAUSED:
			_on_resume_game()