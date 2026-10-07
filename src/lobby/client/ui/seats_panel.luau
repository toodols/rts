--!strict
-- Who is in the lobby and on which side, with the empty places left. In a team game each team is a column, and a
-- player moves to the other team by clicking one of its empty places; against the scavengers and in a free for all
-- everyone is in one list. Under them are the spectators, who come to the game only to watch: a player moves to
-- watching by clicking the place left there, and a spectator back to playing by clicking an empty seat.
--
-- Each player's row shows their level, as a rank before their name (rank.luau), and their resource bonus, which only a
-- developer (shared/developers.luau) changes; anyone else sees it only when there is one. A player who is
-- ready to start says so on their row.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"

local React = require(ReplicatedStorage.Packages.react)

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local developers = require(ReplicatedStorage.Shared.developers)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local rank = require(script.Parent.rank)

local format = require(ReplicatedStorage.ClientShared.format)

type LobbyView = protocol.LobbyView

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

local local_player = Players.LocalPlayer

-- How far a press on a bonus has to move, in pixels, to be a drag rather than a click, and how far a drag moves it by
-- one percent: the whole range is 200 pixels across.
local DRAG_THRESHOLD = 3
local PIXELS_PER_PERCENT = 1

-- What a player's bonus can be changed with, passed down to where it is shown.
type BonusProps = {
	bonuses: { [string]: number },
	can_change: boolean,
	act: (action: protocol.Action, argument: any?) -> (),
}

local function bonus_text(percent: number): string
	return if percent > 0 then `+{percent}%` else `{percent}%`
end

local function tone(percent: number): string
	return if percent > 0 then " up" elseif percent < 0 then " down" else ""
end

