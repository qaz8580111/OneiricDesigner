## IconLibrary.gd - 图标资源统一加载库（静态工具类，无需实例化）
## 职责：按"文件名契约"自动加载技能/装备/敌人掉落物图标，UI 层只管要图标、不关心路径组织
## 命名契约（新增图标零代码的核心）：
##   路径 = assets/art/ui/icons/<目录名>/icon_<资源id>.png
##   目录名由类型/稀有度映射：普通=白色普通、稀有=蓝色稀有、史诗=紫色史诗、
##   护盾装备=灰色护盾、敌人掉落物=敌人掉落（掉落物 item_id 经 DROP_ICON_MAP 映射到文件名）
## 使用场景：PauseMenu 装备/背包面板（装备与词条图标）、GameHUD（buff图标/护盾显示）、PickUp（掉落物贴图）
## 数据流：调用方传入 upgrade_id/shield_id/item_id → 本类拼路径 → load() → 缓存后返回
## 设计意图：
##   1. 约定优于配置：只要 png 按 icon_<id>.png 命名放进对应目录，UI 自动显示，无需改任何 .tres/代码
##   2. 容错兜底：图标缺失时返回 null，调用方回退到原有文字/色块显示（游戏永不因缺图报错）
##   3. 双缓存：正缓存存已加载纹理；负缓存记录"确认不存在"的路径，
##      避免每次刷新都重复 file_exists 磁盘查询（buff栏升级时会高频刷新）
class_name IconLibrary
extends RefCounted

## ========== 路径契约常量 ==========

## 图标根目录
const BASE_PATH: String = "res://assets/art/ui/icons"

## 稀有度枚举值 → 图标子目录名（目录改名需同步此处）
## 键与 UpgradeData.Rarity 枚举对齐：0=普通 1=稀有 2=史诗
const RARITY_FOLDERS: Dictionary = {
	0: "白色普通",
	1: "蓝色稀有",
	2: "紫色史诗",
}

## 护盾装备图标子目录名（装备无稀有度维度，独立目录）
const SHIELD_FOLDER: String = "灰色护盾"

## 敌人掉落物图标子目录名（碎片/血包/装备掉落等掉落物）
const DROP_FOLDER: String = "敌人掉落"

## 掉落物 item_id → 图标文件名（不含扩展名）映射表
## 设计意图：item_id 与美术文件名按英文语义对应但不完全同名（如 fragment_small → icon_fragments_small，
##           精英怪变体 elite_* 共用同一张大图），故用映射表做"按英文自动适配"的唯一登记点；
##           新增掉落物种类时：美术放 icon_xxx.png 到"敌人掉落"目录 + 本表加一行，零代码改动
## 取值来源：Enemy._generate_default_drops() 与 GameWorld/StageDirector 动态生成的 item_id
const DROP_ICON_MAP: Dictionary = {
	## 梦境碎片：小碎片用小图；中碎片/精英碎片/Boss碎片共用大图（大小掉落从图标尺寸上也能区分）
	"fragment_small": "icon_fragments_small",
	"fragment_medium": "icon_fragments_big",
	"elite_fragment": "icon_fragments_big",
	"boss_fragment": "icon_fragments_big",
	## 装备掉落：四大成长维度统一聚合为装备后，地面掉落物统一使用"技能"图标（icon_skill）
	## 设计意图：掉落物只需告知玩家"这是一件装备"（不暴露具体槽位/稀有度，保留惊喜感），
	##           具体词条/特效/护盾/主动技能由拾取入包后在背包/装备面板中查看
	"equipment_drop": "icon_skill",
}

## 装备槽位 → 兜底代表图标文件名（不含扩展名）
## 设计意图：装备实例本身不存图标，get_equipment_icon 会先尝试"护盾蓝图/首条词条"解析，
##           全都解析不出时才按槽位给一张"代表图标"，保证任何装备在 UI 上都有图可显示
## 键与 EquipmentData.Slot 枚举对齐：0=武器 1=护甲 2=鞋子 3=盾牌 4=戒指 5=法宝
const SLOT_ICON_FILES: Dictionary = {
	0: "icon_upg_damage",       ## 武器 → 伤害
	1: "icon_upg_max_hp",       ## 护甲 → 血量上限
	2: "icon_upg_move_speed",   ## 鞋子 → 移动速度
	3: "icon_shield_basic",     ## 盾牌 → 基础护盾（该图在"灰色护盾"目录）
	4: "icon_upg_fire_rate",    ## 戒指 → 射速
	5: "icon_upg_random",       ## 法宝 → 随机
}

## ========== 静态缓存 ==========

## 正缓存：路径 → 已加载的 Texture2D（load()本身有引擎级缓存，此处主要省路径拼接与查询）
static var _cache: Dictionary = {}

