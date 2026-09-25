-- The player list, opened and closed with T (see input.luau): every team in the game, yours and your allies' first
-- with what each has in the bank, then your enemies'. An enemy's bank is never sent (see server/sharing.luau).
--
-- An ally's metal and energy bars each carry a handle at the end of their fill. Dragging it out along the bar measures
-- off what to give them, in their own storage's scale, as far as the faint stretch ahead of it shows: no more than you
-- have, and no more than they have room for. Letting go sends it. A bar that has fallen low is called out, and its
-- handle glows, since that is the ally who needs it.
--
-- With an ally to ask, your own metal bar carries a handle too. Dragging it out measures off what you want, as far as
-- the room in your storage, and letting go asks your allies for it (server/notifications.luau).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local input = require(ReplicatedStorage.Client.input)

local use_viewport = require(script.Parent.use_viewport)

type Relation = "self" | "ally" | "enemy" | "watched"
type Resource = "metal" | "energy"

-- As server/sharing.luau sends them.
type Bank = {
	metal: number,
	energy: number,
	metal_capacity: number,
	energy_capacity: number,
}

type RosterEntry = {
	team_id: number,
	name: string,
	user_id: number,
	color: Color3,
	relation: Relation,
	bank: Bank?,
}

type Drag = {
	start_x: number,
}

local roster_updated: RemoteEvent = ReplicatedStorage.Shared.RosterUpdated
local share_resources: RemoteEvent = ReplicatedStorage.Shared.ShareResources
local request_metal: RemoteEvent = ReplicatedStorage.Shared.RequestMetal

local local_player = Players.LocalPlayer

-- At or under this share of storage a bar reads as low.
local LOW_FRACTION = 0.25
-- Dragged to within this share of as far as it can go, the drag gives all of it, so the very end need not be hit.
local SNAP_FRACTION = 0.03
-- How long a bar says what was just sent, in seconds.
local SENT_SECONDS = 1.5
-- A low ally's handle swells and settles to catch the eye. It is driven here rather than in the stylesheet, which
-- has no looping animation.
local BECKON = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BECKON_SCALE = 1.35

local LABELS: { [Resource]: string } = {
	metal = "METAL",
	energy = "ENERGY",
}

local function format_amount(value: number): string
	if value >= 10000 then
		return string.format("%.1fk", value / 1000)
	end
	return string.format("%d", math.floor(value))
end

local function amount_of(bank: Bank, resource: Resource): number
	return if resource == "metal" then bank.metal else bank.energy
end

local function capacity_of(bank: Bank, resource: Resource): number
	return math.max(1, if resource == "metal" then bank.metal_capacity else bank.energy_capacity)
end

local function use_open(): boolean
	local open, set_open = React.useState(input.is_player_list_open())
	React.useEffect(function()
		set_open(input.is_player_list_open())
		return input.subscribe_player_list(set_open)
	end, {})
	return open
end

local function use_roster(): { RosterEntry }
	local roster, set_roster = React.useState({} :: { RosterEntry })
	React.useEffect(function()
		local connection = roster_updated.OnClientEvent:Connect(function(next_roster: { RosterEntry })
			set_roster(next_roster)
		end)
		return function()
			connection:Disconnect()
		end
	end, {})
	return roster
end

-- The team's player's headshot on the team's colour, or the first letter of the team's name for a team nobody plays
-- (or a Studio test player, whose ids are not real). The team colour is set inline, which is why this and the stripe are
-- ImageLabels: the stylesheet makes every Frame's background transparent, and would hide it.
local function Avatar(props: { entry: RosterEntry, LayoutOrder: number })
	local has_face = props.entry.user_id > 0
	return React.createElement("ImageLabel", {
		[React.Tag] = "roster-avatar",
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = props.entry.color,
		Image = if has_face then `rbxthumb://type=AvatarHeadShot&id={props.entry.user_id}&w=48&h=48` else "",
	}, {
		Initial = if has_face
			then nil
			else React.createElement("TextLabel", {
				[React.Tag] = "roster-initial",
				Text = string.upper(string.sub(props.entry.name, 1, 1)),
			}),
	})
