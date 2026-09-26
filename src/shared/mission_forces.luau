--!strict
-- What the campaign's missions put on the field, as their design has it: the overlook's enemy base (and what its hard
-- mode adds), and the counterattack's layout and waves (and its hard mode's). The server's missions put it down (server/missions); it is kept here, apart from
-- how they play it, so that what reads it (a test, a mission's guide) needs nothing of theirs.

-- One of the enemy's things. What is out in front stands `from_edge` studs east of wherever the cliff's edge is at its
-- z (mission_map.brink_x), since the edge wanders: a guard reaches 39.5 studs and a thug at the edge about 55 from that
-- height, so 45 out is out of a guard's reach of the edge and well within a thug's. That is half of it: the front line
-- of guards and two solar collectors at the foot of the cliff. The rest stands where `at` says, in world
-- (x, z), beyond a thug's reach of the edge: a guard covering the foot of each ramp from as far back as its reach lets
-- it (so that an aggravator at the foot outranges it), a second line, and the base, for the ramps or aggravators. Those
-- distances are the weapons', so they stay what they are however big the map is; it is the base behind them that is
-- packed into what room the low ground has, some 64 studs past the edge and more.
--
-- In the counterattack all of it is wrecks, where it stood but for what stood in the waves' zone, whose wreck lies at
-- `wrecked_at` instead, west of the zone, so that it stays once raised: the ramp guards nearer the feet of the ramps,
-- which they then cover, and the base's back row closer in.
export type Thing = { def_name: string, at: Vector2, from_edge: number?, wrecked_at: Vector2? }

local OVERLOOK_ENEMY: { Thing } = {
	-- in reach from the edge
	{ def_name = "guard", at = Vector2.new(0, -24), from_edge = 45 },
	{ def_name = "guard", at = Vector2.new(0, -8), from_edge = 45 },
	{ def_name = "guard", at = Vector2.new(0, 8), from_edge = 45 },
	{ def_name = "guard", at = Vector2.new(0, 24), from_edge = 45 },
	{ def_name = "solar_collector", at = Vector2.new(0, -16), from_edge = 49 },
	{ def_name = "solar_collector", at = Vector2.new(0, 16), from_edge = 49 },
	-- beyond it: the feet of the ramps, the second line, and the base
	{ def_name = "guard", at = Vector2.new(62, -42), from_edge = nil, wrecked_at = Vector2.new(38, -38) },
	{ def_name = "guard", at = Vector2.new(62, 42), from_edge = nil, wrecked_at = Vector2.new(38, 38) },
	{ def_name = "guard", at = Vector2.new(48, -10), from_edge = nil },
	{ def_name = "guard", at = Vector2.new(48, 10), from_edge = nil },
	{ def_name = "solar_collector", at = Vector2.new(60, -17), from_edge = nil, wrecked_at = Vector2.new(54, -18) },
	{ def_name = "solar_collector", at = Vector2.new(60, 17), from_edge = nil, wrecked_at = Vector2.new(54, 18) },
	{ def_name = "energy_storage", at = Vector2.new(64, 0), from_edge = nil, wrecked_at = Vector2.new(44, 0) },
}

-- What the overlook's enemy has besides in its hard mode: an agitator, whose shells reach the plateau, in the middle of
-- its base.
local OVERLOOK_HARD_ENEMY: { Thing } = {
	{ def_name = "agitator", at = Vector2.new(54, 0), from_edge = nil },
}

-- A wave: when it arrives, in seconds after the first does, and what it brings, in the order it comes down in: the
-- heaviest first, so that they lead the way.
export type Wave = {
	at: number,
	units: { { def_name: string, count: number } },
}

local COUNTERATTACK_LAYOUT = table.freeze({
	-- where the waves come in, in world (x, z): the north one's make for the north ramp, and the south one's for the
	-- south
	arrivals = table.freeze({ Vector2.new(68, 26), Vector2.new(68, -26) }),
	-- The west edge of the enemy zone. All of the old base lies west of it, so that whatever is raised of it stays.
	zone_x = 60,
	-- how long the player has to prepare before the first wave, in seconds
	prep_seconds = 300,
})

-- Every wave, the last of them the final wave, 10 seconds apart: eight of them. They grow over 70 seconds, from a raid
-- of grunts and incisors (about 300 metal of units) to the final wave's 25 units (about 3,400), some 11,600 metal in
-- all. Against that the player has the thugs and aggravators they took the heights with (about 1,300), their four
-- extractors and commander's 10 metal a second (3,000 in the five minutes they have to prepare), the 1,000 they start
-- with, and the wrecks below. Above all the second mission's base's: its eight guards, raised by the two graverobbers
-- they start with (12.5 seconds and 700 energy a guard, and no metal) and repaired whole by them after (some 6 seconds
-- more), stand on the low ground across the waves' way to the ramps, where the thugs above can cover them. The waves
-- come too close together for anything to be raised between them, so what holds is what was raised before the first.
-- From the fourth wave wolverines come too, whose shells outreach the guards, and from the fifth bombers, which only
-- anti-air does much to.
local COUNTERATTACK_WAVES: { Wave } = table.freeze({
	{
		at = 0,
		units = {
			{ def_name = "incisor", count = 1 },
			{ def_name = "grunt", count = 4 },
		},
	},
	{
		at = 10,
		units = {
			{ def_name = "thug", count = 2 },
			{ def_name = "incisor", count = 1 },
			{ def_name = "grunt", count = 4 },
		},
	},
	{
		at = 20,
		units = {
			{ def_name = "thug", count = 2 },
			{ def_name = "aggravator", count = 1 },
			{ def_name = "incisor", count = 2 },
			{ def_name = "grunt", count = 3 },
		},
	},
	{
		at = 30,
		units = {
			{ def_name = "wolverine", count = 1 },
			{ def_name = "thug", count = 3 },
			{ def_name = "aggravator", count = 1 },
			{ def_name = "incisor", count = 1 },
			{ def_name = "grunt", count = 3 },
		},
	},
	{
		at = 40,
		units = {
			{ def_name = "brute", count = 1 },
			{ def_name = "wolverine", count = 1 },
			{ def_name = "thug", count = 2 },
			{ def_name = "aggravator", count = 1 },
			{ def_name = "incisor", count = 1 },
			{ def_name = "grunt", count = 4 },
			{ def_name = "whirlwind", count = 1 },
		},
	},
	{
		at = 50,
		units = {
			{ def_name = "brute", count = 1 },
			{ def_name = "centurion", count = 1 },
			{ def_name = "wolverine", count = 1 },
			{ def_name = "thug", count = 3 },
			{ def_name = "aggravator", count = 1 },
			{ def_name = "incisor", count = 1 },
			{ def_name = "grunt", count = 4 },
			{ def_name = "whirlwind", count = 1 },
		},
	},
	{
		at = 60,
		units = {
			{ def_name = "brute", count = 2 },
			{ def_name = "centurion", count = 2 },
			{ def_name = "wolverine", count = 2 },
			{ def_name = "thug", count = 4 },
			{ def_name = "aggravator", count = 2 },
			{ def_name = "incisor", count = 2 },
			{ def_name = "grunt", count = 5 },
			{ def_name = "whirlwind", count = 1 },
		},
	},
	{
		at = 70,
		units = {
			{ def_name = "brute", count = 3 },
			{ def_name = "centurion", count = 2 },
			{ def_name = "wolverine", count = 3 },
			{ def_name = "thug", count = 4 },
			{ def_name = "aggravator", count = 3 },
			{ def_name = "incisor", count = 2 },
			{ def_name = "grunt", count = 6 },
			{ def_name = "whirlwind", count = 2 },
		},
	},
})

-- The hard mode's waves: COUNTERATTACK_WAVES, and these seven more after them, fifteen in all, as far apart, growing on
-- from the last of them and bringing pounders and januses as well, from one pounder in the ninth to four of each in
-- the fifteenth (44 units, about 7,000 metal), some 47,900 metal in all.
local EXTRA_HARD_WAVES: { Wave } = {
	{
		at = 80,
		units = {
			{ def_name = "brute", count = 3 },
			{ def_name = "centurion", count = 2 },
			{ def_name = "pounder", count = 1 },
			{ def_name = "wolverine", count = 3 },
			{ def_name = "thug", count = 4 },
			{ def_name = "aggravator", count = 3 },
			{ def_name = "incisor", count = 2 },
			{ def_name = "grunt", count = 6 },
			{ def_name = "whirlwind", count = 2 },
		},
	},
	{
		at = 90,
		units = {
			{ def_name = "brute", count = 3 },
			{ def_name = "centurion", count = 2 },
			{ def_name = "pounder", count = 1 },
			{ def_name = "janus", count = 1 },
			{ def_name = "wolverine", count = 3 },
			{ def_name = "thug", count = 4 },
			{ def_name = "aggravator", count = 3 },
			{ def_name = "incisor", count = 2 },
			{ def_name = "grunt", count = 6 },
			{ def_name = "whirlwind", count = 2 },
		},
	},
	{
		at = 100,
		units = {
			{ def_name = "brute", count = 3 },
			{ def_name = "centurion", count = 2 },
			{ def_name = "pounder", count = 2 },
			{ def_name = "janus", count = 2 },
			{ def_name = "wolverine", count = 3 },
			{ def_name = "thug", count = 5 },
			{ def_name = "aggravator", count = 3 },
			{ def_name = "incisor", count = 2 },
			{ def_name = "grunt", count = 7 },
			{ def_name = "whirlwind", count = 2 },
		},
	},
	{
		at = 110,
		units = {
			{ def_name = "brute", count = 3 },
			{ def_name = "centurion", count = 3 },
			{ def_name = "pounder", count = 2 },
			{ def_name = "janus", count = 2 },
			{ def_name = "wolverine", count = 3 },
			{ def_name = "thug", count = 5 },
			{ def_name = "aggravator", count = 3 },
			{ def_name = "incisor", count = 2 },
			{ def_name = "grunt", count = 7 },
			{ def_name = "whirlwind", count = 2 },
		},
	},
	{
		at = 120,
		units = {
			{ def_name = "brute", count = 4 },
			{ def_name = "centurion", count = 3 },
			{ def_name = "pounder", count = 3 },
			{ def_name = "janus", count = 3 },
			{ def_name = "wolverine", count = 4 },
			{ def_name = "thug", count = 5 },
			{ def_name = "aggravator", count = 4 },
			{ def_name = "incisor", count = 2 },
			{ def_name = "grunt", count = 8 },
			{ def_name = "whirlwind", count = 2 },
		},
	},
	{
		at = 130,
		units = {
			{ def_name = "brute", count = 4 },
			{ def_name = "centurion", count = 3 },
			{ def_name = "pounder", count = 3 },
			{ def_name = "janus", count = 4 },
			{ def_name = "wolverine", count = 4 },
			{ def_name = "thug", count = 6 },
			{ def_name = "aggravator", count = 4 },
			{ def_name = "incisor", count = 3 },
			{ def_name = "grunt", count = 8 },
			{ def_name = "whirlwind", count = 3 },
		},
	},
	{
		at = 140,
		units = {
			{ def_name = "brute", count = 4 },
			{ def_name = "centurion", count = 4 },
			{ def_name = "pounder", count = 4 },
			{ def_name = "janus", count = 4 },
			{ def_name = "wolverine", count = 4 },
			{ def_name = "thug", count = 6 },
			{ def_name = "aggravator", count = 4 },
			{ def_name = "incisor", count = 3 },
			{ def_name = "grunt", count = 8 },
			{ def_name = "whirlwind", count = 3 },
		},
	},
}
local COUNTERATTACK_HARD_WAVES: { Wave } = table.clone(COUNTERATTACK_WAVES)
table.move(EXTRA_HARD_WAVES, 1, #EXTRA_HARD_WAVES, #COUNTERATTACK_HARD_WAVES + 1, COUNTERATTACK_HARD_WAVES)
table.freeze(COUNTERATTACK_HARD_WAVES)

return table.freeze({
	OVERLOOK_ENEMY = OVERLOOK_ENEMY,
	OVERLOOK_HARD_ENEMY = OVERLOOK_HARD_ENEMY,
	COUNTERATTACK_LAYOUT = COUNTERATTACK_LAYOUT,
	COUNTERATTACK_WAVES = COUNTERATTACK_WAVES,
	COUNTERATTACK_HARD_WAVES = COUNTERATTACK_HARD_WAVES,
})
