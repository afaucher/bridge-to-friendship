extends "res://scripts/test_support/test_case.gd"

# EVERY ENEMY IS AN EnemyBody, AND GETS WHAT THAT MEANS.
#
# The shared base exists because four enemies had written the same things four
# times and one copy had already drifted: the rusher never set `floor_max_angle`,
# so it kept Godot's 45-degree default -- and a steep ramp is EXACTLY 45 degrees
# (MAX_WALK_ANGLE_DEG's own note: "a steep one, 2 units per cell, 45 deg"), the
# slope this game uses as its co-op gate. Every other body in the game stops at
# 40. Asserted as the property, because that names the fault; a rusher walking a
# ramp it should not is the symptom, and it is intermittent at a boundary.
#
# And each kind names its own corpse, which retired a table in GameWorld from
# pool to pile that had to be kept in step by hand.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const Corpse = preload("res://scripts/sim/corpse.gd")

const KINDS := {
	"res://scenes/rusher.tscn": Corpse.Kind.RUSHER,
	"res://scenes/zombie.tscn": Corpse.Kind.ZOMBIE,
	"res://scenes/skirmisher.tscn": Corpse.Kind.SKIRMISHER,
	"res://scenes/turret.tscn": Corpse.Kind.TURRET,
}

func setup(_main) -> void:
	for path in KINDS:
		var body: Node = (load(path) as PackedScene).instantiate()
		add_child(body)        # _ready runs here
		near(body.floor_max_angle, deg_to_rad(SimConfig.MAX_WALK_ANGLE_DEG), 0.0001,
			"%s stops on the same slope every other body does (%.1f deg, want %.1f)"
				% [path.get_file(), rad_to_deg(body.floor_max_angle), SimConfig.MAX_WALK_ANGLE_DEG])
		eq(body.corpse_kind(), int(KINDS[path]), "%s leaves its own kind of pile" % path.get_file())
		body.id = 7
		eq(int(body.capture_state()[0]), 7, "%s puts its id first on the wire" % path.get_file())
		body.queue_free()
	finish()
