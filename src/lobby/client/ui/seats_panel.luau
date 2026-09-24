-- Who is in the lobby and on which side, with the empty places left. In a team game each team is a column, and a
-- player moves to the other team by clicking one of its empty places; against the scavengers and in a free for all
-- everyone is in one list. Under them are the spectators, who come to the game only to watch: a player moves to
-- watching by clicking the place left there, and a spectator back to playing by clicking an empty seat.
--
-- Each player's row shows their resource bonus, which only a developer (shared/developers.luau) steps up and down;
-- anyone else sees it only when there is one. A player who is ready to start says so on their row.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local developers = require(ReplicatedStorage.Shared.developers)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local controls = require(script.Parent.controls)

type LobbyView = protocol.LobbyView
type SeatView = protocol.SeatView

local ACTIONS = protocol.ACTIONS

local local_player = Players.LocalPlayer

-- What a player's bonus can be changed with, passed down to where it is shown.
type BonusProps = {
	bonuses: { [string]: number },
	can_change: boolean,
	act: (action: string, argument: any?) -> (),
}

local function bonus_text(percent: number): string
	return if percent > 0 then `+{percent}%` else `{percent}%`
end

-- The bonus of the player `user_id`, with a step down and up either side of it for a developer. Nothing for anyone else
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
	local function step(by: number)
		bonus.act(ACTIONS.set_bonus, { user_id = props.user_id, percent = percent + by })
	end
	return React.createElement("Frame", {
		[React.Tag] = "bonus",
		LayoutOrder = props.LayoutOrder,
	}, {
		Down = React.createElement(controls.Button, {
			kind = "chip",
			tag = "step",
			label = "-",
			locked = percent <= game_modes.BONUS_MIN,
			on_press = function()
				step(-game_modes.BONUS_STEP)
			end,
			LayoutOrder = 1,
		}),
		Value = React.createElement("TextLabel", {
			[React.Tag] = if percent > 0
				then "bonus-value up"
				elseif percent < 0 then "bonus-value down"
				else "bonus-value",
			LayoutOrder = 2,
			Text = bonus_text(percent),
		}),
		Up = React.createElement(controls.Button, {
			kind = "chip",
			tag = "step",
			label = "+",
			locked = percent >= game_modes.BONUS_MAX,
			on_press = function()
				step(game_modes.BONUS_STEP)
			end,
			LayoutOrder = 3,
		}),
	})
end

-- `bonus` is given to a player's seat, not a spectator's.
local function Seat(props: { seat: SeatView, host: number, ready: boolean, bonus: BonusProps?, LayoutOrder: number })
	local you = props.seat.user_id == local_player.UserId
	return React.createElement("Frame", {
		[React.Tag] = if you then "seat you" else "seat",
		LayoutOrder = props.LayoutOrder,
	}, {
		Name = React.createElement("TextLabel", {
			[React.Tag] = "seat-name grow",
			LayoutOrder = 1,
			Text = props.seat.name,
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
				LayoutOrder = 5,
			})
			else nil,
	})
end

local function OpenSeat(props: { can_move: boolean, move_label: string, on_move: () -> (), LayoutOrder: number })
	return React.createElement("TextButton", {
		[React.Tag] = if props.can_move then "seat open movable" else "seat open",
		LayoutOrder = props.LayoutOrder,
		Text = if props.can_move then props.move_label else "Open",
		AutoButtonColor = false,
		Interactable = props.can_move,
		[React.Event.Activated] = props.on_move,
	})
end

local function Side(
	props: {
		label: string,
		seats: { SeatView },
		room: number,
		-- how many empty places to draw, if not all of them
		open: number?,
		host: number,
		-- the user ids of the players who are ready
		ready: { number },
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
	act: (action: string, argument: any?) -> (),
})
	local lobby = props.lobby
	local mode = game_modes.get(lobby.mode) :: game_modes.Mode

	local my_side: number? = nil
	local players: { SeatView } = {}
	local spectators: { SeatView } = {}
	for _, seat in lobby.seats do
		if seat.user_id == local_player.UserId then
			my_side = seat.side
		end
		table.insert(if seat.side == game_modes.SPECTATOR_SIDE then spectators else players, seat)
	end
	local watching = my_side == game_modes.SPECTATOR_SIDE
	local bonus: BonusProps = {
		bonuses = lobby.bonuses,
		can_change = developers.is_developer(local_player),
		act = props.act,
	}

	local sides: { [string]: any } = {}
	if mode.kind == "teams" then
		for side = 1, mode.sides do
			local on_side = {}
			for _, seat in players do
				if seat.side == side then
					table.insert(on_side, seat)
				end
			end
			sides[`Side{side}`] = React.createElement(Side, {
				label = `TEAM {side}`,
				seats = on_side,
				room = mode.per_side,
				host = lobby.host,
				ready = lobby.ready,
				bonus = bonus,
				on_move = if side ~= my_side
					then function()
						props.act(ACTIONS.move, side)
					end
					else nil,
				LayoutOrder = side,
			})
		end
	else
		sides.Everyone = React.createElement(Side, {
			label = if mode.kind == "scavengers"
				then "AGAINST THE SCAVENGERS"
				elseif mode.kind == "campaign" then "CO-OP: ALLIED"
				else "EVERY PLAYER FOR THEMSELVES",
			seats = players,
			room = mode.capacity,
			host = lobby.host,
			ready = lobby.ready,
			bonus = bonus,
			-- a spectator takes whichever seat is free
			on_move = if watching
				then function()
					props.act(ACTIONS.move, 1)
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
				[React.Tag] = if mode.kind == "teams" then "teams split" else "teams",
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
				on_move = if watching
					then nil
					else function()
						props.act(ACTIONS.move, game_modes.SPECTATOR_SIDE)
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