-- A bonus as a developer changes it: one small field, filled out from its middle as far as the bonus goes. Dragging
-- across it scrubs the value in steps of game_modes.BONUS_STEP (by 1 with shift held), sent once it is let go; a click
-- that does not drag types an exact one in; a right click sets it back to none.
local function BonusField(props: { percent: number, on_set: (number) -> (), LayoutOrder: number })
	-- the value being dragged to, shown in place of the bonus until it is let go
	local preview: number?, set_preview = React.useState(nil :: number?)
	local editing, set_editing = React.useState(false)
	local box_ref = React.useRef(nil :: TextBox?)
	local drag_ref = React.useRef(nil :: { RBXScriptConnection }?)

	local function stop_drag()
		local connections = drag_ref.current
		drag_ref.current = nil
		if connections ~= nil then
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end

	React.useEffect(function()
		return stop_drag
	end, {})

	-- a drag let go shows where it went until the bonus it sent comes back
	React.useEffect(function()
		set_preview(nil)
	end, { props.percent })

	React.useEffect(function()
		local box = box_ref.current
		if editing and box ~= nil then
			box:CaptureFocus()
			box.CursorPosition = #box.Text + 1
		end
	end, { editing })

	-- Sends `value` as the bonus, unless it already is. Returns whether it was sent.
	local function set(value: number): boolean
		local clamped = game_modes.clamp_bonus(value)
		if clamped == props.percent then
			return false
		end
		props.on_set(clamped)
		return true
	end

	local function began(_field: GuiObject, input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			set(0)
			return
		end
		local pointer = input.UserInputType
		if (pointer ~= Enum.UserInputType.MouseButton1 and pointer ~= Enum.UserInputType.Touch) or editing then
			return
		end
		stop_drag()
		local start_x = input.Position.X
		local start = props.percent
		local moved = false
		local value = start
		drag_ref.current = {
			UserInputService.InputChanged:Connect(function(change: InputObject)
				if change.UserInputType ~= Enum.UserInputType.MouseMovement and change ~= input then
					return
				end
				local dx = change.Position.X - start_x
				moved = moved or math.abs(dx) >= DRAG_THRESHOLD
				if not moved then
					return
				end
				local fine = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
				local step = if fine then 1 else game_modes.BONUS_STEP
				value = game_modes.clamp_bonus(math.round((start + dx / PIXELS_PER_PERCENT) / step) * step)
				set_preview(value)
			end),
			UserInputService.InputEnded:Connect(function(ended: InputObject)
				if ended.UserInputType ~= pointer then
					return
				end
				stop_drag()
				if moved then
					if set(value) == false then
						set_preview(nil)
					end
				else
					set_editing(true)
				end
			end),
		}
	end

	local shown = preview or props.percent
	local tag = `bonus-field{tone(shown)}`
	if editing then
		tag ..= " editing"
	elseif preview ~= nil then
		tag ..= " scrubbing"
	end
	local reach = math.abs(shown) / (game_modes.BONUS_MAX - game_modes.BONUS_MIN)
	return React.createElement(
		"TextButton",
		{
			[React.Tag] = tag,
			LayoutOrder = props.LayoutOrder,
			Text = "",
			AutoButtonColor = false,
			[React.Event.InputBegan] = began,
		} :: Props,
		{
			Fill = React.createElement("Frame", {
				[React.Tag] = `bonus-fill{tone(shown)}`,
				Position = UDim2.fromScale(if shown < 0 then 0.5 - reach else 0.5, 0),
				Size = UDim2.fromScale(reach, 1),
			}),
			Middle = React.createElement("Frame", {
				[React.Tag] = "bonus-middle",
			}),
			Value = if editing
				then React.createElement(
					"TextBox",
					{
						[React.Tag] = `bonus-text{tone(shown)}`,
						Text = tostring(props.percent),
						ClearTextOnFocus = false,
						ref = box_ref,
						[React.Event.FocusLost] = function(box: TextBox, _enter: boolean, cause: InputObject?)
							set_editing(false)
							if cause ~= nil and cause.KeyCode == Enum.KeyCode.Escape then
								return
							end
							local typed = tonumber((string.gsub(box.Text, "[%s%%+]", "")))
							if typed ~= nil then
								set(typed)
							end
						end,
					} :: Props
				)
				else React.createElement("TextLabel", {
					[React.Tag] = `bonus-text{tone(shown)}`,
					Text = bonus_text(shown),
					-- presses go through it to the field
					Interactable = false,
				}),
		}
	)
end

-- The bonus of the player `user_id`: the field above for a developer, and for anyone else the value alone, nothing
-- while it is none.
local function Bonus(props: { user_id: number, bonus: BonusProps, LayoutOrder: number })
	local bonus = props.bonus
	local percent = bonus.bonuses[tostring(props.user_id)] or 0
	if bonus.can_change == false then
		if percent == 0 then
			return nil
		end
		return React.createElement("TextLabel", {
			[React.Tag] = if percent > 0 then "bonus-value up" else "bonus-value down",
			LayoutOrder = props.LayoutOrder,
			Text = `BONUS {bonus_text(percent)}`,
		})
	end
	return React.createElement(BonusField, {
		percent = percent,
		on_set = function(value: number)
			bonus.act("set_bonus", { user_id = props.user_id, percent = value })
		end,
		LayoutOrder = props.LayoutOrder,
	})
end

-- `bonus` is given to a player's seat, not a spectator's.
local function Seat(props: {
	seat: game_modes.Seat,
	host: number,
	ready: boolean,
	level: number?,
	bonus: BonusProps?,
	LayoutOrder: number,
})
	local you = props.seat.user_id == local_player.UserId
	return React.createElement("Frame", {
		[React.Tag] = if you then "seat you" else "seat",
		LayoutOrder = props.LayoutOrder,
	}, {
		Rank = if props.level ~= nil
			then React.createElement(rank.Insignia, {
				level = props.level,
				LayoutOrder = 0,
			})
			else nil,
		Name = React.createElement("TextLabel", {
			[React.Tag] = "seat-name grow",
			LayoutOrder = 1,
			Text = format.escape(props.seat.name),
		}),
		Host = if props.seat.user_id == props.host
			then React.createElement("TextLabel", {
				[React.Tag] = "tag host",
				LayoutOrder = 2,
				Text = "HOST",
			})
			else nil,
		You = if you
			then React.createElement("TextLabel", {
				[React.Tag] = "tag you",
				LayoutOrder = 3,
				Text = "YOU",
			})
			else nil,
		Ready = if props.ready
			then React.createElement("TextLabel", {
				[React.Tag] = "tag ready",
				LayoutOrder = 4,
				Text = "READY",
			})
			else nil,
		Bonus = if props.bonus ~= nil
			then React.createElement(Bonus, {
				user_id = props.seat.user_id,
				bonus = props.bonus,
				LayoutOrder = 6,
			})
			else nil,
	})
end

local function OpenSeat(props: { can_move: boolean, move_label: string, on_move: () -> (), LayoutOrder: number })
	return React.createElement(
		"TextButton",
		{
			[React.Tag] = if props.can_move then "seat open movable" else "seat open",
			LayoutOrder = props.LayoutOrder,
			Text = if props.can_move then props.move_label else "Open",
			AutoButtonColor = false,
			Interactable = props.can_move,
			[React.Event.Activated] = props.on_move,
		} :: Props
	)
end

local function Side(
	props: {
		label: string,
		seats: { game_modes.Seat },
		room: number,
		-- how many empty places to draw, if not all of them
		open: number?,
		host: number,
		-- the user ids of the players who are ready
		ready: { number },
		-- each player's level, by user id as a string
		levels: { [string]: number },
		-- what shows and changes each seat's bonus, for players' sides
		bonus: BonusProps?,
		-- nil when nobody can move to this side
		on_move: (() -> ())?,
		move_label: string?,
		LayoutOrder: number,
	}
)
	local rows: { [string]: any } = {
		Head = React.createElement("Frame", {
			[React.Tag] = "side-head",
			LayoutOrder = 0,
		}, {
			Label = React.createElement("TextLabel", {
				[React.Tag] = "group-label grow",
				LayoutOrder = 1,
				Text = props.label,
			}),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "side-count",
				LayoutOrder = 2,
				Text = `{#props.seats}/{props.room}`,
			}),
		}),
	}
	for index, seat in props.seats do
		rows[`Seat{seat.user_id}`] = React.createElement(Seat, {
			seat = seat,
			host = props.host,
			ready = table.find(props.ready, seat.user_id) ~= nil,
			level = props.levels[tostring(seat.user_id)],
			bonus = props.bonus,
			LayoutOrder = index,
		})
	end
	local on_move = props.on_move
	local last_open = if props.open ~= nil then math.min(props.room, #props.seats + props.open) else props.room
	for index = #props.seats + 1, last_open do
		rows[`Open{index}`] = React.createElement(OpenSeat, {
			can_move = on_move ~= nil,
			move_label = props.move_label or "Move here",
			on_move = function()
				if on_move ~= nil then
					on_move()
				end
			end,
			LayoutOrder = index,
		})
	end
	return React.createElement("Frame", {
		[React.Tag] = "side",
		LayoutOrder = props.LayoutOrder,
	}, rows)
end

local function SeatsPanel(props: {
	lobby: LobbyView,
	act: (action: protocol.Action, argument: any?) -> (),
})
	local lobby = props.lobby
	local mode = game_modes.get(lobby.match.mode) :: game_modes.Mode

	local my_side: number? = nil
	local players: { game_modes.Seat } = {}
	local spectators: { game_modes.Seat } = {}
	for _, seat in lobby.match.seats do
		if seat.user_id == local_player.UserId then
			my_side = seat.side
		end
		table.insert(if seat.side == game_modes.SPECTATOR_SIDE then spectators else players, seat)
	end
	local watching = my_side == game_modes.SPECTATOR_SIDE
	local bonus: BonusProps = {
		bonuses = lobby.match.bonuses,
		can_change = developers.is_developer(local_player),
		act = props.act,
	}

	local sides: { [string]: any } = {}
	if mode.picks_sides then
		for side = 1, mode.sides do
			local on_side = {}
			for _, seat in players do
				if seat.side == side then
					table.insert(on_side, seat)
				end
			end
			sides[`Side{side}`] = React.createElement(Side, {
				label = `{mode.side_label} {side}`,
				seats = on_side,
				room = mode.per_side,
				host = lobby.host,
				ready = lobby.ready,
				levels = lobby.levels or {},
				bonus = bonus,
				on_move = if side ~= my_side
					then function()
						props.act("move", side)
					end
					else nil,
				LayoutOrder = side,
			})
		end
	else
		sides.Everyone = React.createElement(Side, {
			label = mode.side_label,
			seats = players,
			room = mode.capacity,
			host = lobby.host,
			ready = lobby.ready,
			levels = lobby.levels or {},
			bonus = bonus,
			-- a spectator takes whichever seat is free
			on_move = if watching
				then function()
					props.act("move", 1)
				end
				else nil,
			move_label = "Play",
			LayoutOrder = 1,
		})
	end

	return React.createElement("Frame", {
		[React.Tag] = "seats-panel panel",
		LayoutOrder = 2,
	}, {
		Rail = React.createElement("Frame", {
			[React.Tag] = "rail",
			LayoutOrder = 1,
		}),
		Title = React.createElement("Frame", {
			[React.Tag] = "title-row",
			LayoutOrder = 2,
		}, {
			Accent = React.createElement("Frame", {
				[React.Tag] = "accent-bar",
				LayoutOrder = 1,
			}),
			Name = React.createElement("TextLabel", {
				[React.Tag] = "heading",
				LayoutOrder = 2,
				Text = "Players",
			}),
			Count = React.createElement("TextLabel", {
				[React.Tag] = "badge",
				LayoutOrder = 3,
				Text = `{#players}/{mode.capacity}`,
			}),
		}),
		Sides = React.createElement("ScrollingFrame", {
			[React.Tag] = "sides",
			LayoutOrder = 3,
		}, {
			Teams = React.createElement("Frame", {
				[React.Tag] = if mode.picks_sides then "teams split" else "teams",
				LayoutOrder = 1,
			}, sides),
			-- one place to move to is enough to show there is room to watch
			Spectators = React.createElement(Side, {
				label = "SPECTATORS",
				seats = spectators,
				room = game_modes.SPECTATOR_CAPACITY,
				open = if watching then 0 else 1,
				host = lobby.host,
				ready = lobby.ready,
				levels = lobby.levels or {},
				on_move = if watching
					then nil
					else function()
						props.act("move", game_modes.SPECTATOR_SIDE)
					end,
				move_label = "Watch",
				LayoutOrder = 2,
			}),
		}),
	})
end

return table.freeze({
	SeatsPanel = SeatsPanel,
})
