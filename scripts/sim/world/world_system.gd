extends RefCounted

# ONE PIECE OF THE SIMULATION THAT GameWorld RUNS. A pool of enemies, the laps,
# the buses -- anything with its own state, its own tick and its own answer to
# "what happens on a wipe".
#
# WHY: GameWorld was 7,500 lines because every pool lived in it as the same six
# things written again -- an array, a root node, a next-id counter, a process
# pass, an encoder and an applier -- plus a line in each of the half-dozen places
# that must know every pool exists (the wipe, the corridor cut, the snapshot, the
# mode gate). A new pool had to find all of them. A system is those things in one
# object, and GameWorld asks every system the same questions in the same places.
#
# `world` IS UNTYPED ON PURPOSE. A system preloading game_world.gd would close a
# class cycle (CLAUDE.md: a preload cycle HANGS the run rather than failing it).

var world = null

# The GameMode pool this answers to, or "" for one that always runs. When the
# round's mode switches the pool OFF, `step()` CLEARS it rather than merely not
# ticking it: a pool told not to run must not keep what it already has standing
# (the bus shipped parking a vehicle on the ordinary bridge for exactly that).
var pool_name: String = ""

# The snapshot section this system owns, or "" if it does not ride the snapshot.
var section_name: String = ""

# How the world names it when a mode brings it (see BaseMode.systems).
var system_name: String = ""

func attach(w) -> void:
	world = w
	_attached()

func _attached() -> void:
	pass

# The host's tick, gated on the mode. Call this, not host_tick().
func step() -> void:
	if pool_name != "" and not world.mode_runs(pool_name):
		clear()
		return
	host_tick()

func host_tick() -> void:
	pass

# EVERY MACHINE, AFTER BOTH TICKS: what this system DRAWS, which is per-viewer and
# decides nothing, so a client does it for itself rather than being told.
func present() -> void:
	pass

# --- The snapshot -------------------------------------------------------------

func snapshot(_keyframe: bool) -> Array:
	return []

func apply_snapshot(_section: Array) -> void:
	pass

# THE PARTY IS BACK IN A LOBBY: the round just played is definitively over. The
# scoreboard that ranked it may still be on screen, so this is the place to stop
# anything still RUNNING, not to clear what the board is reading.
func on_round_over() -> void:
	pass

# --- Going away ---------------------------------------------------------------

# A wipe, or the mode switching this pool off: everything this system holds, gone.
func clear() -> void:
	pass

# The corridor past `cut_row` is being thrown away (a mode re-pick). Anything
# standing on it goes with it.
func discard_from_row(_cut_row: int) -> void:
	pass