end

-- One of a team's two bars. `giver` is what you have of the resource to give, or nil when this bar takes nothing
-- from you: it is your own, or you are watching. `asking` is set on your own metal bar when you have an ally to ask.
local function Meter(props: {
	team_id: number,
	resource: Resource,
	bank: Bank,
	giver: number?,
	asking: boolean?,
	LayoutOrder: number,
})
	local amount = amount_of(props.bank, props.resource)
	local capacity = capacity_of(props.bank, props.resource)
	local fraction = math.clamp(amount / capacity, 0, 1)
	local asking = props.asking == true
	local reach = if asking
		then math.max(0, capacity - amount)
		elseif props.giver ~= nil then math.max(0, math.min(props.giver, capacity - amount))
		else 0
	local can_give = reach >= 1
	local low = fraction <= LOW_FRACTION

	-- what the drag has measured off so far, nil while nothing is being dragged
	local pending, set_pending = React.useState(nil :: number?)
	-- what was last sent, shown on the bar for a moment
	local sent, set_sent = React.useState(nil :: number?)
	local lane_ref = React.useRef(nil :: Frame?)
	local beckon_ref = React.useRef(nil :: UIScale?)
	local drag_ref = React.useRef(nil :: Drag?)
	-- the drag's listeners outlive a render, so they read these rather than what they were made with
	local pending_ref = React.useRef(nil :: number?)
	local limits_ref = React.useRef({ reach = reach, capacity = capacity })
	limits_ref.current = { reach = reach, capacity = capacity }

	React.useEffect(function()
		local moved = UserInputService.InputChanged:Connect(function(event: InputObject)
			local drag = drag_ref.current
			local lane = lane_ref.current
			if drag == nil or lane == nil or event.UserInputType ~= Enum.UserInputType.MouseMovement then
				return
			end
			local limits = limits_ref.current
			local width = math.max(1, lane.AbsoluteSize.X)
			local measured = (event.Position.X - drag.start_x) / width * limits.capacity
			if measured >= limits.reach * (1 - SNAP_FRACTION) then
				measured = limits.reach
			end
			local next_pending = math.floor(math.clamp(measured, 0, limits.reach))
			pending_ref.current = next_pending
			set_pending(next_pending)
		end)
		local released = UserInputService.InputEnded:Connect(function(event: InputObject)
			if drag_ref.current == nil or event.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end
			local given = pending_ref.current or 0
			drag_ref.current = nil
			pending_ref.current = nil
			set_pending(nil)
			if given >= 1 then
				if asking then
					request_metal:FireServer(given)
				else
					share_resources:FireServer(props.team_id, props.resource, given)
				end
				set_sent(given)
			end
		end)
		return function()
			moved:Disconnect()
			released:Disconnect()
		end
	end, { props.team_id, props.resource, asking } :: { any })

	-- the note of what was sent clears itself, unless something newer has replaced it by then
	React.useEffect(function()
		if sent == nil then
			return
		end
		local shown = sent
		local clear = task.delay(SENT_SECONDS, function()
			set_sent(function(current: number?): number?
				return if current == shown then nil else current
			end)
		end)
		return function()
			task.cancel(clear)
		end
	end, { sent })

	local dragging = pending ~= nil
	local wanted = low and can_give and dragging == false and asking == false

	React.useEffect(function()
		local scale = beckon_ref.current
		if scale == nil or wanted == false then
			return
		end
		local beckon = TweenService:Create(scale, BECKON, { Scale = BECKON_SCALE })
		beckon:Play()
		return function()
			beckon:Cancel()
			scale.Scale = 1
		end
	end, { wanted })

	local function begin_drag(_: GuiObject, event: InputObject)
		if event.UserInputType ~= Enum.UserInputType.MouseButton1 or can_give == false then
			return
		end
		drag_ref.current = { start_x = event.Position.X }
		pending_ref.current = 0
		set_pending(0)
		set_sent(nil)
	end

	local head = fraction + (pending or 0) / capacity
	local readout = if dragging
		then `+{format_amount(pending :: number)}`
		elseif sent ~= nil then `{if asking then "ASKED" else "SENT"} {format_amount(sent)}`
		else `{format_amount(amount)}/{format_amount(capacity)}`

	local tags = `roster-meter {props.resource}`
	if low then
		tags ..= " low"
	end
	if dragging then
		tags ..= " dragging"
	elseif sent ~= nil then
		tags ..= " sent"
	end

	return React.createElement("Frame", {
		[React.Tag] = tags,
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = React.createElement("TextLabel", {
			[React.Tag] = "roster-meter-label",
			LayoutOrder = 1,
			Text = if low then `{LABELS[props.resource]} LOW` else LABELS[props.resource],
		}),
		Lane = React.createElement("Frame", {
			[React.Tag] = "roster-lane",
			LayoutOrder = 2,
			ref = lane_ref,
		}, {
			Track = React.createElement("Frame", {
				[React.Tag] = "roster-track",
			}, {
				-- how far the handle could go, drawn faintly ahead of the fill
				Reach = if can_give
					then React.createElement("Frame", {
						[React.Tag] = "roster-reach",
						-- positioned and sized inline, as the other fills are
						Position = UDim2.fromScale(fraction, 0),
						Size = UDim2.fromScale(reach / capacity, 1),
					})
					else nil,
				Fill = React.createElement("Frame", {
					[React.Tag] = `roster-fill {props.resource}-fill`,
					Size = UDim2.fromScale(fraction, 1),
				}),
				Pending = if dragging
					then React.createElement("Frame", {
						[React.Tag] = "roster-pending",
						Position = UDim2.fromScale(fraction, 0),
						Size = UDim2.fromScale(head - fraction, 1),
					})
					else nil,
			}),
			Handle = if can_give or dragging
				then React.createElement("TextButton", {
					[React.Tag] = if wanted then "roster-handle wanted" else "roster-handle",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(head, 0.5),
					Text = "",
					AutoButtonColor = false,
					[React.Event.InputBegan] = begin_drag,
				}, {
					Beckon = React.createElement("UIScale", { ref = beckon_ref }),
				})
				else nil,
		}),
		Readout = React.createElement("TextLabel", {
			[React.Tag] = "roster-readout",
			LayoutOrder = 3,
			Text = readout,
		}),
	})
