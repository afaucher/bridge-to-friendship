extends RefCounted

# THE ONE INTEGER HASH. Everything in this game that must come out the same on
# every machine from the same number -- a run's plan, a section's shape, a hat's
# style, a zombie's next move, a character's face -- draws from this.
#
# It was six byte-identical copies, one per file that needed one. They agreed
# because nobody had touched any of them, which is the "same arithmetic, one place
# each" shape CLAUDE.md records: the day one copy is "improved", every seed that
# crosses from one system into another stops reproducing, and nothing errors.
#
# DELIBERATELY NOT THE GLOBAL RNG. That is seeded once per launch (entropy in
# play, a fixed seed in tests) and consumed by everything else, so a world
# planned from it would differ between two machines that had drawn a different
# number of randoms before asking.
#
# A 32-bit avalanche (the well-known 0x45d9f3b mixer) on a 64-bit int, with the
# sign folded away so `% n` is always a valid index.
static func mix(value: int) -> int:
	var x: int = value
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return absi(x)
