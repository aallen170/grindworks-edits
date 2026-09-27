extends MeshInstance3D

const BASE_ITEM := "res://objects/items/resources/passive/track_frame.tres"

var track: String

var resource: Item


func setup(item: Item):
	resource = item
	
	# Standard behavior
	if not resource.arbitrary_data.has('track'):
		randomize_track()
	else:
		track = resource.arbitrary_data['track']

	# Color the mesh if this is in-world (not generated for logic purposes i.e. on item application)
	if item.item_model_in_real_world(self):
		var mesh_mat: StandardMaterial3D = mesh.surface_get_material(0).duplicate(true)
		mesh_mat.albedo_color = get_color()
		set_surface_override_material(0, mesh_mat)


func modify(ui: MeshInstance3D) -> void:
	ui.set_surface_override_material(0, ui.mesh.surface_get_material(0).duplicate(true))
	ui.get_surface_override_material(0).albedo_texture = get_gag_got().icon
	ui.get_surface_override_material(0).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

# Weighted gag generation
func randomize_track() -> void:
	var hat := get_hat()
	
	if hat.is_empty():
		resource.reroll()
		return
	
	track = hat[RNG.channel(RNG.ChannelGagFrames).randi() % hat.size()]
	
	# Store the track in the item resource
	resource.arbitrary_data['track'] = track
	resource.item_description = "New %s Gag!" % track
	resource.big_description = resource.item_description

func get_color() -> Color:
	if get_track(track):
		return get_track(track).track_color
	else:
		return Color.NAVY_BLUE

func collect() -> void:
	var stats := Util.get_player().stats
	var track_size: int = get_track(track).gags.size()
	# Clamp instead of blindly incrementing: godmode (or any other source that
	# maxes gags_unlocked ahead of normal progression) can leave this already
	# at track_size, and incrementing past it corrupts the save (gags_unlocked
	# stores a raw index+1 elsewhere -- see get_gag_got()) and crashes the
	# next read of it.
	stats.gags_unlocked[track] = mini(stats.gags_unlocked[track] + 1, track_size)
	resource.item_name = get_gag_got().action_name

func get_track(track_name: String) -> Track:
	var loadout := Util.get_player().stats.character.gag_loadout
	
	for gag_track in loadout.loadout:
		if gag_track.track_name == track_name:
			return gag_track
	return null

func get_hat() -> Array[String]:
	var loadout: GagLoadout = Util.get_player().character.gag_loadout
	
	# Put all missing gags in a hat
	var hat: Array[String] = []
	for gag_track in loadout.loadout:
		var unlocked: int = Util.get_player().stats.gags_unlocked[gag_track.track_name]
		var remaining := gag_track.gags.size() - unlocked
		for i in remaining:
			hat.append(gag_track.track_name)
	
	# Remove the gags from the floor that have already been spawned
	for item: Item in ItemService.items_in_play:
		if item.arbitrary_data.has('track'):
			hat.erase(item.arbitrary_data['track'])
	
	return hat

func get_gag_got() -> ToonAttack:
	var gag_track := Util.get_player().stats.character.gag_loadout.get_track_of_name(track)
	# Clamp the index defensively: an out-of-range gags_unlocked value here
	# (e.g. from an already-corrupted save, or a mod/debug tool that doesn't
	# go through collect()'s clamp) should not crash the game.
	var index: int = clampi(Util.get_player().stats.gags_unlocked[track] - 1, 0, gag_track.gags.size() - 1)
	return gag_track.gags[index]
