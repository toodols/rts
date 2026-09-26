--!strict
-- The guide's state (Client.tutorial) as hooks: each re-renders whenever the step, or what is done in it, changes, and
-- returns what it subscribes to.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local tutorial = require(ReplicatedStorage.Client.tutorial)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

type State = tutorial.State

-- What `read` says of the guide, kept up to date.
local function use_read<T>(read: () -> T): T
	return use_store.use_store(read, tutorial.subscribe)
end

local function use_tutorial(): State
	return use_read(tutorial.get)
end

-- What the build menu should point out right now, if anything.
local function use_build_target(): string?
	return use_read(tutorial.build_target)
end

-- Which command the commands list should point out right now, if any.
local function use_command_target(): string?
	return use_read(tutorial.command_target)
end

return table.freeze({
	use_tutorial = use_tutorial,
	use_build_target = use_build_target,
	use_command_target = use_command_target,
})
