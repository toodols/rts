-- What is drawn over the view while a unit is piloted (client/pilot.luau): the crosshair, in the very middle of the
-- screen where the shots go, locked on while it is over an enemy the chosen weapon reaches; low in the middle, the unit's health over a row of what its keys do: its weapons, the one
-- the trigger fires lit, its manual weapon, and the orders for its army, the one it is under lit; and the whole screen
-- reddening as its health runs low.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local piloting = require(ReplicatedStorage.Shared.piloting)

local world = require(ReplicatedStorage.Client.world)
local pilot = require(ReplicatedStorage.Client.pilot)
local use_viewport = require(ReplicatedStorage.Client.ui.use_viewport)

type EntityId = types.EntityId

local team_updated: RemoteEvent = ReplicatedStorage.Shared.TeamUpdated

-- Below this share of its health the screen starts to redden, and at none it is this opaque.
local DANGER_FRACTION = 0.6
local DANGER_OPACITY = 0.45
local DANGER_COLOR = Color3.fromRGB(200, 24, 16)

-- The team's energy, as the server last said (it says so a few times a second), for how charged the manual weapon is.
local latest_energy = 0

-- How long a key's tile flashes when it is pressed.
local FLASH_SECONDS = 0.35
-- How long a key pressed for something that cannot be done flashes red, and how long why is shown.
local FAILED_FLASH_SECONDS = 0.5
local FAILED_CAPTION_SECONDS = 1.5
-- How often the army panel counts the army again.
local ARMY_SAMPLE_SECONDS = 0.25
-- How far over the top of a unit's collider what it says is drawn, and how far from the camera it is still drawn, in
-- studs.
local CALLOUT_RISE = 3
local CALLOUT_MAX_DISTANCE = 400

-- The frame each unit's line is drawn in, by unit, for `place_callouts` to move.
local callout_frames: { [EntityId]: Frame } = {}

-- What is piloted, which weapon the trigger fires and the last order given the army, kept live.
local function use_pilot(): (EntityId?, number?, pilot.Command?)
	local _, set_version = React.useState(0)
	React.useEffect(function()
		return pilot.subscribe(function()
			set_version(function(version: number): number
				return version + 1
			end)
		end)
	end, {})
	return pilot.active(), pilot.chosen_weapon(), pilot.last_command()
end

-- Whether something that happened at `at` (`os.clock()`) happened within the last FLASH_SECONDS.
local function use_flash(at: number?, seconds: number?): boolean
	local lit, set_lit = React.useState(false)
	React.useEffect(function()
		if at == nil then
			set_lit(false)
			return nil
		end
		set_lit(true)
		local thread = task.delay(if seconds ~= nil then seconds else FLASH_SECONDS, function()
			set_lit(false)
		end)
		return function()
			task.cancel(thread)
		end
	end, { at })
	return lit
end

-- The string attribute `name` of `model`, kept live; nil while there is none.
local function use_text(model: Model?, name: string): string?
	local value, set_value = React.useState(nil :: string?)
	React.useEffect(function()
		if model == nil then
			set_value(nil)
			return nil
		end
		local function read()
			local raw = model:GetAttribute(name)
			set_value(if typeof(raw) == "string" then raw else nil)
		end
		read()
		local connection = model:GetAttributeChangedSignal(name):Connect(read)
		return function()
			connection:Disconnect()
		end
	end, { model, name } :: { any })
	return value
end

-- Whether the attribute `name` of `model` is true, kept live.
local function use_flag(model: Model?, name: string): boolean
	local value, set_value = React.useState(false)
	React.useEffect(function()
		if model == nil then
			set_value(false)
			return nil
		end
		local function read()
			set_value(model:GetAttribute(name) == true)
		end
		read()
		local connection = model:GetAttributeChangedSignal(name):Connect(read)
		return function()
			connection:Disconnect()
		end
	end, { model, name } :: { any })
	return value
end

-- The number attribute `name` of `model`, kept live; `default` while there is none.
local function use_number(model: Model?, name: string, default: number?): number
	local fallback = if default ~= nil then default else 0
	local value, set_value = React.useState(fallback)
	React.useEffect(function()
		if model == nil then
			set_value(fallback)
			return nil
		end
		local function read()
			local raw = model:GetAttribute(name)
			set_value(if typeof(raw) == "number" then raw else fallback)
		end
		read()
		local connection = model:GetAttributeChangedSignal(name):Connect(read)
		return function()
			connection:Disconnect()
		end
	end, { model, name, fallback } :: { any })
	return value
end