## 负缓存：确认不存在的路径集合（值为 true），命中直接返回 null 不再查盘
static var _miss_cache: Dictionary = {}

## ========== 对外接口 ==========

## 获取升级词条图标（装备/背包面板与状态面板的词条图标共用）
## 参数：upgrade_id - 词条唯一标识（如 "upg_damage"）；rarity - 稀有度枚举值（决定子目录）
## 返回：图标纹理；图标缺失或 id 为空时返回 null（调用方自行回退文字显示）
## 加载策略：先按稀有度目录找；该目录缺失（磁盘上尚未做"蓝色稀有/紫色史诗"分目录）时，
##           回退到"白色普通"目录，保证 RARE/EPIC 装备的词条图标不会因缺目录而全部空白
static func get_upgrade_icon(upgrade_id: String, rarity: int) -> Texture2D:
	## 空id直接失败（新词条未配id时不炸）
	if upgrade_id.is_empty():
		return null
	## 按稀有度映射子目录（未知稀有度回退普通目录，保证总有合法路径）
	var folder: String = RARITY_FOLDERS.get(rarity, RARITY_FOLDERS[0])
	var tex: Texture2D = _load_icon("%s/%s/icon_%s.png" % [BASE_PATH, folder, upgrade_id])
	if tex != null:
		return tex
	## 稀有度目录 miss：回退白色普通目录（仅当当前目录非普通目录时才多查一次）
	var common_folder: String = RARITY_FOLDERS[0]
	if folder != common_folder:
		return _load_icon("%s/%s/icon_%s.png" % [BASE_PATH, common_folder, upgrade_id])
	return null

## 获取护盾装备图标（HUD护盾栏 / 暂停菜单装备展示用，不再用于地面掉落物）
## 参数：shield_id - 护盾唯一标识（如 "shield_basic"）
## 返回：图标纹理；缺失或 id 为空时返回 null（调用方回退占位色块）
static func get_shield_icon(shield_id: String) -> Texture2D:
	if shield_id.is_empty():
		return null
	return _load_icon("%s/%s/icon_%s.png" % [BASE_PATH, SHIELD_FOLDER, shield_id])

## 获取敌人掉落物图标（碎片/血包/装备掉落贴图用）
## 参数：item_id - 掉落物唯一标识（DropItem.item_id，如 "fragment_small"）
## 返回：图标纹理；id 未登记映射或图标文件缺失时返回 null（调用方回退占位色块）
static func get_drop_icon(item_id: String) -> Texture2D:
	if item_id.is_empty():
		return null
	## 经映射表把 item_id 翻译成美术图标文件名（未登记的 id 视为无图标，如预留的 WEAPON/ITEM 类）
	var icon_name: String = DROP_ICON_MAP.get(item_id, "")
	if icon_name.is_empty():
		return null
	return _load_icon("%s/%s/%s.png" % [BASE_PATH, DROP_FOLDER, icon_name])

## 获取子弹特效图标（装备/背包面板展示特效词条用）
## 参数：effect_id - 特效唯一标识（BulletEffect.effect_id，不含前缀，如 "lifesteal"）
##       rarity - 稀有度枚举值（决定图标子目录）
## 返回：图标纹理；缺失或 id 为空时返回 null
## 说明：特效图标复用属性词条图标（美术按 icon_upg_<effect_id>.png 命名），故此处统一补 "upg_" 前缀
static func get_effect_icon(effect_id: String, rarity: int) -> Texture2D:
	if effect_id.is_empty():
		return null
	return get_upgrade_icon("upg_" + effect_id, rarity)

## 获取装备槽位兜底图标（装备自身/词条/护盾都解析不出图标时的最后一级回退）
## 参数：slot - 槽位枚举值（EquipmentData.Slot）；rarity - 稀有度枚举值（决定首选子目录）
## 返回：图标纹理；SLOT_ICON_FILES 未登记的槽位返回 null
## 加载策略：依次尝试 稀有度目录 → 白色普通 → 灰色护盾 → 敌人掉落
##           （原因：稀有度分目录多数不存在、盾牌代表图标 icon_shield_basic 只在后两个目录，
##            追加"白色普通"可覆盖 RARE/EPIC 装备槽位兜底图标，避免空槽/高稀有度装备无图）
static func get_slot_icon(slot: int, rarity: int = 0) -> Texture2D:
	var file_name: String = SLOT_ICON_FILES.get(slot, "")
	if file_name.is_empty():
		return null
	## 候选目录顺序：稀有度目录 → 白色普通 → 灰色护盾 → 敌人掉落
	var folders: Array[String] = [
		String(RARITY_FOLDERS.get(rarity, RARITY_FOLDERS[0])),
		String(RARITY_FOLDERS[0]),
		SHIELD_FOLDER,
		DROP_FOLDER,
	]
	for folder: String in folders:
		var tex: Texture2D = _load_icon("%s/%s/%s.png" % [BASE_PATH, folder, file_name])
		if tex != null:
			return tex
	return null

