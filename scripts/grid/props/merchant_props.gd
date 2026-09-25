extends "res://scripts/grid/props/consumable_props.gd"

# MERCHANTS. The one kind that is NOT removed when consumed: a sold-out shopkeeper
# is still standing there and still solid -- "is there a merchant here" and "can
# I trade" are two different questions -- so taking one marks it spent and leaves
# the node.

const MerchantBody = preload("res://scripts/sim/merchant_body.gd")

func _init() -> void:
	root_name = "Merchants"
	node_prefix = "Merchant"

func _build(cell: Vector2i) -> Node3D:
	var merchant := MerchantBody.new()
	merchant.cell = cell
	merchant.position = grid.cell_surface(cell)
	return merchant

# BUILT EVEN WHEN SPENT, and marked. A joiner is told who has sold before the
# segment holding him exists; leaving him out would be a missing shopkeeper,
# leaving him unmarked would be him for sale a second time.
func spawn(cell: Vector2i) -> void:
	var was_spent: bool = spent.has(cell)
	spent.erase(cell)
	super(cell)
	if was_spent:
		spent.append(cell)
		at(cell).mark_spent()

func open() -> Array:
	var out: Array = []
	for cell in nodes.keys():
		var merchant: Node = nodes[cell]
		if is_instance_valid(merchant) and merchant.can_trade():
			out.append(merchant)
	return out

func take(cell: Vector2i) -> bool:
	var merchant: Node = at(cell)
	if merchant == null or not merchant.can_trade():
		return false
	merchant.mark_spent()
	mark_spent(cell)
	return true

func apply_layout(data: PackedInt32Array) -> void:
	var i := 0
	while i + 1 < data.size():
		var cell := Vector2i(data[i], data[i + 1])
		mark_spent(cell)
		var merchant: Node = at(cell)
		if merchant != null:
			merchant.mark_spent()
		i += 2
