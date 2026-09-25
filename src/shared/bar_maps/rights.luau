-- Who made each of the Beyond All Reason maps, and whether we may use it.
--
-- A map is its makers' work, not BAR's, and none of these carries a licence: not in its archive, not on its page, not
-- in BAR's maps-metadata. With no licence the makers keep every right, so a map is only ours to ship once they have
-- said yes. Until then it is `unlicensed`: a developer's map, as if it were not part of the game. It plays in Studio,
-- for working on the game, but outside Studio it is not offered in a lobby and cannot be loaded (see `bar_maps.MAPS`).
--
-- When a maker says yes, keep what they wrote (a screenshot of the message will do) under docs/map_permissions/, and
-- set `status` to "permitted" and `evidence` to that file. A remake needs the original's maker too, since what it
-- remakes is theirs.
--
-- The makers are as each map's own mapinfo.lua names them.

export type Status = "unlicensed" | "permitted"

export type Rights = {
	-- who made the map as it is, and how to reach them where the mapinfo says
	authors: { string },
	-- who made what it remakes, if it is a remake
	original_authors: { string },
	status: Status,
	-- where the permission is kept, once there is one
	evidence: string?,
}

local RIGHTS: { [string]: Rights } = {
	acidic_quarry = {
		authors = { "BasiC", "[teh]Beherith (mysterme@gmail.com)", "IceXuick" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	altair_crossing = {
		authors = { "[teh]Beherith (mysterme@gmail.com)" },
		original_authors = { "Quanto" },
		status = "unlicensed",
		evidence = nil,
	},
	ancient_bastion = {
		authors = { "Russ838", "Nikuksis (retexture)" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	aurelia = {
		authors = { "Johannes" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	boulder_beach = {
		authors = { "[teh]Beherith (mysterme@gmail.com)" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	canis_river = {
		authors = { "Phalange" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	center_command = {
		authors = { "Nikuksis" },
		original_authors = { "Vampiro" },
		status = "unlicensed",
		evidence = nil,
	},
	charlie_in_the_hills = {
		authors = { "Nikuksis" },
		original_authors = { "Enetheru", "LathanStanley", "Ralphie" },
		status = "unlicensed",
		evidence = nil,
	},
	coast_to_coast = {
		authors = { "Nikuksis" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	comet_catcher = {
		authors = { "IceXuick" },
		original_authors = { "NoiZe" },
		status = "unlicensed",
		evidence = nil,
	},
	devils_postpiles = {
		authors = { "AidanNaut" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	faster_than_light = {
		authors = { "ShaunJS" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	folsom_dam = {
		authors = { "IceXuick", "SirArtturi (V4 deluxe)" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	gasbag_grabens = {
		authors = { "AidanNaut" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	great_divide = {
		authors = { "NOiZE" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	greenest_fields = {
		authors = { "IceXuick" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	hooked = {
		authors = { "Raghna (timothyverbruggen@gmail.com)" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	pinewood_derby = {
		authors = { "[teh]Beherith (mysterme@gmail.com)" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	rifted = {
		authors = { "[teh]Beherith (mysterme@gmail.com)" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
	supreme_isthmus = {
		authors = { "Nikuksis" },
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	},
}

-- The rights to the map called `name`; a map with none recorded is unlicensed.
local function of(name: string): Rights
	return RIGHTS[name] or {
		authors = {},
		original_authors = {},
		status = "unlicensed",
		evidence = nil,
	}
end

-- The makers of the map called `name`, as they are to be credited: "A, B (original by C)". The contact details in
-- brackets are left out.
local function credit(name: string): string
	local rights = of(name)
	local function names(list: { string }): string
		local out = {}
		for _, entry in list do
			table.insert(out, (string.gsub(entry, "%s*%(.-@.-%)", "")))
		end
		return table.concat(out, ", ")
	end
	local text = names(rights.authors)
	if #rights.original_authors > 0 then
		text ..= ` (original by {names(rights.original_authors)})`
	end
	return text
end

return table.freeze({
	RIGHTS = RIGHTS,
	of = of,
	credit = credit,
})