end

local BADGES: { [Relation]: string } = {
	self = "YOU",
	ally = "ALLY",
	enemy = "ENEMY",
	watched = "",
}

-- A team: a stripe of its colour, its player's face and name, and for one whose bank is known, its two bars.
-- `can_ask` is whether you have an ally to ask for metal, from your own card.
local function Card(props: { entry: RosterEntry, mine: Bank?, can_ask: boolean, LayoutOrder: number })
	local entry = props.entry
	local bank = entry.bank
	-- only an ally takes from your bank; your own bars and a watched team's are only read
	local mine = if entry.relation == "ally" then props.mine else nil

	return React.createElement("Frame", {
		[React.Tag] = `roster-card {entry.relation}`,
		LayoutOrder = props.LayoutOrder,
	}, {
		Stripe = React.createElement("ImageLabel", {
			[React.Tag] = "roster-stripe",
			LayoutOrder = 1,
			BackgroundColor3 = entry.color,
		}),
		Body = React.createElement("Frame", {
			[React.Tag] = "roster-body",
			LayoutOrder = 2,
		}, {
			Head = React.createElement("Frame", {
				[React.Tag] = "roster-head",
				LayoutOrder = 1,
			}, {
				Avatar = React.createElement(Avatar, { entry = entry, LayoutOrder = 1 }),
				Name = React.createElement("TextLabel", {
					[React.Tag] = "roster-name",
					LayoutOrder = 2,
					Text = entry.name,
				}),
				Badge = if BADGES[entry.relation] ~= ""
					then React.createElement("TextLabel", {
						[React.Tag] = `roster-badge {entry.relation}`,
						LayoutOrder = 3,
						Text = BADGES[entry.relation],
					})
					else nil,
			}),
			Metal = if bank ~= nil
				then React.createElement(Meter, {
					team_id = entry.team_id,
					resource = "metal",
					bank = bank,
					giver = if mine ~= nil then mine.metal else nil,
					asking = entry.relation == "self" and props.can_ask,
					LayoutOrder = 2,
				})
				else nil,
			Energy = if bank ~= nil
				then React.createElement(Meter, {
					team_id = entry.team_id,
					resource = "energy",
					bank = bank,
					giver = if mine ~= nil then mine.energy else nil,
					LayoutOrder = 3,
				})
				else nil,
		}),
	})
