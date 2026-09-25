-- Sound effects: weapons and explosions heard from where they happen, and the interface's clicks and its
-- notifications (an ally's ping) heard as they are. The sounds are our own, synthesized by tools/sound_pipeline.
--
-- A battle fires far more shots than can be told apart by ear, so each sound is held to a few playing at once
-- and a short gap between starts; what is over the limit is simply not heard.
--
-- A Sound made when it is wanted is silent until its audio has loaded, which is heard as lag. So each sound has its
-- voices made up front, one for each that may play at once, loaded as the game starts and played again and again.

local ContentProvider = game:GetService "ContentProvider"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local SoundService = game:GetService "SoundService"
local Workspace = game:GetService "Workspace"

local sound_ids = require(ReplicatedStorage.Client.sound_ids)

export type SoundName =
	"laser"
	| "cannon"
	| "explosion_small"
	| "explosion_large"
	| "dgun"
	| "anti_air"
	| "click"
	| "notify"

type Kind = {
	volume: number,
	-- the shortest time between two starts, in seconds, and the most that play at once
	gap: number,
	most: number,
	-- how far the pitch strays either way from one play to the next, so a volley is not one note over and over
	pitch_spread: number,
	-- For a sound heard from a point in the world (`play_at`) rather than as it is (`play_ui`): it is at full volume
	-- within `near` studs of the camera, and from there falls off with distance (twice as far, half as loud), until
	-- it is cut off at `far`. At the camera's usual height the ground in the middle of the view is about 80 away.
	near: number?,
	far: number?,
}

local KINDS: { [SoundName]: Kind } = {
	laser = { volume = 0.49, gap = 0.035, most = 6, pitch_spread = 0.08, near = 30, far = 500 },
	cannon = { volume = 1.43, gap = 0.04, most = 6, pitch_spread = 0.1, near = 30, far = 600 },
	explosion_small = { volume = 2.73, gap = 0.05, most = 5, pitch_spread = 0.12, near = 40, far = 800 },
	explosion_large = { volume = 2.32, gap = 0.12, most = 3, pitch_spread = 0.08, near = 60, far = 1400 },
	dgun = { volume = 1.6, gap = 0.1, most = 3, pitch_spread = 0.05, near = 40, far = 900 },
	anti_air = { volume = 1.4, gap = 0.04, most = 6, pitch_spread = 0.06, near = 30, far = 600 },
	click = { volume = 0.66, gap = 0.03, most = 2, pitch_spread = 0 },
	-- loud enough to be heard over a battle, since a ping is a call for attention
	notify = { volume = 1.2, gap = 0.08, most = 2, pitch_spread = 0 },
}

-- One of a sound's voices: a Sound, and for a sound heard from the world, the attachment it is moved to each play.
type Voice = { sound: Sound, anchor: Attachment? }

local voices: { [SoundName]: { Voice } }? = nil
local last_start: { [SoundName]: number } = {}

-- Makes every sound's voices, once, and starts loading their audio.
local function all_voices(): { [SoundName]: { Voice } }
	if voices ~= nil then
		return voices
	end
	local group = Instance.new "SoundGroup"
	group.Name = "Effects"
	group.Volume = 1
	group.Parent = SoundService
	local made: { [SoundName]: { Voice } } = {}
	local sounds: { Instance } = {}
	for name, kind in KINDS do
		made[name] = {}
		for _ = 1, kind.most do
			local sound = Instance.new "Sound"
			sound.Name = name
			sound.SoundId = sound_ids[name]
			sound.SoundGroup = group
			local anchor: Attachment? = nil
			if kind.near ~= nil and kind.far ~= nil then
				sound.RollOffMode = Enum.RollOffMode.InverseTapered
				sound.RollOffMinDistance = kind.near
				sound.RollOffMaxDistance = kind.far
				local attachment = Instance.new "Attachment"
				attachment.Name = `Sound_{name}`
				attachment.Parent = Workspace.Terrain
				sound.Parent = attachment
				anchor = attachment
			else
				sound.Parent = group
			end
			table.insert(made[name], { sound = sound, anchor = anchor })
			table.insert(sounds, sound)
		end
	end
	voices = made
	task.spawn(ContentProvider.PreloadAsync, ContentProvider, sounds)
	return made
end

-- A voice of this sound free to start now, if one is and it has been long enough since the last start.
local function claim(name: SoundName): Voice?
	local now = os.clock()
	if now - (last_start[name] or -math.huge) < KINDS[name].gap then
		return nil
	end
	for _, voice in all_voices()[name] do
		if voice.sound.IsPlaying == false then
			last_start[name] = now
			return voice
		end
	end
	return nil
end

local function start(name: SoundName, voice: Voice, volume_scale: number, pitch: number)
	local kind = KINDS[name]
	local sound = voice.sound
	sound.Volume = kind.volume * volume_scale
	sound.PlaybackSpeed = pitch * (1 + (math.random() * 2 - 1) * kind.pitch_spread)
	sound.TimePosition = 0
	sound:Play()
end

-- Plays a sound as it is, heard the same wherever the camera is: the interface's.
local function play_ui(name: SoundName)
	local voice = claim(name)
	if voice ~= nil then
		start(name, voice, 1, 1)
	end
end

-- Plays a sound from a point in the world. `volume_scale` and `pitch` shape one play of it (a nuke is a big
-- explosion played slow and loud). Anything too far from the camera to be heard is not played at all.
local function play_at(name: SoundName, at: Vector3, volume_scale: number?, pitch: number?)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	if (camera.CFrame.Position - at).Magnitude > (KINDS[name].far or 0) then
		return
	end
	local voice = claim(name)
	if voice == nil then
		return
	end
	local anchor = voice.anchor :: Attachment
	anchor.WorldPosition = at
	start(name, voice, volume_scale or 1, pitch or 1)
end

-- Every button in the interface clicks when pressed, whichever panel it is on, without each having to say so. It
-- clicks as the button goes down, not when it is let go (`Activated`), which would be heard late.
local hooked: { [GuiButton]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function hook_button(instance: Instance)
	if instance:IsA "GuiButton" == false or hooked[instance :: GuiButton] then
		return
	end
	local button = instance :: GuiButton
	hooked[button] = true
	button.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if
			(kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch)
			and button.Interactable
			and button.Active
		then
			play_ui "click"
		end
	end)
end

local function init_clicks()
	all_voices()
	local player_gui = Players.LocalPlayer:WaitForChild "PlayerGui"
	for _, descendant in player_gui:GetDescendants() do
		hook_button(descendant)
	end
	player_gui.DescendantAdded:Connect(hook_button)
end

return table.freeze({
	init_clicks = init_clicks,
	play_at = play_at,
	play_ui = play_ui,
})
