extends "res://scripts/test_support/test_case.gd"

# EVERY SPECIAL HAS ONE COMPLETE ROW, AND THE ROW NAMES REAL THINGS.
#
# items/weapon_defs.gd replaced five tables and nine step functions. The failure
# it exists to prevent is a kind that one of them forgot -- which is silent: a
# special with no mesh is an invisible pickup, one with no ammo arrives spent and
# is destroyed on the tick it is taken, one with no trigger does nothing. So:
#
#   1. EVERY KIND HAS A ROW, and every row is a kind -- both directions.
#   2. EVERY ROW IS COMPLETE: a name, a magazine, a trigger, and for a HOLD
#      weapon an interval and something to fire.
#   3. THE MESH IT NAMES IS IN special.tscn, and applying the look shows exactly
#      that one mesh -- the check the four-kinds-share-"Body" bug needed.

const WeaponDefs = preload("res://scripts/sim/items/weapon_defs.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const SpecialScene = preload("res://scenes/special.tscn")

const FIRE_VERBS := ["rounds", "mine", "grenade", ""]

func setup(_main) -> void:
	for kind in WeaponDefs.Kind.values():
		check(WeaponDefs.has(kind), "kind %s has a row" % WeaponDefs.Kind.keys()[kind])
	eq(WeaponDefs.DEFS.size(), WeaponDefs.Kind.size(), "and there is no row for a kind that does not exist")
	eq(SpecialBody.Kind.MACHINE_GUN, WeaponDefs.Kind.MACHINE_GUN, "SpecialBody.Kind is the same enum")

	for kind in WeaponDefs.DEFS:
		var label: String = WeaponDefs.Kind.keys()[kind]
		var row: Dictionary = WeaponDefs.def(kind)
		check(WeaponDefs.name_of(kind) != "?", "%s has a HUD name" % label)
		check(WeaponDefs.base_ammo(kind) > 0, "%s arrives with something in it" % label)
		check(FIRE_VERBS.has(str(row.get("fire", "?"))), "%s fires something WeaponSystem knows" % label)
		if WeaponDefs.trigger_of(kind) == WeaponDefs.Trigger.HOLD:
			check(WeaponDefs.interval_of(kind) > 0.0, "%s, held, has a cadence" % label)
			check(str(row.get("fire", "")) != "", "%s, held, fires something" % label)

		var special: Node = SpecialScene.instantiate()
		special.kind = kind
		add_child(special)
		special.apply_kind_look()
		var shape: String = WeaponDefs.shape_of(kind)
		var mesh := special.get_node_or_null(shape) as MeshInstance3D
		if check(mesh != null, "%s's mesh `%s` is in special.tscn" % [label, shape]):
			check(mesh.visible, "and applying the look shows it")
		for other in WeaponDefs.shape_nodes():
			if other == shape:
				continue
			var node := special.get_node_or_null(other) as MeshInstance3D
			if node != null:
				check(not node.visible, "%s hides `%s`" % [label, other])
		var barrel := special.get_node_or_null("Barrel") as MeshInstance3D
		if barrel != null:
			eq(barrel.visible, WeaponDefs.has_barrel(kind), "%s shows a barrel only if it points" % label)
		special.queue_free()
	finish()