-- Health goes from green through amber to red as it runs down, as in the selection panel.
local function health_tone(fraction: number): string
	return if fraction > 0.6
		then "vitals-fill-good"
		elseif fraction > 0.3 then "vitals-fill-worn"
		else "vitals-fill-critical"
end

-- How far the manual weapon is charged, from 0 to 1: the lesser of how far through its reload it is and how much of
-- the energy for a shot its team has. The server gives the reload to a tenth of a second (`seconds_left`), and from
-- there it is counted down here every frame, so the charge fills smoothly.
local function use_charge(seconds_left: number, reload: number, cost: number): number
	local charge, set_charge = React.useState(1)
	local energy, set_energy = React.useState(latest_energy)
	React.useEffect(function()
		local connection = team_updated.OnClientEvent:Connect(function(team: { energy: number })
			latest_energy = team.energy
			set_energy(team.energy)
		end)
		return function()
			connection:Disconnect()
		end
	end, {})
	React.useEffect(function()
		local heard_at = os.clock()
		local connection = RunService.RenderStepped:Connect(function()
			local left = math.max(0, seconds_left - (os.clock() - heard_at))
			local reloaded = if reload > 0 then 1 - left / reload else 1
			local paid = if cost > 0 then energy / cost else 1
			set_charge(math.clamp(math.min(reloaded, paid), 0, 1))
		end)
		return function()
			connection:Disconnect()
		end
	end, { seconds_left, reload, cost, energy })
	return charge
end

-- One key's tile: the key in its corner and what it does across the middle; for a weapon that costs energy, what it
-- costs along the bottom, and for one that reloads, a shade over the part of it not yet charged, which draws back down
-- it as it charges. `lit` is for the weapon the trigger fires, or the order the army is under. It flashes whenever its
-- key is pressed (`pilot.pressed_at`), and the chosen weapon's whenever the trigger is.
local function Ability(props: {
	keybind: string,
	name: string,
	cost: string?,
	charge: number?,
	large: boolean?,
	lit: boolean?,
	danger: boolean?,
	LayoutOrder: number,
})
	local flash = use_flash(pilot.pressed_at(props.keybind))
	local failure = pilot.last_failure()
	local failed =
		use_flash(if failure ~= nil and failure.key == props.keybind then failure.at else nil, FAILED_FLASH_SECONDS)
	local charge = if props.charge ~= nil then props.charge else 1
	local tags = "pilot-ability"
	if props.large == true then
		tags ..= " large"
	end
	if props.lit == true then
		tags ..= " lit"
	end
	if props.danger == true then
		tags ..= " danger"
	end
	if failed then
		tags ..= " failed"
	elseif flash then
		tags ..= " flash"
	end
	if charge < 1 then
		tags ..= " charging"
	end
	return React.createElement("Frame", {
		[React.Tag] = tags,
		LayoutOrder = props.LayoutOrder,
	}, {
		Tint = if props.lit == true
			then React.createElement("Frame", {
				[React.Tag] = "pilot-ability-tint",
			})
			else nil,
		Mark = if props.lit == true
			then React.createElement("Frame", {
				[React.Tag] = "pilot-ability-mark",
			})
			else nil,
		Flash = if failed
			then React.createElement("Frame", {
				[React.Tag] = "pilot-ability-failed",
			})
			elseif flash then React.createElement("Frame", {
				[React.Tag] = "pilot-ability-flash",
			})
			else nil,
		Keybind = React.createElement("TextLabel", {
			[React.Tag] = "pilot-ability-key",
			Text = props.keybind,
		}),
		Name = React.createElement("TextLabel", {
			[React.Tag] = "pilot-ability-name",
			Text = props.name,
		}),
		Cost = if props.cost ~= nil
			then React.createElement("TextLabel", {
				[React.Tag] = "pilot-ability-cost",
				Text = props.cost,
			})
			else nil,
		Shade = if charge < 1
			then React.createElement("Frame", {
				[React.Tag] = "pilot-ability-shade",
				Size = UDim2.new(1, 0, 1 - charge, 0),
			})
			else nil,
	})
end

-- The tile of weapon `index` of the piloted unit in `model`: its number, what kind it is, and how far through its
-- reload it is, as the server publishes it for its pilot.
local function WeaponAbility(props: {
	model: Model,
	index: number,
	weapon: types.Weapon,
	chosen: boolean,
	LayoutOrder: number,
})
	local charge = use_number(props.model, piloting.charge_attribute(props.index), 1)
	local weapon = props.weapon
	return React.createElement(Ability, {
		keybind = tostring(props.index),
		name = piloting.weapon_label(weapon),
		cost = if weapon.energy_per_shot > 0 then `{weapon.energy_per_shot} E` else nil,
		charge = charge,
		lit = props.chosen,
		LayoutOrder = props.LayoutOrder,
	})
