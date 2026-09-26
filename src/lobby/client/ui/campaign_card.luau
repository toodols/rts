--!strict
-- The way into the campaign, over the lobby browser: a card that is itself the button, saying how far this player is
-- through the campaign, with an arrow at its right end. The stylesheet (.campaign-card in lobby.scss) does most of its
-- motion: the face brightening, the glow, the title stepping in, the arrow walking out with a second chevron trailing
-- it, the dip when pressed. This does what outlass can't: sweeping the sheen across the card as it lights, lighting it
-- while a gamepad has it selected, and holding the campaign back a moment once it's pressed so the arrow is seen to
-- shoot off.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TweenService = game:GetService "TweenService"

local React = require(ReplicatedStorage.Packages.react)

local campaign_standing = require(ReplicatedStorage.ClientShared.campaign_standing)

local campaign = require(script.Parent.campaign)

-- An element's properties: strict mode cannot type a table of them that mixes tags, properties and handlers.
type Props = { [any]: any }

-- The sheen frame carries a band of light across its middle, and is swept from a card's width left of the card to a
-- card's width right of it, where it stays parked; the card clips it.
local SHEEN = TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SHEEN_START = UDim2.fromScale(-1, 0)
local SHEEN_PARKED = UDim2.fromScale(1, 0)
-- as long as the arrow's launch takes to clear the card, near enough (its transition is 0.2s)
local LAUNCH_SECONDS = 0.16

-- A chevron, drawn as the top and right edges of a square the stylesheet turns 45 degrees.
local function Chevron(props: { tag: string })
	return React.createElement("Frame", {
		[React.Tag] = `campaign-card-chevron {props.tag}`,
	}, {
		Top = React.createElement("Frame", { [React.Tag] = "campaign-card-chevron-bar top" }),
		Side = React.createElement("Frame", { [React.Tag] = "campaign-card-chevron-bar side" }),
	})
end

local function CampaignCard(props: { on_open: () -> (), LayoutOrder: number })
	local progress = campaign_standing.use_standing()
	local done, missions = campaign.mission_counts(progress.completed)
	local unlocked, lockable = campaign.unlock_counts(progress.unlocks)

	-- selected by a gamepad, which Roblox's styles have no state for, so the card lights by a tag instead
	local selected, set_selected = React.useState(false)
	-- pressed and let go, and the campaign about to open
	local launching, set_launching = React.useState(false)
	local sheen_ref = React.useRef(nil :: Frame?)
	local sweep_ref = React.useRef(nil :: Tween?)
	local launch_ref = React.useRef(nil :: thread?)

	React.useEffect(function()
		return function()
			if sweep_ref.current ~= nil then
				sweep_ref.current:Cancel()
			end
			if launch_ref.current ~= nil then
				task.cancel(launch_ref.current)
			end
		end
	end, {})

	local function sweep()
		local sheen = sheen_ref.current
		if sheen == nil then
			return
		end
		if sweep_ref.current ~= nil then
			sweep_ref.current:Cancel()
		end
		sheen.Position = SHEEN_START
		local tween = TweenService:Create(sheen, SHEEN, { Position = SHEEN_PARKED })
		sweep_ref.current = tween
		tween:Play()
	end

	local function launch()
		if launch_ref.current ~= nil then
			return
		end
		set_launching(true)
		launch_ref.current = task.delay(LAUNCH_SECONDS, function()
			launch_ref.current = nil
			set_launching(false)
			props.on_open()
		end)
	end

	local tag = "campaign-card"
	if selected then
		tag ..= " selected"
	end
	if launching then
		tag ..= " launching"
	end

	return React.createElement("Frame", {
		[React.Tag] = "campaign-strip",
		LayoutOrder = props.LayoutOrder,
	}, {
		Card = React.createElement(
			"TextButton",
			{
				[React.Tag] = tag,
				Text = "",
				AutoButtonColor = false,
				[React.Event.MouseEnter] = sweep,
				[React.Event.SelectionGained] = function()
					set_selected(true)
					sweep()
				end,
				[React.Event.SelectionLost] = function()
					set_selected(false)
				end,
				[React.Event.Activated] = launch,
			} :: Props,
			{
				Glow = React.createElement("Frame", { [React.Tag] = "campaign-card-glow" }),
				Edge = React.createElement("Frame", { [React.Tag] = "campaign-card-edge" }),
				Content = React.createElement("Frame", {
					[React.Tag] = "campaign-card-content",
				}, {
					Texts = React.createElement("Frame", {
						[React.Tag] = "campaign-strip-texts grow",
						LayoutOrder = 1,
					}, {
						Title = React.createElement("TextLabel", {
							[React.Tag] = "campaign-strip-title heading",
							LayoutOrder = 1,
							Text = "Campaign",
						}),
						Progress = React.createElement("TextLabel", {
							[React.Tag] = "campaign-strip-progress",
							LayoutOrder = 2,
							Text = `{done}/{missions} missions complete · {unlocked}/{lockable} units unlocked`,
						}),
					}),
					Arrow = React.createElement("Frame", {
						[React.Tag] = "campaign-card-arrow",
						LayoutOrder = 2,
					}, {
						Trail = React.createElement(Chevron, { tag = "trail" }),
						Lead = React.createElement(Chevron, { tag = "lead" }),
					}),
				}),
				Sheen = React.createElement("Frame", {
					[React.Tag] = "campaign-card-sheen",
					Position = SHEEN_PARKED,
					ref = sheen_ref,
				}),
			}
		),
	})
end

return table.freeze({
	CampaignCard = CampaignCard,
})
