extends Node

signal event_triggered(event_data: Dictionary)
signal event_registered(event_id: String)

var registered_events: Dictionary = {}
var event_history: Array = []

func _ready() -> void:
	print("EventSystem initialized")
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.debug_info("EventSystem 初始化", "EventSystem")
	load_builtin_events()

func load_builtin_events() -> void:
	var builtin_events: Array = [
		{
			"id": "heal_small",
			"name": "Small Heal",
			"description": "Heals a small amount of health",
			"weight": 10,
			"type": "positive",
			"effects": { "heal": 20 }
		},
		{
			"id": "damage_small",
			"name": "Small Damage",
			"description": "Takes a small amount of damage",
			"weight": 10,
			"type": "negative",
			"effects": { "damage": 15 }
		},
		{
			"id": "treasure",
			"name": "Find Treasure",
			"description": "You found some treasure!",
			"weight": 5,
			"type": "positive",
			"effects": { "gold": 50 }
		},
		{
			"id": "trap",
			"name": "Spring Trap",
			"description": "You triggered a trap!",
			"weight": 7,
			"type": "negative",
			"effects": { "damage": 30 }
		}
	]
	
	for event_data in builtin_events:
		register_event(event_data)

func register_event(event_data: Dictionary) -> void:
	if not event_data.has("id"):
		push_error("Event must have an 'id' field!")
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_error("事件缺少 id 字段", "EventSystem")
		return
	
	var event_id: String = event_data["id"]
	if registered_events.has(event_id):
		push_warning("Event with id '%s' already registered. Overwriting." % event_id)
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_warning("事件 id '%s' 已存在，覆盖" % event_id, "EventSystem")
	
	registered_events[event_id] = event_data
	event_registered.emit(event_id)
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.debug_info("注册事件: %s" % event_id, "EventSystem")
	print("Registered event: ", event_id)

func unregister_event(event_id: String) -> void:
	if registered_events.has(event_id):
		registered_events.erase(event_id)
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.debug_info("注销事件: %s" % event_id, "EventSystem")
		print("Unregistered event: ", event_id)

func get_random_event() -> Dictionary:
	if registered_events.is_empty():
		return {}
	
	var weighted_events: Array = []
	for event_id in registered_events:
		var event: Dictionary = registered_events[event_id]
		var weight: int = event.get("weight", 1)
		for _i in range(weight):
			weighted_events.append(event)
	
	return RandomManager.rand_element(weighted_events)

func trigger_event(event_id: String = "", event_data: Dictionary = {}) -> Dictionary:
	var final_event: Dictionary = {}
	
	if event_id != "" and registered_events.has(event_id):
		final_event = registered_events[event_id].duplicate()
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.debug_info("触发指定事件: %s" % event_id, "EventSystem")
	elif event_data.is_empty():
		final_event = get_random_event()
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.debug_info("触发随机事件", "EventSystem")
	else:
		final_event = event_data.duplicate()
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.debug_info("触发自定义事件", "EventSystem")
	
	if not final_event.is_empty():
		final_event["timestamp"] = Time.get_ticks_msec()
		event_history.append(final_event)
		event_triggered.emit(final_event)
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_info("事件触发: %s" % final_event.get("name", "Unknown"), "EventSystem")
		print("Event triggered: ", final_event.get("name", "Unknown"))
	
	return final_event

func get_event(event_id: String) -> Dictionary:
	return registered_events.get(event_id, {})

func get_all_events() -> Dictionary:
	return registered_events.duplicate()

func clear_event_history() -> void:
	event_history.clear()
