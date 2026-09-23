-- Who is in the lobby and on which side, with the empty places left. In a team game each team is a column, and a
-- player moves to the other team by clicking one of its empty places; against the scavengers and in a free for all
-- everyone is in one list.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local game_modes = require(ReplicatedStorage.Shared.game_modes)

local protocol = require(ReplicatedStorage.Lobby.protocol)

type LobbyView = protocol.LobbyView
type SeatView = protocol.SeatView

local ACTIONS = protocol.ACTIONS

local local_player = Players.LocalPlayer

local function Seat(props: { seat: SeatView, host: number, LayoutOrder: number })
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
	})
end

local function OpenSeat(props: { can_move: boolean, on_move: () -> (), LayoutOrder: number })
	return React.createElement("TextButton", {
		[React.Tag] = if props.can_move then "seat open movable" else "seat open",
		LayoutOrder = props.LayoutOrder,
		Text = if props.can_move then "Move here" else "Open",
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
		host: number,
		-- nil when nobody can move to this side
		on_move: (() -> ())?,
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
			LayoutOrder = index,
		})
	end
	local on_move = props.on_move
	for index = #props.seats + 1, props.room do
		rows[`Open{index}`] = React.createElement(OpenSeat, {
			can_move = on_move ~= nil,
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

	local sides: { [string]: any } = {}
	if mode.kind == "teams" then
		local my_side = 0
		for _, seat in lobby.seats do
			if seat.user_id == local_player.UserId then
				my_side = seat.side
			end
		end
		for side = 1, mode.sides do
			local on_side = {}
			for _, seat in lobby.seats do
				if seat.side == side then
					table.insert(on_side, seat)
				end
			end
			sides[`Side{side}`] = React.createElement(Side, {
				label = `TEAM {side}`,
				seats = on_side,
				room = mode.per_side,
				host = lobby.host,
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
			label = if mode.kind == "scavengers" then "AGAINST THE SCAVENGERS" else "EVERY PLAYER FOR THEMSELVES",
			seats = lobby.seats,
			room = mode.capacity,
			host = lobby.host,
			on_move = nil,
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
				Text = `{#lobby.seats}/{mode.capacity}`,
			}),
		}),
		Sides = React.createElement("ScrollingFrame", {
			[React.Tag] = if mode.kind == "teams" then "sides split" else "sides",
			LayoutOrder = 3,
		}, sides),
	})
end

return table.freeze({
	SeatsPanel = SeatsPanel,
})
