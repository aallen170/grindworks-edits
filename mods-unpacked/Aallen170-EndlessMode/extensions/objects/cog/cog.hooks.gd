extends Object

# TGM-9: Endless Mode hook for cog.gd's roll_for_level()
#
# Root cause (confirmed): scenes/final_boss/penthouse_boss.gd is a bare
# Node3D, not a GameFloor - so outside a real floor, Util.floor_manager is
# stale/invalid. Cog.roll_for_level() checks is_instance_valid(Util.floor_manager)
# first and, when that's false, falls back to the Cog's own DNA-defined
# level_low/level_high. Both boss presets (whistleblower.tres, union_buster.tres)
# hardcode level_low = level_high = 20 with health_mod = 6.493, which works out
# to max_hp = (20+1)*(20+2)*6.493 = ~3002 - a fixed level/HP no matter which
# boss encounter you're on. That's the flat "3000 HP every time" Andrew saw.
#
# This same fallback also silently defeats fill_elevator()'s mid-fight
# reinforcement cogs: penthouse_boss.gd sets cog.custom_level_range to a
# hardcoded Vector2i(10, 16) (COG_LEVEL_RANGE) right before add_child(), but
# roll_for_level() unconditionally recomputes custom_level_range itself the
# instant the Cog enters the tree (same is_instance_valid(Util.floor_manager)
# check, same DNA fallback) - so that pre-set value never actually took
# effect on its own; it only happened to look right because floor 5's
# (floors_since_first_boss == 0) computed range collapsed to the same 10-16.
#
# TGM-9 follow-up (2026-09-13, after first playtest): the original version of
# this fix applied ONE curve to every boss-floor Cog, which incorrectly
# flattened floor 5's real boss (whistleblower/union_buster) down to a random
# 10-16 instead of leaving it at vanilla's flat level 20/~3002 HP, while every
# later boss floor scaled up from that same wrong 10-16 baseline instead of
# from 20. Fix: tell main boss cogs apart from fill_elevator()'s reinforcement
# cogs by the custom_level_range fill_elevator() already stamped on them
# (Vector2i(10, 16), same as penthouse_boss.gd's COG_LEVEL_RANGE) *before*
# add_child() - Cog's own default is Vector2i(1, 12), so a real boss cog will
# never match that on its own. Each kind then grows from its own correct
# baseline (20 for main bosses, 10-16 for reinforcements) using the same
# per-floor rate normal floors use. Because the rate is added on top of the
# baseline, floor 5 (floors_since_first_boss == 0) collapses back to exactly
# the vanilla values for both kinds automatically - no separate "is this the
# first boss" branch needed.

const LOW_RATE := 1.6  # keep in sync with elevator_scene.hooks.gd / floor_variant.hooks.gd
const HIGH_RATE := 2.2  # keep in sync with elevator_scene.hooks.gd / floor_variant.hooks.gd
const REINFORCEMENT_LEVEL_RANGE := Vector2i(10, 16)  # keep in sync with penthouse_boss.gd's COG_LEVEL_RANGE


func roll_for_level(chain: ModLoaderHookChain) -> void:
	var cog: Cog = chain.reference_object

	if cog.level == 0 and Util.floor_number >= 5 and not is_instance_valid(Util.floor_manager):
		var floors_since_first_boss: int = Util.floor_number - 5
		var is_reinforcement: bool = cog.custom_level_range == REINFORCEMENT_LEVEL_RANGE

		var base_low: int = 10 if is_reinforcement else 20
		var base_high: int = 16 if is_reinforcement else 20

		var low: int = base_low + roundi(LOW_RATE * floors_since_first_boss)
		var high: int = base_high + roundi(HIGH_RATE * floors_since_first_boss)
		cog.custom_level_range = Vector2i(low, high)
		cog.level = RNG.channel(RNG.ChannelCogLevels).randi_range(low, high)
		# Same "allow cogs higher/lower than the floor intends" behavior vanilla has.
		if not signi(cog.level_range_offset) == 0:
			cog.level = cog.custom_level_range.y + cog.level_range_offset
		return

	chain.execute_next([])
