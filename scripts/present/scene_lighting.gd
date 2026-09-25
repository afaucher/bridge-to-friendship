extends RefCounted

# The sky and the sun for a bridge level.
#
# Built in CODE rather than as a .tscn on purpose: a directional light is defined
# by its ROTATION, and a .tscn stores a Transform3D basis -- which means
# hand-writing a rotation matrix into a text file and hoping. `rotation_degrees`
# here says what it means and can be adjusted by reading it.
#
# The gym carries its own lighting because it is a self-contained level scene. A
# bridge is assembled from .seg files, which describe structure and nothing else,
# so its lighting has to come from somewhere -- this is that somewhere.

static func build() -> Node3D:
	var root := Node3D.new()
	root.name = "Lighting"
	root.add_child(_sky())
	root.add_child(_sun())
	return root

static func _sky() -> WorldEnvironment:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.32, 0.50, 0.78)
	sky_material.sky_horizon_color = Color(0.74, 0.80, 0.84)
	sky_material.ground_horizon_color = Color(0.52, 0.48, 0.44)
	sky_material.ground_bottom_color = Color(0.16, 0.15, 0.14)

	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	# Ambient from the sky, and a generous amount of it. The bridge is a
	# structure in open air with nothing around it to bounce light back, so
	# without this every surface facing away from the sun goes near-black --
	# including the sides of the pillars and the inside faces of the parapets,
	# which are exactly the things a player needs to read.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.7
	env.ambient_light_energy = 1.0

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	return world_env

static func _sun() -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"

	# Deliberately NOT overhead. A light straight down flattens the checkerboard
	# into one tone and takes away the thing it exists to provide -- the deck has
	# to cast enough shadow off pillars and parapets to read as having depth,
	# and the checker has to stay legible under it. Yawed off-axis so shadows
	# fall diagonally rather than along the cell grid, where they would line up
	# with the checker and cancel it out.
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true

	# The bridge recedes a long way up-screen from a 45-degree camera; the
	# default shadow distance runs out well inside the visible deck and the far
	# half would simply stop casting.
	sun.directional_shadow_max_distance = 220.0
	return sun