end

-- A line a pilot's unit says: a dark strip with a bar of colour down its left, `color` (its team's) or the accent, and
-- the words. `world` is for one drawn over a unit, which `place_callouts` moves; otherwise it is the pilot's own, in
-- their HUD.
local function Callout(props: {
	text: string,
	color: Color3?,
	world: boolean?,
	danger: boolean?,
	id: EntityId?,
	LayoutOrder: number?,
})
	local id = props.id
	local ui_scale = use_viewport.use_ui_scale()
	local tags = "pilot-callout"
	if props.world == true then
		tags ..= " world"
	end
	if props.danger == true then
		tags ..= " danger"
	end
	return React.createElement("Frame", {
		[React.Tag] = tags,
		LayoutOrder = props.LayoutOrder,
		AnchorPoint = if props.world == true then Vector2.new(0.5, 1) else nil,
		-- parked off screen until the first placement has run
		Position = if props.world == true then UDim2.fromOffset(-1000, -1000) else nil,
		ref = if props.world == true and id ~= nil
			then function(instance: Frame?)
				if instance ~= nil then
					callout_frames[id] = instance
				else
					callout_frames[id] = nil
				end
			end
			else nil,
	}, {
		-- the pilot's own sits in their HUD, which is scaled already
		Scale = if props.world == true then React.createElement("UIScale", { Scale = ui_scale }) else nil,
		Bar = React.createElement("Frame", {
			[React.Tag] = "pilot-callout-bar",
			BackgroundColor3 = props.color,
			LayoutOrder = 1,
		}),
		Text = React.createElement("TextLabel", {
			[React.Tag] = "pilot-callout-text",
			Text = props.text,
			LayoutOrder = 2,
		}),
	})
end

-- Puts every unit's line over it, as world_bars does its bars: written straight to the frames every frame.
local function place_callouts()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	for id, frame in callout_frames do
		local model = world.get(id)
		local def_name = if model ~= nil then model:GetAttribute "def_name" else nil
		local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
		if model == nil or def == nil then
			frame.Visible = false
			continue
		end
		local anchor = world.position_of(model) + Vector3.new(0, unit_defs.collider_height(def) / 2 + CALLOUT_RISE, 0)
		local point, on_screen = camera:WorldToViewportPoint(anchor)
		frame.Visible = on_screen and (anchor - camera.CFrame.Position).Magnitude <= CALLOUT_MAX_DISTANCE
		if on_screen then
			frame.Position = UDim2.fromOffset(math.floor(point.X), math.floor(point.Y))
		end
	end
end

-- What every piloted unit but this player's own is saying, over it, for everyone to see.
local function PilotCallouts()
	local id = use_pilot()
	React.useEffect(function()
		local connection = RunService.RenderStepped:Connect(place_callouts)
		return function()
			connection:Disconnect()
		end
	end, {})
	local shown: { [string]: any } = {}
	for speaker, callout in pilot.current_callouts() do
		local model = world.get(speaker)
		if speaker == id or model == nil then
			continue
		end
		local color = model:GetAttribute "team_color"
		shown[`Callout{speaker}`] = React.createElement(Callout, {
			text = piloting.PHRASES[callout.phrase],
			color = if typeof(color) == "Color3" then color else nil,
			world = true,
			id = speaker,
		})
	end
	return React.createElement(React.Fragment, {}, shown)
end

-- The army hold and follow send (`pilot.army`), as it stands: how many, their health and the most of it between them,
-- and how many of each kind, most first.
type ArmyState = {
	count: number,
	health: number,
	max_health: number,
	kinds: { { name: string, count: number } },
}

local EMPTY_ARMY: ArmyState = { count = 0, health = 0, max_health = 0, kinds = {} }

local function sample_army(): ArmyState
	local by_name: { [string]: number } = {}
	local state: ArmyState = { count = 0, health = 0, max_health = 0, kinds = {} }
	for _, unit in pilot.army() do
		state.count += 1
		local health = unit.model:GetAttribute "health"
		local max_health = unit.model:GetAttribute "max_health"
		state.health += if typeof(health) == "number" then health else 0
		state.max_health += if typeof(max_health) == "number" then max_health else 0
		by_name[unit.def.display_name] = (by_name[unit.def.display_name] or 0) + 1
	end
	for name, count in by_name do
		table.insert(state.kinds, { name = name, count = count })
	end
	table.sort(state.kinds, function(a, b)
		return if a.count ~= b.count then a.count > b.count else a.name < b.name
	end)
	return state
