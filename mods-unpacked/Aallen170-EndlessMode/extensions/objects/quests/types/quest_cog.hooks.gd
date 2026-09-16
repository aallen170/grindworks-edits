extends Object

# TGM-11 follow-up (crash after boss loop): reported after the ToonTask
# carry-through fix - rerolling or completing a ToonTask worked fine before
# and during the first boss fight, but crashed the moment it happened on the
# floor *after* choosing to keep going.
#
# Root cause: QuestCog.randomize_objective() (run every time a quest is
# rerolled or completed - see quest_scroll.gd's reset_quest()) indexes
# FloorVariant.LEVEL_RANGES directly by Util.floor_number:
#
#   var level_ranges := FloorVariant.LEVEL_RANGES
#   var floor_num: int = max(Util.floor_number, 0)
#   var minimum_level: int = mini(0, level_ranges[floor_num][0] - 1)
#   var maximum_level: int = mini(7, level_ranges[floor_num][1] - 1)
#
# LEVEL_RANGES is a Dictionary[int, Array] with only keys 0-5 (vanilla never
# runs a normal floor past floor_number 4, since floor 5 is the final boss
# and the run ends there). Endless Mode's loop-back bumps Util.floor_number
# past 5 forever, so the very first reroll/complete after a boss loop looks
# up a key that doesn't exist - level_ranges[floor_num] returns null, and
# `null[0]` is an invalid get index. This is the same class of bug TGM-9
# already fixed once for FloorVariant.get_calculated_level_range() (see
# floor_variant.hooks.gd) - randomize_objective() just never got the same
# treatment because vanilla has no reason to call it past floor 5.
#
# Unlike the normal-floor/boss-floor difficulty curves, this doesn't need a
# growing formula of its own: mini(0, ...) always yields 0 for minimum_level
# regardless of which table entry is looked up, and mini(7, ...) already
# clamps maximum_level to a flat 7 for every floor from 3 onward. So looking
# up any floor >= 5 always produces the exact same (0, 7) result vanilla's
# own math already converges to - clamping the lookup key to 5 changes
# nothing about quest difficulty, it just avoids indexing a key that isn't
# there.
#
# Fix: reimplement randomize_objective() (can't hook just the one line
# through the chain system) with floor_num clamped to LEVEL_RANGES' valid
# range. Keep in sync with quest_cog.gd if vanilla ever changes this
# function.

func randomize_objective(chain: ModLoaderHookChain) -> void:
	var quest: QuestCog = chain.reference_object

	quest.quota = RNG.channel(RNG.ChannelQuests).randi_range(QuestCog.OBJECTIVE_RANGE.x, QuestCog.OBJECTIVE_RANGE.y)
	var quotaf := float(quest.quota)

	var quest_type = RNG.channel(RNG.ChannelCogQuestTypes).randi() % 3
	if quest_type == 1 and quest.prev_quest_roll == 1:
		quest_type += 1 * RNG.channel(RNG.ChannelCogQuestTypes).pick_random([-1, 1])

	var level_ranges := FloorVariant.LEVEL_RANGES
	# Only change from vanilla: clamp to LEVEL_RANGES' valid keys (0-5)
	# instead of indexing Util.floor_number directly.
	var floor_num: int = mini(maxi(Util.floor_number, 0), 5)

	var minimum_level: int = mini(0, level_ranges[floor_num][0] - 1)
	var maximum_level: int = mini(7, level_ranges[floor_num][1] - 1)
	quest.department = RNG.channel(RNG.ChannelCogQuestTypes).randi() % (CogDNA.CogDept.keys().size() - 1) as CogDNA.CogDept

	# 33% chance of department specific
	if quest_type == 0:
		quest.department = CogDNA.CogDept.NULL
	elif quest_type == 1:
		var cog_pool: CogPool
		match quest.department:
			CogDNA.CogDept.SELL:
				cog_pool = load('res://objects/cog/presets/pools/sellbot.tres')
			CogDNA.CogDept.CASH:
				cog_pool = load('res://objects/cog/presets/pools/cashbot.tres')
			CogDNA.CogDept.LAW:
				cog_pool = load('res://objects/cog/presets/pools/lawbot.tres')
			CogDNA.CogDept.BOSS:
				cog_pool = load('res://objects/cog/presets/pools/bossbot.tres')
		quest.specific_cog = cog_pool.cogs[RNG.channel(RNG.ChannelCogQuestTypes).randi_range(minimum_level, maximum_level)]
		quest.department = CogDNA.CogDept.NULL

	# Reduce quotas for more specific quest types
	if not quest.department == CogDNA.CogDept.NULL:
		quotaf /= 2.0
	elif quest.specific_cog:
		quotaf /= 4.0

	# Level minimum objectives
	if RNG.channel(RNG.ChannelCogQuestTypes).randi() % 3 == 0:
		if quest.specific_cog:
			quest.min_level = RNG.channel(RNG.ChannelCogQuestTypes).randi_range(quest.specific_cog.level_low + 1, quest.specific_cog.level_low + 3)
			if quest.min_level > quest.specific_cog.level_high or quest.min_level > maximum_level:
				quest.min_level = 1
		else:
			quest.min_level = RNG.channel(RNG.ChannelCogQuestTypes).randi_range(minimum_level, maximum_level)

	if quest.min_level > 1:
		quotaf /= maxf(quest.min_level / 4.0, 1.25)

	quest.quota = int(round(quotaf))
