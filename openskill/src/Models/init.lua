--[[
Don't require this unless you want all models to be loaded
If you're going to use only one model, require it directly to save memory
]]

local models = {}
for _, v in ipairs(script:GetChildren()) do
	models[v.Name] = require(v)
end
return models