end

-- The army, sampled ARMY_SAMPLE_SECONDS apart while `active`.
local function use_army(active: boolean): ArmyState
	local army, set_army = React.useState(EMPTY_ARMY)
	React.useEffect(function()
		if active == false then
			set_army(EMPTY_ARMY)
			return nil
		end
		set_army(sample_army())
		local waited = 0
		local connection = RunService.Heartbeat:Connect(function(delta: number)
			waited += delta
			if waited >= ARMY_SAMPLE_SECONDS then
				waited = 0
				set_army(sample_army())
			end
		end)
		return function()
			connection:Disconnect()
		end
	end, { active })
	return army
end

-- Down the left: the army hold and follow send, its health between them, and how many of each kind are left.
local function ArmyPanel(props: { army: ArmyState })
	local army = props.army
	local ui_scale = use_viewport.use_ui_scale()
	local fraction = if army.max_health > 0 then math.clamp(army.health / army.max_health, 0, 1) else 0
	local rows: { [string]: any } = {}
	for index, kind in army.kinds do
		rows[`Kind{index}`] = React.createElement("Frame", {
			[React.Tag] = "pilot-army-row",
			LayoutOrder = 2 + index,
		}, {
			Name = React.createElement("TextLabel", {
				[React.Tag] = "pilot-army-name",
				Text = kind.name,
				LayoutOrder = 1,
			}),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "pilot-army-count",
				Text = `×{kind.count}`,
				LayoutOrder = 2,
			}),
		})
	end
	rows.Scale = React.createElement("UIScale", { Scale = ui_scale })
	rows.Title = React.createElement("TextLabel", {
		[React.Tag] = "pilot-army-title",
		Text = `ARMY  {army.count}`,
		LayoutOrder = 1,
	})
	rows.Health = React.createElement("Frame", {
		[React.Tag] = "vitals-track",
		LayoutOrder = 2,
	}, {
		Fill = React.createElement("Frame", {
			[React.Tag] = `vitals-fill {health_tone(fraction)}`,
			Size = UDim2.new(fraction, 0, 1, 0),
		}),
		Label = React.createElement("TextLabel", {
			[React.Tag] = "vitals-label",
			Text = `{math.floor(army.health)} / {math.floor(army.max_health)}`,
		}),
	})
	return React.createElement("Frame", {
		[React.Tag] = "pilot-army",
	}, rows)
end

