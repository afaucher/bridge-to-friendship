extends Camera3D

# The game's one camera. Fixed yaw, fixed 45-degree pitch, locked to the centre
# line of the bridge, tracking only along it.
#
# THREE PROPERTIES, EACH LOAD-BEARING:
#
#   Fixed yaw. Not a preference. The shove is locked to compass axes, so "north"
#   has to mean the same direction on every screen and in every frame; a camera
#   that rotates makes the game's signature verb unusable. See
#   design_ideas/game_concept.md.
#
#   The whole bridge across. The bridge is 30 cells (60 m) wide and the co-op
#   depends on seeing what your friends are doing, so the framing is derived from
#   the bridge's width rather than picked by eye -- change WIDTH or CELL_SIZE and
#   the camera pulls back to match, automatically.
#
#   No sideways tracking. X is pinned to the centre line. A camera that chased a
#   player sideways would make a 60 m bridge feel like a corridor and would move
#   the world under a player who is trying to line up an axis-locked dash.
#
# It follows along the bridge in BOTH Z and Y: the deck is pitched and steps up
# in layers, so tracking Z alone would let the party climb out of frame.

const GridConfig = preload("res://scripts/grid/grid_config.gd")

# Looking down at 45 degrees: enough to read the deck layout and the gaps in it,
# shallow enough that players still have visible height.
@export var pitch_deg: float = 45.0

# HORIZONTAL field of view -- see keep_aspect below. Narrower means further away
# and flatter; wider means closer with more perspective distortion at the edges.
@export var horizontal_fov_deg: float = 70.0

# A little more than the bridge, so the parapets are not flush with the screen
# edge.
@export var width_margin: float = 1.08

# Exponential follow. High enough to keep up with a dash, low enough that the
# frame does not twitch on every step.
@export var follow_rate: float = 6.0

# What the camera frames. Set by GameWorld to the local player -- each machine
# frames its own player, so nobody can be left off their own screen. Following
# the party centroid instead is a one-line change here, and is the better answer
# once the soft leash (M8) guarantees the party is close together.
var focus_target: Node = null

# How much bridge to fit across the screen. Set by GameWorld from the grid it
# built, so a narrower bridge brings the camera in rather than leaving it framed
# for one that is not there.
var bridge_width_cells: int = GridConfig.DEFAULT_WIDTH

var _distance: float = 0.0
var _offset: Vector3 = Vector3.ZERO
var _snapped: bool = false

func _ready() -> void:
	# KEEP_WIDTH makes `fov` the HORIZONTAL angle, which is what lets the framing
	# be derived from the bridge's width instead of from an aspect ratio. With
	# the default (KEEP_HEIGHT) the same fov shows a different amount of bridge
	# on every monitor, and the "see the whole bridge" requirement would hold
	# only on the machine it was tuned on.
	keep_aspect = Camera3D.KEEP_WIDTH
	fov = horizontal_fov_deg

	var span: float = float(bridge_width_cells) * GridConfig.CELL_SIZE * width_margin
	_distance = (span * 0.5) / tan(deg_to_rad(fov) * 0.5)

	var pitch := deg_to_rad(pitch_deg)
	# Behind the party (+Z, since up the bridge is -Z) and above it.
	_offset = Vector3(0.0, _distance * sin(pitch), _distance * cos(pitch))
	rotation = Vector3(-pitch, 0.0, 0.0)

func _physics_process(delta: float) -> void:
	var desired := desired_position()
	if not _snapped:
		# Snap on the first frame. Lerping from wherever the node happened to be
		# created reads as the camera flying in from the origin.
		position = desired
		_snapped = true
		return
	position = position.lerp(desired, clampf(follow_rate * delta, 0.0, 1.0))

# Where the camera wants to be, given what it is framing. Separated out so a test
# can ask without running frames.
func desired_position() -> Vector3:
	var focus := focus_position()
	# X is dropped on purpose: the camera rides the bridge's centre line.
	return Vector3(0.0, focus.y, focus.z) + _offset

func focus_position() -> Vector3:
	if focus_target != null and is_instance_valid(focus_target):
		return focus_target.position
	return Vector3.ZERO

# Half the width the camera can see at the focus plane. What "the whole bridge
# fits" is checked against.
func visible_half_width() -> float:
	return _distance * tan(deg_to_rad(fov) * 0.5)
