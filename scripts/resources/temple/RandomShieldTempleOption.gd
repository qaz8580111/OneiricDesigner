## RandomShieldTempleOption.gd - 神庙选项：随机护盾（赌博式）
## 职责：从 data/equipment/ 目录随机抽取一件护盾装备给玩家
## 赌博性：可能抽到特效护盾（毒雾/冰霜/反击，血赚），也可能抽到基础护盾
##         （比当前装备的特效护盾差，血亏）——护盾替换机制天然构成赌博
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → 扫描 data/equipment/*.tres → 过滤 ShieldEquipmentData
##         → 随机选一个 → player.equip_shield(shield_data)
## 扩展性：新增护盾只需放入 data/equipment/ 目录，本选项自动感知
class_name RandomShieldTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：随机装备一件护盾
func apply(player: Node) -> bool:
	if player == null or not player.has_method("equip_shield"):
		return false

	## 扫描装备目录，收集所有护盾数据
	var shields: Array = []
	var dir_path: String = "res://data/equipment"
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		push_warning("RandomShieldTempleOption: 无法打开装备目录 " + dir_path)
		return false

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var resource: Resource = load(dir_path + "/" + file_name)
			## 只收集护盾类型（未来新增其他装备类型时自动被过滤）
			if resource is ShieldEquipmentData:
				shields.append(resource)
		file_name = dir.get_next()
	dir.list_dir_end()

	if shields.is_empty():
		push_warning("RandomShieldTempleOption: 装备目录中没有护盾资源")
		return false

	## 随机选一件并装备（替换当前护盾）
	var random_index: int = RandomManager.randi_range(0, shields.size() - 1)
	player.equip_shield(shields[random_index])
	return true