## 获取主动技能图标（主界面 HUD 技能栏 / 状态面板主动技能行）
## 返回：技能图标纹理；图标缺失时返回 null（调用方回退占位色块/文字）
## 说明：主动技能暂无专属图标目录，统一复用"敌人掉落"目录下的 icon_skill.png 作为技能标识图
static func get_active_skill_icon() -> Texture2D:
	return _load_icon("%s/%s/icon_skill.png" % [BASE_PATH, DROP_FOLDER])

## 获取一件装备的展示图标（装备/背包面板统一入口）
## 参数：data - EquipmentData 实例
## 返回：图标纹理；全链路都解析不出时返回 null（调用方回退色块/文字）
## 解析优先级（尽量展示"这件装备最独特的地方"）：
##   1. 装备自带 icon（美术若为某件装备单独配图，则优先级最高）
##   2. 盾牌槽：护盾蓝图图标（体现护盾种类）
##   3. 首条"带来源 id"的基础属性词条图标（体现主要属性）
##   4. 首个子弹特效图标（体现特效）
##   5. 按槽位兜底代表图标（保证任何装备都有图可显示）
static func get_equipment_icon(data: EquipmentData) -> Texture2D:
	if data == null:
		return null
	## 1. 装备自带图标
	if data.icon != null:
		return data.icon
	## 2. 盾牌槽：护盾蓝图图标
	if data.slot == EquipmentData.Slot.SHIELD and data.shield_data != null:
		var shield_icon: Texture2D = get_shield_icon(data.shield_data.shield_id)
		if shield_icon != null:
			return shield_icon
	## 3. 首条带来源 id 的基础属性词条图标
	for affix: EquipmentAffix in data.affixes:
		if affix == null or affix.source_id.is_empty():
			continue
		var affix_icon: Texture2D = get_upgrade_icon(affix.source_id, data.rarity)
		if affix_icon != null:
			return affix_icon
	## 4. 首个子弹特效图标
	for effect: BulletEffect in data.bullet_effects:
		if effect == null:
			continue
		var effect_icon: Texture2D = get_effect_icon(effect.effect_id, data.rarity)
		if effect_icon != null:
			return effect_icon
	## 5. 按槽位兜底
	return get_slot_icon(data.slot, data.rarity)

## ========== 内部方法 ==========

## 统一加载入口：正/负缓存 + 文件存在性检查 + load + Image兜底
## 参数：path - 完整 res:// 图标路径
## 返回：纹理或 null
## 加载策略（两层兜底）：
##   1. 先走 Godot 的 load()（依赖 .ctex 导入产物，引擎级缓存、GPU 友好）
##   2. load 失败时用 Image.load() 直接读 PNG 像素数据 → ImageTexture.create_from_image()
##      （绕开导入链路，适合 .import/.ctex 失步的紧急修复；性能略低但能跑）
static func _load_icon(path: String) -> Texture2D:
	## 正缓存命中：直接返回（零查询开销）
	if _cache.has(path):
		return _cache[path]
	## 负缓存命中：已知不存在，直接返回 null（避免高频刷新重复查盘）
	if _miss_cache.has(path):
		return null
	## 文件不存在：记入负缓存（某词条没做图是常态，只查一次盘）
	if not FileAccess.file_exists(path):
		_miss_cache[path] = true
		print("[IconLibrary] MISS (file_not_found): ", path)
		return null
	## 第一层：Godot 标准 load() 依赖 .ctex 导入产物
	var tex: Texture2D = load(path) as Texture2D
	if tex != null:
		_cache[path] = tex
		return tex
	## 第二层兜底：直接从 PNG 像素数据构造纹理（绕过导入链路）
	## 适用场景：.import/.ctex 失步或完全缺失时，确保掉落物能显示图标而不是色块
	var img: Image = Image.new()
	var err: Error = img.load(path)
	if err == OK and img.get_data() != null:
		## 确保格式为 RGBA8（ImageTexture 要求有 alpha 通道才能正常透明渲染）
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		tex = ImageTexture.create_from_image(img)
		if tex != null:
			_cache[path] = tex
			print("[IconLibrary] FALLBACK Image.load() OK: ", path, " size=", img.get_width(), "x", img.get_height())
			return tex
	## 彻底失败：记入负缓存，打印诊断日志便于排查 PNG 格式问题
	_miss_cache[path] = true
	print("[IconLibrary] FAIL (load + Image.load both null): ", path, " Image.load err=", err)
	return tex
