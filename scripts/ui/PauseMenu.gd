## PauseMenu.gd - 暂停菜单逻辑脚本
## 职责：管理游戏暂停界面，处理继续游戏、打开设置、返回主菜单三种操作
## 继承：Control（UI控件基类，作为暂停菜单的根节点）
extends Control

## 暂停菜单必须在暂停状态下仍能处理输入，需要 ALWAYS 模式
func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

## ========== 信号定义（用于与其他节点通信） ==========

## 继续游戏信号：当用户点击继续游戏按钮时发出，通知上层恢复游戏
signal resume_game()

## 打开设置信号：当用户点击设置按钮时发出，通知上层打开设置界面
signal open_settings()

## 返回主菜单信号：当用户点击返回主菜单按钮时发出，通知上层返回主菜单
signal quit_to_menu()

## ========== UI节点引用（使用 @onready 延迟初始化） ==========

## 暂停菜单标题标签（显示"暂停"）
@onready var title_label: Label = $VBoxContainer/Title

## 继续游戏按钮
@onready var resume_button: Button = $VBoxContainer/ResumeButton

## 设置按钮（打开设置界面）
@onready var settings_button: Button = $VBoxContainer/SettingsButton

## 返回主菜单按钮
@onready var quit_button: Button = $VBoxContainer/QuitButton

## ========== 菜单导航器（用于手柄/键盘导航） ==========

## 菜单导航器脚本（用于处理键盘/手柄的菜单导航）
var MENU_NAVIGATOR_SCRIPT: Script = load("res://scripts/autoload/MenuController.gd")

## 菜单导航器实例
var _navigator: Node = null

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 更新界面文本（支持多语言）
	_update_text()
	
	## 连接按钮信号到处理方法
	resume_button.pressed.connect(_on_resume_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	
	## 监听语言变化信号（语言切换时更新界面文本）
	TranslationManager.language_changed.connect(_on_language_changed)

	## 添加菜单导航器为子节点（用于键盘/手柄导航）
	if MENU_NAVIGATOR_SCRIPT != null:
		_navigator = MENU_NAVIGATOR_SCRIPT.new()
		add_child(_navigator)
		## 连接导航器的取消信号到继续游戏处理（按ESC键继续游戏）
		_navigator.cancel_pressed.connect(_on_resume_button_pressed)
		## 等待一帧确保节点完全加入场景树
		await get_tree().process_frame
		## 激活导航器
		_navigator.activate(self)
	else:
		print("MenuNavigator script not found!")

## _exit_tree() - 节点离开场景树时调用，用于清理
func _exit_tree() -> void:
	## 如果导航器存在，停用导航器
	if _navigator != null:
		_navigator.deactivate()

## ========== 界面文本更新方法 ==========

## 更新界面文本（支持多语言）
func _update_text() -> void:
	title_label.text = TranslationManager.t("PAUSED_TITLE")
	resume_button.text = TranslationManager.t("BUTTON_RESUME")
	settings_button.text = TranslationManager.t("BUTTON_SETTINGS")
	quit_button.text = TranslationManager.t("BUTTON_QUIT_TO_MENU")

## ========== 信号回调方法 ==========

## 语言变化回调：重新更新界面文本
func _on_language_changed(_lang: String) -> void:
	_update_text()

## 继续游戏按钮点击回调：发出继续游戏信号
func _on_resume_button_pressed() -> void:
	print("Resuming game...")
	resume_game.emit()

## 设置按钮点击回调：发出打开设置信号
func _on_settings_button_pressed() -> void:
	print("Opening settings from pause...")
	open_settings.emit()

## 返回主菜单按钮点击回调：发出返回主菜单信号
func _on_quit_button_pressed() -> void:
	print("Quitting to menu...")
	quit_to_menu.emit()