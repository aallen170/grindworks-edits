extends Object

# TGM-6: Endless Mode hook for floor_variant.gd
#
# Vanilla behavior: randomize_details() sets floor_difficulty = Util.floor_number + 1,
# then looks it up in the LEVEL_RANGES table (keys 0-5, covering floor_number 0-4).
# Vanilla never runs a normal floor with floor_number >= 5, since floor 5 sends the
# player to the final boss and the run ends there - so the "difficulty out of table"
# branch was only ever meant as a failsafe:
#
#   func get_calculated_level_range(_difficulty: int) -> Vector2i:
#       var base_range := Vector2i(LEVEL_RANGES[5][0], LEVEL_RANGES[5][1])
#       base_range *= (Util.floor_number ** Globals.floor_difficulty_increase)
#       return base_range
#
# (the source comment above it literally says "I will not be testing how well
# balanced this is - you modders can do that one yourselves"). With
# floor_difficulty_increase = 1/3, this still climbs fast: by floor_number 10 the
# level range is already ~19-32, well past the floor-4/boss range (8-16) the
# player has actually built up for - hence getting flattened right after the
# first boss.
#
# Endless behavior loops floor_number past 5 forever for every batch of normal
# floors after each boss. Rather than resetting back down to an easy floor-0
# difficulty each cycle (which underscales - the player's stats/loot have kept
# climbing the whole run) or using vanilla's exploding failsafe, this continues
# the SAME average per-floor growth vanilla's own table already uses across
# floors 0-5 (roughly +1.6 to the low end and +2.2 to the high end per floor)
# indefinitely past floor 5. Boss floors sit on this same curve too (see
# elevator_scene.hooks.gd's endless_boss_floor) - keep LOW_RATE/HIGH_RATE in
# sync between the two files.

const LOW_RATE := 1.6  # keep in sync with elevator_scene.hooks.gd
const HIGH_RATE := 2.2  # keep in sync with elevator_scene.hooks.gd


func get_calculated_level_range(chain: ModLoaderHookChain, _difficulty: int) -> Vector2i:
	var variant: FloorVariant = chain.reference_object

	var floors_since_first_boss: int = Util.floor_number - 5
	var low: int = 10 + roundi(LOW_RATE * floors_since_first_boss)
	var high: int = 16 + roundi(HIGH_RATE * floors_since_first_boss)

	# floor_difficulty just drives the elevator card's danger-star meter past
	# this point (a fixed-size row of stars) - max it out rather than leaving
	# it at the ever-climbing (and meaningless past 5) raw floor_number + 1.
	variant.floor_difficulty = 5

	return Vector2i(low, high)
