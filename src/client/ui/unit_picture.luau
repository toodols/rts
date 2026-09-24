-- A def's own art (Client.art), `def_name`'s, in a ViewportFrame: seen from above and ahead, as the camera sees it on
-- the field, framed round the model's bounds. While its art is still being built it waits for it; a def with no art
-- at all shows `fallback` as text instead, or nothing.
--
-- With `spin` (radians a second) the camera circles the model, so it turns slowly on the spot.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local art = require(ReplicatedStorage.Client.art)

-- where the camera looks from, before any spin, and how wide its lens is
local DIRECTION = Vector3.new(0.35, 1, 0.9).Unit
local FOV = 30

local function UnitPicture(props: {
	def_name: string,
	tag: string,
	Position: any?,
	LayoutOrder: number?,
	spin: number?,
	fallback: string?,
})
	local frame_ref = React.useRef(nil :: ViewportFrame?)
	local built, set_built = React.useState(0)
	local missing, set_missing = React.useState(false)

	React.useEffect(function(): (() -> ())?
		local viewport = frame_ref.current
		if viewport == nil then
			return nil
		end
		local model = art.ghost(props.def_name)
		if model == nil then
			if art.pending(props.def_name) then
				return art.when_built(props.def_name, function()
					set_built(function(count: number)
						return count + 1
					end)
				end)
			end
			set_missing(true)
			return nil
		end
		set_missing(false)
		local box, size = model:GetBoundingBox()
		local center = box.Position
		local distance = (size.Magnitude / 2) / math.sin(math.rad(FOV / 2))
		local camera = Instance.new "Camera"
		camera.FieldOfView = FOV
		local function aim(yaw: number)
			local direction = CFrame.Angles(0, yaw, 0):VectorToWorldSpace(DIRECTION)
			camera.CFrame = CFrame.lookAt(center + direction * distance, center)
		end
		aim(0)
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		model.Parent = viewport

		local spinning: RBXScriptConnection? = nil
		local spin = props.spin
		if spin ~= nil and spin ~= 0 then
			local began = os.clock()
			spinning = RunService.RenderStepped:Connect(function()
				aim((os.clock() - began) * spin)
			end)
		end
		return function()
			if spinning ~= nil then
				spinning:Disconnect()
			end
			model:Destroy()
			camera:Destroy()
		end
	end, { props.def_name, props.spin, built } :: { any })

	if missing and props.fallback ~= nil then
		return React.createElement("TextLabel", {
			[React.Tag] = `{props.tag} art-fallback`,
			LayoutOrder = props.LayoutOrder,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = props.Position,
			Text = props.fallback,
		})
	end

	return React.createElement("ViewportFrame", {
		[React.Tag] = props.tag,
		ref = frame_ref,
		LayoutOrder = props.LayoutOrder,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = props.Position,
		Ambient = Color3.fromRGB(150, 150, 160),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.5, -1, -0.7),
	})
end

return table.freeze({
	UnitPicture = UnitPicture,
})
