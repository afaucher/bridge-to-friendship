extends RefCounted

# THE PHYSICS LAYERS, BY NAME. Mirrors `[layer_names]` in project.godot bit for
# bit, and test_layers holds the two together -- plus every scene that carries a
# layer in its .tscn, since a scene cannot reference a script constant.
#
# WHY THIS FILE EXISTS: this project has shipped five bugs that were one wrong
# bit in a mask (CLAUDE.md), and before it every script spelled its layers its
# own way -- `1 << 3`, `2048`, `LAYER := 1024`, `(1 << 0) | (1 << 1) | (1 << 4)`.
# A number written by hand is a number nobody can read back; the laser sight
# claimed "same layers a round is stopped by" and was missing three of them.

const WORLD := 1 << 0          # 1  "world": deck, walls, anything you stand on
const PLAYERS := 1 << 1        # 2  "players"
const STONES := 1 << 2         # 3  "stones": pushable pillars
const BALLS := 1 << 3          # 4  "balls": plinko balls -- AND THE SWALLOW, see below
const ENEMIES := 1 << 4        # 5  "rushers": every walking enemy (rusher, zombie, gunner)
const HATS := 1 << 5           # 6  "hats": a LOOSE hat
const SPECIALS := 1 << 6       # 7  "specials": pickups, grenades, mines
const BARRIER := 1 << 7        # 8  "barrier": the round walls
const WORN_HATS := 1 << 8      # 9  "worn_hats": a hat on a head
const MERCHANT := 1 << 9       # 10 "merchant"
const POSTS := 1 << 10         # 11 "mode_post": the mode post AND the bus post
const BUS := 1 << 11           # 12 "bus"
const DEBRIS := 1 << 12        # 13 "debris": corpse fragments

# THE SWALLOW SITS ON `BALLS`, and that is load-bearing rather than tidy: the
# player's mask does not include it, so a body can be pulled INTO the swallow's
# core (which is how it drains) instead of stopping against its shell. Its old
# comment called the layer "enemies"; putting it there would have made it solid
# to players and the core unreachable.
const SWALLOW := BALLS

# WHAT STOPS A ROUND. The bullet sweep and anything that claims to show where a
# round will go -- the laser sight -- must ask exactly this.
const SHOT_STOPPERS := WORLD | PLAYERS | STONES | BALLS | ENEMIES | WORN_HATS

# WHAT BLOCKS A LINE OF SIGHT for an enemy deciding whether it can see you.
const SIGHT_BLOCKERS := WORLD | STONES

# The project's own name for layer `bit` (1-based), for messages and tests.
static func name_of(bit: int) -> String:
	return str(ProjectSettings.get_setting("layer_names/3d_physics/layer_%d" % bit, ""))
