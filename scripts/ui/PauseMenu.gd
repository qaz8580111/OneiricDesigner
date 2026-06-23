extends Control

signal resume_game()
signal open_settings()
signal quit_to_menu()

@onready var title_label: Label = $VBoxContainer/Title
@onready var resume_button: Button = $VBoxContainer/ResumeButton
@onready var settings_button: Button = $VBoxContainer/SettingsButton
@onready var quit_button: Button = $VBoxContainer/QuitButton

# 菜单导航器实例
var _navigator: MenuNavigator = MenuNavigator.new()

func _ready() -> void:
	_update_text()
	resume_button.pressed.connect(_on_resume_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	TranslationManager.language_changed.connect(_on_language_changed)

	# 添加导航器为子节点
	add_child(_navigator)
	# B键返回 = 继续游戏
	_navigator.cancel_pressed.connect(_on_resume_button_pressed)
	# 延迟一帧激活导航（等待UI布局完成）
	await get_tree().process_frame
	_navigator.activate(self)

func _exit_tree() -> void:
	_navigator.deactivate()

func _update_text() -> void:
	title_label.text = TranslationManager.t("PAUSED_TITLE")
	resume_button.text = TranslationManager.t("BUTTON_RESUME")
	settings_button.text = TranslationManager.t("BUTTON_SETTINGS")
	quit_button.text = TranslationManager.t("BUTTON_QUIT_TO_MENU")

func _on_language_changed(_lang: String) -> void:
	_update_text()

func _on_resume_button_pressed() -> void:
	print("Resuming game...")
	resume_game.emit()

func _on_settings_button_pressed() -> void:
	print("Opening settings from pause...")
	open_settings.emit()

func _on_quit_button_pressed() -> void:
	print("Quitting to menu...")
	quit_to_menu.emit()
