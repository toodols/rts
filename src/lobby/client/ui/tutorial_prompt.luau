--!strict
-- The box a player who has not finished the tutorial is met with in the lobby, urging them to play it: Play Tutorial
-- starts it, as its Play on the campaign screen does, and the other button puts it off. Put off once, it asks again,
-- harder (every mission, and so every unit past the starting ones, waits on the tutorial: campaign.is_open); put off
-- twice, it is gone until they next come to the lobby. Over everything else, with the screen behind it shaded and not
-- to be clicked through.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local controls = require(script.Parent.controls)

-- What the box says each time it asks, in order. The text is rich text.
local PLEAS: { { title: string, text: string, play: string, later: string } } = {
	{
		title = "New Here?",
		text = `<font size="32">We have a tutorial.</font> <font size="30">A tremendous tutorial.</font> <font size="28">Probably the best tutorial anywhere.</font> <font size="26">People are saying it.</font> <font size="24">Many, many people.</font> <font size="22">They come up to me—grown adults, very successful people—and they say, “Sir, this tutorial is incredible.”</font> <font size="20">They say it with tears in their eyes.</font> <font size="18">Tears.</font> <font size="16">Nobody has seen a tutorial like this before.</font> <font size="14">Believe me.</font>`,
		play = "Play Tutorial",
		later = "nah i'd win",
	},
	{
		title = "Are you sure?",
		text = `We believe in free will. But also all the units in the game are locked behind the tutorial.`,
		play = "Play Tutorial",
		later = "no",
	},
}

-- `plea` is which of PLEAS it is asking with.
local function TutorialPrompt(props: {
	ui_scale: number,
	plea: number,
	on_play: () -> (),
	on_later: () -> (),
})
	local plea = PLEAS[props.plea]
	-- a button rather than a frame, so that a click beside the box lands on it and not on the lobby under it
	return React.createElement("TextButton", {
		[React.Tag] = "prompt-scrim",
		Text = "",
		AutoButtonColor = false,
	}, {
		Box = React.createElement("Frame", {
			[React.Tag] = "prompt panel",
		}, {
			Scale = React.createElement("UIScale", { Scale = props.ui_scale }),
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
					Text = plea.title,
				}),
			}),
			Text = React.createElement("TextLabel", {
				[React.Tag] = "prompt-text",
				LayoutOrder = 3,
				Text = plea.text,
			}),
			Actions = React.createElement("Frame", {
				[React.Tag] = "prompt-actions",
				LayoutOrder = 4,
			}, {
				Later = React.createElement(controls.Button, {
					kind = "button",
					label = plea.later,
					on_press = props.on_later,
					LayoutOrder = 1,
				}),
				Play = React.createElement(controls.Button, {
					kind = "button",
					tag = "primary",
					label = plea.play,
					on_press = props.on_play,
					LayoutOrder = 2,
				}),
			}),
		}),
	})
end

return table.freeze({
	PLEAS = #PLEAS,
	TutorialPrompt = TutorialPrompt,
})