local function PilotHud()
	local id, chosen, command = use_pilot()
	local model = if id ~= nil then world.get(id) else nil
	local cooldown = use_number(model, piloting.COOLDOWN_ATTRIBUTE)
	local health = use_number(model, "health")
	local max_health = use_number(model, "max_health")
	local cargo_used = use_number(model, "cargo_used")
	local can_load = use_flag(model, piloting.LOAD_ATTRIBUTE)
	local can_unload = use_flag(model, piloting.UNLOAD_ATTRIBUTE)
	local can_call = use_flag(model, piloting.CALL_ATTRIBUTE)
	local call_state = use_text(model, piloting.CALL_STATE_ATTRIBUTE)
	local failure = pilot.last_failure()
	local failing = use_flash(if failure ~= nil then failure.at else nil, FAILED_CAPTION_SECONDS)
	local army = use_army(id ~= nil)
	local ui_scale = use_viewport.use_ui_scale()
	local def_name = if model ~= nil then model:GetAttribute "def_name" else nil
	local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
	local manual = if def ~= nil then def.manual_weapon else nil
	local charge = use_charge(
		cooldown,
		if manual ~= nil then manual.reload else 0,
		if manual ~= nil then manual.energy_per_shot else 0
	)
	if id == nil then
		return nil
	end

	local fraction = math.clamp(health / math.max(1, max_health), 0, 1)
	local danger = math.clamp((DANGER_FRACTION - fraction) / DANGER_FRACTION, 0, 1)
	local said = pilot.current_callouts()[id]

	-- its weapons first, by their number keys, then its manual weapon, then the orders for the army
	local abilities: { [string]: any } = {}
	local order = 0
	if model ~= nil and def ~= nil and def.weapons ~= nil then
		for index, weapon in def.weapons do
			if piloting.can_select(def, index) == false or index > 9 then
				continue
			end
			order += 1
			abilities[`Weapon{index}`] = React.createElement(WeaponAbility, {
				model = model,
				index = index,
				weapon = weapon,
				chosen = index == chosen,
				LayoutOrder = order,
			})
		end
	end
	if manual ~= nil then
		abilities.Dgun = React.createElement(Ability, {
			keybind = "Q",
			name = "DGUN",
			cost = `{manual.energy_per_shot} E`,
			charge = charge,
			large = true,
			LayoutOrder = order + 1,
		})
	end
	-- a transport picks up while its hold is empty and sets down once it is not; something it could carry calls one.
	-- Each is shaded right over while it cannot be done yet.
	if def ~= nil and def.transport ~= nil then
		if cargo_used <= 0 then
			abilities.Load = React.createElement(Ability, {
				keybind = "J",
				name = "LOAD",
				charge = if can_load then 1 else 0,
				LayoutOrder = order + 2,
			})
		else
			abilities.Unload = React.createElement(Ability, {
				keybind = "U",
				name = "UNLOAD",
				charge = if can_unload then 1 else 0,
				LayoutOrder = order + 2,
			})
		end
	elseif def ~= nil and def.weight_class ~= nil then
		-- lit while the transport it called is on its way, and red for a moment if that is shot down
		abilities.Call = React.createElement(Ability, {
			keybind = "G",
			name = if call_state == "coming" then "INBOUND" elseif call_state == "lost" then "LOST" else "MOUNT",
			charge = if can_call or call_state == "coming" then 1 else 0,
			lit = call_state == "coming",
			danger = call_state == "lost",
			LayoutOrder = order + 2,
		})
	end
	abilities.Hold = React.createElement(Ability, {
		keybind = "X",
		name = "HOLD",
		lit = command ~= nil and command.kind == "hold",
		LayoutOrder = order + 3,
	})
	abilities.Follow = React.createElement(Ability, {
		keybind = "C",
		name = "FOLLOW",
		lit = command ~= nil and command.kind == "follow",
		LayoutOrder = order + 4,
	})
	abilities.Attack = React.createElement(Ability, {
		keybind = "V",
		name = "ATTACK",
		lit = command ~= nil and command.kind == "attack",
		LayoutOrder = order + 5,
	})

	return React.createElement(React.Fragment, {}, {
		Danger = if danger > 0
			then React.createElement("Frame", {
				[React.Tag] = "pilot-danger",
				BackgroundColor3 = DANGER_COLOR,
				BackgroundTransparency = 1 - danger * DANGER_OPACITY,
			})
			else nil,
		Army = React.createElement(ArmyPanel, { army = army }),
		Crosshair = React.createElement("Frame", {
			[React.Tag] = if pilot.is_on_target() then "pilot-crosshair locked" else "pilot-crosshair",
		}, {
			Dot = React.createElement("Frame", {
				[React.Tag] = "pilot-crosshair-dot",
			}),
		}),
		Bar = React.createElement("Frame", {
			[React.Tag] = "pilot-bar",
		}, {
			Scale = React.createElement("UIScale", { Scale = ui_scale }),
			-- what its unit has just said, over its health
			Said = if said ~= nil
				then React.createElement(Callout, {
					text = piloting.PHRASES[said.phrase],
					LayoutOrder = 0,
				})
				else nil,
			-- why the key just pressed did nothing, for a moment
			Failed = if failing and failure ~= nil
				then React.createElement(Callout, {
					text = failure.reason,
					danger = true,
					LayoutOrder = -2,
				})
				else nil,
			-- how the transport it called is getting on, just for the pilot
			Call = if call_state == "coming" or call_state == "lost"
				then React.createElement(Callout, {
					text = if call_state == "lost" then "Mount shot down!" else "Mount inbound",
					danger = call_state == "lost",
					LayoutOrder = -1,
				})
				else nil,
			Health = React.createElement("Frame", {
				[React.Tag] = "pilot-health",
				LayoutOrder = 1,
			}, {
				Track = React.createElement("Frame", {
					[React.Tag] = "vitals-track",
				}, {
					Fill = React.createElement("Frame", {
						[React.Tag] = `vitals-fill {health_tone(fraction)}`,
						Size = UDim2.new(fraction, 0, 1, 0),
					}),
					Label = React.createElement("TextLabel", {
						[React.Tag] = "vitals-label",
						Text = `{math.floor(health)} / {math.floor(max_health)}`,
					}),
				}),
			}),
			Abilities = React.createElement("Frame", {
				[React.Tag] = "pilot-abilities",
				LayoutOrder = 2,
			}, abilities),
		}),
	})
end

return table.freeze({
	PilotHud = PilotHud,
	PilotCallouts = PilotCallouts,
})
