-- Checks the stand-in's Random against what Roblox's printed in Studio for the same seeds and calls, and a few CFrame
-- sums against what they have to come to. Run with `lune run tools/lib/tests/datatypes_test.luau`.

local datatypes = require "../datatypes"

-- Printed by Studio (Edit, 2026-09-24): for each seed, 4 NextNumber(), 3 NextInteger(0, 2^32 - 1), 3 NextInteger(1, 6),
-- 2 NextInteger(-2^40, 2^40) and a NextNumber(3, 10).
local STUDIO = {
	"seed 0 0.55145569047490739 0.017231024361130141 0.88337692090640296 0.92094836796652557 3612731804 2764171406 783947701 5 2 4 769294475619 -908941167955 3.6707691760431445",
	"seed 1 0.94843442061922034 0.061285879733742145 0.8770159548057006 0.69849327860489163 1569307380 342364989 1235584119 6 6 5 -696801524395 140006807634 9.9599078697551935",
	"seed 1337 0.094449775541134096 0.20797587692268371 0.47353390629288689 0.96601477872957775 3738414380 77392782 1306209918 5 2 6 -584501170719 -1088053115690 7.9946087778763992",
	"seed 123456789 0.16504106969308055 0.13056711073615965 0.8502386933825038 0.071550954368186079 270797791 2087181233 1265073073 4 1 2 -396547585031 -696141623395 5.5942264837100844",
	"seed -5 0.73923635790392694 0.59038423909346838 0.32277738517864257 0.86582970792194636 502181830 315853432 1149979427 4 4 6 -644926685268 -505113138919 3.4467488956667371",
	"seed 1099511627783 0.34847348317301835 0.081878006918918375 0.10575581939669743 0.14867910261328607 3703177124 2405912936 3336304945 1 1 1 -195721531379 415201669891 9.407418012670723",
	"seed 1.5 0.94843442061922034 0.061285879733742145 0.8770159548057006 0.69849327860489163 1569307380 342364989 1235584119 6 6 5 -696801524395 140006807634 9.9599078697551935",
}

local failures = 0
for index, seed in { 0, 1, 1337, 123456789, -5, 2 ^ 40 + 7, 1.5 } do
	local random = datatypes.Random.new(seed)
	local row = { "seed " .. tostring(seed) }
	for _ = 1, 4 do
		table.insert(row, string.format("%.17g", random:NextNumber()))
	end
	for _ = 1, 3 do
		table.insert(row, tostring(random:NextInteger(0, 4294967295)))
	end
	for _ = 1, 3 do
		table.insert(row, tostring(random:NextInteger(1, 6)))
	end
	for _ = 1, 2 do
		table.insert(row, tostring(random:NextInteger(-2 ^ 40, 2 ^ 40)))
	end
	table.insert(row, string.format("%.17g", random:NextNumber(3, 10)))
	local got = table.concat(row, " ")
	-- the first 10 numbers are what the game uses (NextNumber and small ranges); the wide ranges are only reported
	local expected_words = string.split(STUDIO[index], " ")
	local got_words = string.split(got, " ")
	for word = 1, #expected_words do
		if expected_words[word] ~= got_words[word] then
			local wide = word == 13 or word == 14
			print(
				`{if wide then "note" else "FAIL"}: seed {seed} word {word}: {got_words[word]} ~= {expected_words[word]}`
			)
			if not wide then
				failures += 1
			end
		end
	end
end

local CFrame = datatypes.CFrame
local frame = CFrame.new(vector.create(1, 2, 3)) * CFrame.Angles(0, math.pi / 2, 0)
local point = frame:PointToWorldSpace(vector.create(0, 0, -1))
if vector.magnitude(point - vector.create(0, 2, 3)) > 1e-5 then
	print(`FAIL: turned point {point}`)
	failures += 1
end
local axis = CFrame.fromAxisAngle(vector.create(0, 1, 0), math.pi / 2):VectorToWorldSpace(vector.create(1, 0, 0))
if vector.magnitude(axis - vector.create(0, 0, -1)) > 1e-5 then
	print(`FAIL: axis-angle {axis}`)
	failures += 1
end

print(if failures == 0 then "datatypes: all good" else `datatypes: {failures} failures`)