end

local function Section(props: { title: string, count: number, LayoutOrder: number })
	return React.createElement("Frame", {
		[React.Tag] = "roster-section",
		LayoutOrder = props.LayoutOrder,
	}, {
		Title = React.createElement("TextLabel", {
			[React.Tag] = "roster-section-title",
			LayoutOrder = 1,
			Text = props.title,
		}),
		Count = React.createElement("TextLabel", {
			[React.Tag] = "roster-section-count",
			LayoutOrder = 2,
			Text = tostring(props.count),
		}),
		Seam = React.createElement("Frame", {
			[React.Tag] = "roster-section-seam",
			LayoutOrder = 3,
		}),
	})
end

local function PlayerList()
	local open = use_open()
	local roster = use_roster()
	local ui_scale = use_viewport.use_ui_scale()
	if open == false then
		return nil
	end

	local mine: Bank? = nil
	local friends: { RosterEntry } = {}
	local enemies: { RosterEntry } = {}
	for _, entry in roster do
		if entry.relation == "self" then
			mine = entry.bank
			-- yourself at the head of your side
			table.insert(friends, 1, entry)
		elseif entry.relation == "enemy" then
			table.insert(enemies, entry)
		else
			table.insert(friends, entry)
		end
	end
	local watching = local_player:GetAttribute "spectator" == true
	local can_ask = #friends > 1 and watching == false

	local children: { [string]: any } = {
		Scale = React.createElement("UIScale", { Scale = ui_scale }),
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
			LayoutOrder = 0,
		}),
		Header = React.createElement("Frame", {
			[React.Tag] = "roster-header",
			LayoutOrder = 1,
		}, {
			Title = React.createElement("TextLabel", {
				[React.Tag] = "roster-title",
				LayoutOrder = 1,
				Text = "PLAYERS",
			}),
			Key = React.createElement("TextLabel", {
				[React.Tag] = "roster-key",
				LayoutOrder = 2,
				Text = "T",
			}),
		}),
	}

	local order = 2
	children.FriendsSection = React.createElement(Section, {
		title = if watching then "TEAMS" else "ALLIES",
		count = #friends,
		LayoutOrder = order,
	})
	for index, entry in friends do
		order += 1
		children[`Friend{index}`] =
			React.createElement(Card, { entry = entry, mine = mine, can_ask = can_ask, LayoutOrder = order })
	end
	if #enemies > 0 then
		order += 1
		children.EnemiesSection = React.createElement(Section, {
			title = "ENEMIES",
			count = #enemies,
			LayoutOrder = order,
		})
		for index, entry in enemies do
			order += 1
			children[`Enemy{index}`] =
				React.createElement(Card, { entry = entry, mine = nil, can_ask = false, LayoutOrder = order })
		end
	end
	-- only worth saying when there is someone to give to
	if can_ask then
		order += 1
		children.Hint = React.createElement("TextLabel", {
			[React.Tag] = "roster-hint",
			LayoutOrder = order,
			Text = "Drag an ally's bar to share, your metal to ask",
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "player-list panel",
		-- clicks on the list are the list's, not the battlefield's
		Active = true,
	}, children)
end

return table.freeze({
	PlayerList = PlayerList,
})
