extends Object

# TGM-6: Endless Mode hook for elevator_scene.gd
#
# Vanilla behavior: at Util.floor_number == 5, get_next_floors() sends the
# player into a single fixed final-boss floor (level_range 10-16) instead of
# offering 3 random floor choices; the run ends after that boss is beaten
# (see penthouse_boss.hooks.gd).
#
# Endless behavior: cycle BOSS_CYCLE_LENGTH floors of normal play followed by
# one boss floor, repeating forever. floor_number == 5 reproduces vanilla's
# exact first boss encounter (10-16 range) as the cycle's baseline.
#
# Boss level_range scaling: continues the same average per-floor growth
# vanilla's own difficulty table already uses across floors 0-5 (see
# floor_variant.hooks.gd for the matching normal-floor version of this same
# curve) instead of resetting back down after each boss or blowing up
# exponentially. Keep LOW_RATE/HIGH_RATE in sync between the two files.
#
# BUG FIX (found via debug logging): chain.reference_object is typed as a
# plain Node, and assigning a bare `[final_floor]` array literal through a
# Node-typed variable goes through Godot's dynamic/untyped property setter
# instead of a statically-typed one. The vanilla `next_floors` property is
# declared as `Array[FloorVariant]`, and the untyped literal was being
# silently rejected instead of converted - next_floors stayed an empty
# array the whole time, which is why the elevator card kept showing
# null/default values no matter what final_floor actually contained.
# Casting to ElevatorScene and building an explicitly-typed array before
# assigning fixes it.

const BOSS_CYCLE_LENGTH := 6  # keep in sync with floor_variant.hooks.gd
const LOW_RATE := 1.6  # keep in sync with floor_variant.hooks.gd
const HIGH_RATE := 2.2  # keep in sync with floor_variant.hooks.gd


func is_boss_floor(floor_number: int) -> bool:
	return floor_number >= 5 and (floor_number - 5) % BOSS_CYCLE_LENGTH == 0


func _ready(chain: ModLoaderHookChain) -> void:
	chain.execute_next([])
	if is_boss_floor(Util.floor_number):
		var elevator_ui = chain.reference_object.get_node("ElevatorUI")
		elevator_ui.arrow_left.hide()
		elevator_ui.arrow_right.hide()


func get_next_floors(chain: ModLoaderHookChain) -> void:
	if is_boss_floor(Util.floor_number):
		endless_boss_floor(chain)
		return
	chain.execute_next([])


func endless_boss_floor(chain: ModLoaderHookChain) -> void:
	var elevator: ElevatorScene = chain.reference_object
	var elevator_ui = elevator.get_node("ElevatorUI")

	# elevator.FINAL_FLOOR_VARIANT is lazy-loaded by GameLoader (see
	# elevator_scene.gd's own _init comment about why it isn't preloaded
	# directly - a large dependency chain causes a lag spike). Reuse the
	# already-loaded reference instead of preloading it ourselves here.
	var final_floor: FloorVariant = elevator.FINAL_FLOOR_VARIANT.duplicate(true)

	var floors_since_first_boss: int = Util.floor_number - 5
	var low: int = 10 + roundi(LOW_RATE * floors_since_first_boss)
	var high: int = 16 + roundi(HIGH_RATE * floors_since_first_boss)
	final_floor.level_range = Vector2i(low, high)

	var typed_floors: Array[FloorVariant] = [final_floor]
	elevator.next_floors = typed_floors
	elevator_ui.floors = typed_floors
	elevator_ui.set_floor_index(0)
