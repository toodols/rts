local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local default_stylesheet = require(script.default_stylesheet)

if RunService:IsClient() then
	local stylesheets_folder = ReplicatedStorage:FindFirstChild "Stylesheets"
	if stylesheets_folder ~= nil then
		return {
			default_stylesheet = stylesheets_folder:FindFirstChild "DefaultStylesheet",
		}
	end
end

local stylesheets_folder = Instance.new "Folder"
stylesheets_folder.Name = "Stylesheets"
stylesheets_folder.Parent = ReplicatedStorage

default_stylesheet.Name = "DefaultStylesheet"
default_stylesheet.Parent = stylesheets_folder
return { default_stylesheet = default_stylesheet }
