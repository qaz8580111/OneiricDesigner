## RandomSkillTempleOption.gd - 神庙选项：随机技能（三选一式）
## 职责：打开与"经验升级/技能书拾取"完全相同的三选一面板，由玩家自选一条可用词条
## 设计意图：全游戏获得技能的唯一途径收敛为三选一面板（升级/技能书/神庙同源），
##           杜绝"随机直接塞一个技能"的失控感；候选由 _roll_three_upgrades 加权抽取，
##           满级词条自动被过滤（不会出现选到已满级技能的浪费），
##           词条全部满级时面板静默跳过（不弹空面板）
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → UpgradeManager.open_level_up_choice() → _roll_three_upgrades()
##         → LevelUpPanel 玩家自选 → apply_upgrade() → 属性/特效生效
class_name RandomSkillTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：打开三选一面板（旧实现为随机抽1条直接 apply_upgrade、不开面板，已按需求废弃）
func apply(_player: Node) -> bool:
	## 打开三选一选择面板（内部自带 is_choosing 锁与 _pending_upgrades 排队：
	## 与经验升级/技能书同时触发时依次弹出，不会叠加多个面板）
	UpgradeManager.open_level_up_choice()
	## 面板已打开/排队即视为选项生效（返回值供神庙面板关闭自身等流程使用）
	return true
