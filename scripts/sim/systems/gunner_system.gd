extends "res://scripts/sim/systems/enemy_pool.gd"

# GUNNERS: skirmishers and turrets, everything that SHOOTS. Placed by the level
# (never woken by a trigger), so the host drains the grid's authored cells and
# spawns them where the terrain says.

const GunnerBody = preload("res://scripts/sim/actors/gunner_body.gd")
const SkirmisherScene = preload("res://scenes/skirmisher.tscn")
const TurretScene = preload("res://scenes/turret.tscn")

# How far above its origin a gunner looks from, and fires from.
const EYE := 0.25

func _init() -> void:
	pool_name = "gunners"
	section_name = "gunners"
	root_name = "Gunners"
	node_prefix = "Gunner"

# THE KIND PICKS THE SCENE AND NOTHING ELSE. `kind` is not assigned onto the body
# afterwards -- each script sets its own in _init, so the scene is the single
# source of truth and a scene wired to the wrong script cannot quietly report
# itself as the other thing over the wire.
func _scene_for(kind: int) -> PackedScene:
	return TurretScene if kind == GunnerBody.Kind.TURRET else SkirmisherScene

func _build_for(entry: Array) -> Node:
	var gunner: Node = _scene_for(int(entry[1])).instantiate()
	gunner.world = world
	gunner.position = entry[2]
	return gunner

func spawn(at: Vector3, kind: int) -> Node:
	var gunner: Node = _scene_for(kind).instantiate()
	gunner.world = world
	add(gunner)
	gunner.position = at
	return gunner

func host_tick() -> void:
	if world.grid != null:
		for entry in world.grid.take_authored_gunner_cells():
			spawn(world.grid.cell_surface_world(entry[0]) + Vector3(0.0, 1.0, 0.0),
				int(entry[1]))
	_step_each(_step_gunner)

func _step_gunner(gunner: Node) -> void:
	# A TURRET SHATTERS TOO: `corpse_kind` answers per kind, and a turret is a
	# tapered base, a ring and a gun barrel. Bolted down in life, and no less
	# breakable for it. Culled behind the party as well as when spent.
	if gunner.is_spent() or gunner.position.z > world._trailing_edge_z():
		retire(gunner)
		return

	# LINE OF SIGHT GATES BOTH HALVES, and for a gunner it matters more than it
	# does for a rusher. A rusher with no sight stands still, which is merely
	# wasteful; a GUN that fired through a pillar would have no counter-play at
	# all, and cover is the whole answer to these.
	var target: Node = nearest_visible(gunner, EYE)
	gunner.step(target)
	if target == null:
		return
	var range_to: float = gunner.position.distance_to(target.position)
	# The target goes in as well as the distance: a turret also has to be able to
	# BEAR on it, and that is a question about angle that only the turret can
	# answer.
	if gunner.wants_to_fire(range_to, target):
		gunner.note_fired()
		world._spawn_round(gunner.muzzle(),
			world._spread((target.global_position + Vector3(0.0, EYE, 0.0) - gunner.muzzle()).normalized()),
			0, gunner.get_rid())
