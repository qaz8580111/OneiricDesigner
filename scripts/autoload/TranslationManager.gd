extends Node

signal language_changed(lang: String)

var current_language: String = "zh_CN"

var translations: Dictionary = {
	"zh_CN": {
		# 主菜单
		"MENU_TITLE": "梦境设计师",
		"MENU_SUBTITLE": "随机生成类游戏",
		"BUTTON_START_GAME": "开始游戏",
		"BUTTON_SETTINGS": "设置",
		"BUTTON_QUIT_GAME": "退出游戏",
		"VERSION": "版本",
		
		# 设置菜单
		"SETTINGS_TITLE": "设置",
		"TAB_GAMEPLAY": "游戏性",
		"TAB_AUDIO": "音频",
		"TAB_VIDEO": "视频",
		"TAB_LANGUAGE": "语言",
		"GAMEPLAY_DIFFICULTY": "难度",
		"GAMEPLAY_SHOW_FPS": "显示FPS计数器",
		"AUDIO_MASTER_VOLUME": "主音量",
		"AUDIO_MUSIC_VOLUME": "音乐音量",
		"AUDIO_SFX_VOLUME": "音效音量",
		"VIDEO_RESOLUTION": "分辨率",
		"VIDEO_FULLSCREEN": "全屏",
		"VIDEO_VSYNC": "垂直同步",
		"BUTTON_BACK": "返回",
		"BUTTON_RESET": "重置为默认",
		"BUTTON_APPLY": "应用",
		
		# 难度选项
		"DIFFICULTY_EASY": "简单",
		"DIFFICULTY_NORMAL": "普通",
		"DIFFICULTY_HARD": "困难",
		"DIFFICULTY_EXPERT": "专家",
		
		# 暂停菜单
		"PAUSED_TITLE": "暂停",
		"BUTTON_RESUME": "继续游戏",
		"BUTTON_QUIT_TO_MENU": "返回主菜单",
		
		# 游戏信息
		"GAME_SEED": "种子",
		"GAME_MODS": "模组",
		"GAME_EVENTS": "事件",
		
		# 事件
		"EVENT_TRIGGERED": "事件触发",
		"EVENT_HEAL": "治疗",
		"EVENT_DAMAGE": "伤害",
		"EVENT_TREASURE": "发现宝藏",
		"EVENT_TRAP": "触发陷阱"
	},
	"en_US": {
		# Main Menu
		"MENU_TITLE": "OneiricDesigner",
		"MENU_SUBTITLE": "Procedural Roguelike",
		"BUTTON_START_GAME": "Start Game",
		"BUTTON_SETTINGS": "Settings",
		"BUTTON_QUIT_GAME": "Quit Game",
		"VERSION": "Version",
		
		# Settings Menu
		"SETTINGS_TITLE": "Settings",
		"TAB_GAMEPLAY": "Gameplay",
		"TAB_AUDIO": "Audio",
		"TAB_VIDEO": "Video",
		"TAB_LANGUAGE": "Language",
		"GAMEPLAY_DIFFICULTY": "Difficulty",
		"GAMEPLAY_SHOW_FPS": "Show FPS Counter",
		"AUDIO_MASTER_VOLUME": "Master Volume",
		"AUDIO_MUSIC_VOLUME": "Music Volume",
		"AUDIO_SFX_VOLUME": "SFX Volume",
		"VIDEO_RESOLUTION": "Resolution",
		"VIDEO_FULLSCREEN": "Fullscreen",
		"VIDEO_VSYNC": "V-Sync",
		"BUTTON_BACK": "Back",
		"BUTTON_RESET": "Reset to Default",
		"BUTTON_APPLY": "Apply",
		
		# Difficulty Options
		"DIFFICULTY_EASY": "Easy",
		"DIFFICULTY_NORMAL": "Normal",
		"DIFFICULTY_HARD": "Hard",
		"DIFFICULTY_EXPERT": "Expert",
		
		# Pause Menu
		"PAUSED_TITLE": "Paused",
		"BUTTON_RESUME": "Resume Game",
		"BUTTON_QUIT_TO_MENU": "Quit to Menu",
		
		# Game Info
		"GAME_SEED": "Seed",
		"GAME_MODS": "Mods",
		"GAME_EVENTS": "Events",
		
		# Events
		"EVENT_TRIGGERED": "Event Triggered",
		"EVENT_HEAL": "Healing",
		"EVENT_DAMAGE": "Damage",
		"EVENT_TREASURE": "Treasure Found",
		"EVENT_TRAP": "Trap Triggered"
	}
}

func _ready() -> void:
	_load_language_setting()

func _load_language_setting() -> void:
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")
	
	if err == OK:
		set_language(config.get_value("Settings", "language", "zh_CN"))
	else:
		set_language("zh_CN")

func set_language(lang: String) -> void:
	if translations.has(lang):
		current_language = lang
		_save_language_setting()
		language_changed.emit(lang)
		print("Language changed to: ", lang)

func _save_language_setting() -> void:
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")
	
	if err == OK:
		config.set_value("Settings", "language", current_language)
		config.save("user://settings.cfg")

# 重命名为 t() 避免与 Godot 内置 tr() 冲突
func t(key: String) -> String:
	if translations.has(current_language):
		var lang_dict: Dictionary = translations[current_language]
		if lang_dict.has(key):
			return lang_dict[key]
	return key

func get_current_language() -> String:
	return current_language

func get_language_display_name(lang: String) -> String:
	match lang:
		"zh_CN":
			return "简体中文"
		"en_US":
			return "English"
		_:
			return lang
