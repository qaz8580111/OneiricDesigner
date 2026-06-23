extends Node

signal mod_loaded(mod_id: String, mod_data: Dictionary)
signal mod_failed(mod_id: String, error: String)

var loaded_mods: Dictionary = {}
var mod_directory: String = "user://mods/"

func _ready() -> void:
	print("ModLoader initialized")
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.debug_info("ModLoader 初始化", "ModLoader")
	_ensure_mod_directory()
	load_all_mods()

func _ensure_mod_directory() -> void:
	var dir: DirAccess = DirAccess.open("user://")
	if dir and not dir.dir_exists("mods"):
		dir.make_dir("mods")
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.debug_info("创建 mods 目录", "ModLoader")
		print("Created mods directory")

func load_all_mods() -> void:
	var dir: DirAccess = DirAccess.open(mod_directory)
	if not dir:
		print("Could not open mod directory")
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_warning("无法打开 mod 目录", "ModLoader")
		return
	
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.debug_info("开始加载所有 mods", "ModLoader")
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not file_name.begins_with(".") and dir.current_is_dir():
			load_mod(file_name)
		file_name = dir.get_next()
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.debug_info("已加载 %d 个 mod" % loaded_mods.size(), "ModLoader")

func load_mod(mod_id: String) -> bool:
	var mod_path: String = mod_directory.path_join(mod_id)
	var manifest_path: String = mod_path.path_join("manifest.json")
	
	if not ResourceLoader.exists(manifest_path):
		push_error("Mod '%s' has no manifest.json" % mod_id)
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_error("Mod '%s' 缺少 manifest.json" % mod_id, "ModLoader")
		mod_failed.emit(mod_id, "Missing manifest.json")
		return false
	
	var manifest_file: FileAccess = FileAccess.open(manifest_path, FileAccess.READ)
	if not manifest_file:
		push_error("Could not open manifest for mod '%s'" % mod_id)
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_error("无法打开 mod '%s' 的 manifest" % mod_id, "ModLoader")
		mod_failed.emit(mod_id, "Could not open manifest")
		return false
	
	var manifest_content: String = manifest_file.get_as_text()
	manifest_file.close()
	
	var json: JSON = JSON.new()
	var parse_result: int = json.parse(manifest_content)
	if parse_result != OK:
		push_error("Invalid JSON in manifest for mod '%s'" % mod_id)
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_error("Mod '%s' 的 manifest JSON 无效" % mod_id, "ModLoader")
		mod_failed.emit(mod_id, "Invalid JSON manifest")
		return false
	
	var mod_data: Dictionary = json.data
	mod_data["id"] = mod_id
	mod_data["path"] = mod_path
	
	loaded_mods[mod_id] = mod_data
	
	_load_mod_events(mod_path)
	_load_mod_scripts(mod_path)
	
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.runtime_info("加载 Mod: %s" % mod_id, "ModLoader")
		logger.debug_info("加载 Mod: %s, 数据: %s" % [mod_id, str(mod_data)], "ModLoader")
	print("Loaded mod: ", mod_id)
	mod_loaded.emit(mod_id, mod_data)
	return true

func _load_mod_events(mod_path: String) -> void:
	var events_path: String = mod_path.path_join("events.json")
	if not ResourceLoader.exists(events_path):
		return
	
	var events_file: FileAccess = FileAccess.open(events_path, FileAccess.READ)
	if not events_file:
		return
	
	var events_content: String = events_file.get_as_text()
	events_file.close()
	
	var json: JSON = JSON.new()
	var parse_result: int = json.parse(events_content)
	if parse_result != OK:
		push_error("Invalid events JSON in mod")
		return
	
	var events: Array = json.data
	for event_data in events:
		EventSystem.register_event(event_data)

func _load_mod_scripts(mod_path: String) -> void:
	var scripts_dir: String = mod_path.path_join("scripts")
	if not DirAccess.open(scripts_dir):
		return
	
	var dir: DirAccess = DirAccess.open(scripts_dir)
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".gd"):
			var script_path: String = scripts_dir.path_join(file_name)
			var script: Script = load(script_path)
			if script and script.has_method("_init_mod"):
				var instance: Object = script.new()
				if instance and instance.has_method("_init_mod"):
					instance._init_mod()
		file_name = dir.get_next()

func get_mod(mod_id: String) -> Dictionary:
	return loaded_mods.get(mod_id, {})

func get_all_mods() -> Dictionary:
	return loaded_mods.duplicate()

func is_mod_loaded(mod_id: String) -> bool:
	return loaded_mods.has(mod_id)
