local TestKit = require("../TestKit")
local describe, it, eq, truthy, falsy = TestKit.describe, TestKit.it, TestKit.eq, TestKit.truthy, TestKit.falsy

local SpawningVisuals = require("../../src/ReplicatedStorage/Shared/Features/Visuals/SpawningVisuals")

-- Minimal stand-in for a BasePart template 2 studs tall: Clone, IsA, GetDescendants, PivotTo, Destroy, Size, Position
local function fakeTemplate(modelName, world)
	local template = { Name = modelName, Parent = nil, Pivot = nil, Destroyed = false, Size = Vector3.new(1, 2, 1) }
	function template:IsA(className)
		return className == "BasePart"
	end
	function template:GetDescendants()
		return {}
	end
	function template:PivotTo(cframe)
		self.Pivot = cframe
		self.CFrame = cframe
		self.Position = cframe.Position
	end
	function template:Destroy()
		self.Destroyed = true
		self.Parent = nil
		world.live -= 1
	end
	function template:Clone()
		world.clones += 1
		world.live += 1
		local clone = fakeTemplate(modelName, world)
		clone.SourceModel = modelName
		return clone
	end
	return template
end

-- Model template like the authored eggs: a 2-stud Root mesh at the pivot plus a much taller Hitbox
local function fakeModelTemplate(modelName, world)
	local function part(name, size)
		local p = { Name = name, Size = size, CFrame = CFrame.new() }
		function p:IsA(className)
			return className == "BasePart"
		end
		return p
	end
	local template = { Name = modelName, Parent = nil, Pivot = CFrame.new() }
	template.Root = part("Root", Vector3.new(1, 2, 1))
	template.Hitbox = part("Hitbox", Vector3.new(6, 8, 6))
	function template:IsA(className)
		return className == "Model"
	end
	function template:GetDescendants()
		return { self.Root, self.Hitbox }
	end
	function template:FindFirstChild(name)
		return if name == "Root" then self.Root elseif name == "Hitbox" then self.Hitbox else nil
	end
	function template:GetBoundingBox()
		return self.Pivot, Vector3.new(6, 8, 6) -- the Hitbox dominates the whole box
	end
	function template:PivotTo(cframe)
		self.Pivot = cframe
		self.Root.CFrame = cframe
		self.Hitbox.CFrame = cframe
	end
	function template:Destroy()
		world.live -= 1
	end
	function template:Clone()
		world.clones += 1
		world.live += 1
		return fakeModelTemplate(modelName, world)
	end
	return template
end

local function setup()
	-- groundY: what the client raycast finds (nil = no hit). instantEmerge: finish the dig-out immediately
	local world = {
		clones = 0,
		live = 0,
		templates = {},
		added = {},
		removed = {},
		warnings = {},
		groundY = 0,
		instantEmerge = true,
		emerges = {}, -- pending digs: { Instance, From, To, Done, Cancelled }
		rayIgnore = nil,
	}
	for _, name in { "SnowEgg", "IceEgg" } do
		world.templates[name] = fakeTemplate(name, world)
	end
	local folder = { Name = "LocalEggs" }
	local visuals = SpawningVisuals.new({
		itemCatalog = TestKit.ItemCatalog(),
		getTemplate = function(modelName)
			return world.templates[modelName]
		end,
		parent = folder,
		onAdded = function(entry)
			table.insert(world.added, entry.PickupId)
		end,
		onRemoved = function(entry, reason)
			table.insert(world.removed, { PickupId = entry.PickupId, Reason = reason })
		end,
		warn = function(message)
			table.insert(world.warnings, message)
		end,
		findGroundY = function(_, ignore)
			world.rayIgnore = ignore
			return world.groundY
		end,
		playEmerge = function(instance, from, to, onDone)
			local dig = { Instance = instance, From = from, To = to, Cancelled = false }
			function dig.Done()
				instance:PivotTo(to)
				onDone()
			end
			if world.instantEmerge then
				dig.Done()
			else
				table.insert(world.emerges, dig)
			end
			return function()
				dig.Cancelled = true
			end
		end,
	})
	return visuals, world, folder
end

local function record(pickupId, itemTypeId)
	return {
		PickupId = pickupId,
		ItemTypeId = itemTypeId or "SnowEgg",
		Amount = 1,
		ZoneId = "Meadow",
		Position = Vector3.new(pickupId, 1, 0),
		RemainingLifetime = 30,
	}
end

describe("Local egg instances", function()
	it("clones the authored template into the local folder at the server position", function()
		local visuals, world, folder = setup()
		local entry = visuals:Spawn(record(1))
		truthy(entry, "spawned")
		eq(world.clones, 1, "one clone")
		eq(entry.Instance.Parent, folder, "parented locally")
		eq(entry.Instance.Name, "Egg_1", "named by PickupId")
		eq(entry.Instance.Pivot.Position.X, 1, "placed at the server position")
	end)
end)

local GAP = 2 * SpawningVisuals.HOVER_RATIO -- the fixture egg is 2 studs tall

local function near(actual, expected, label)
	truthy(math.abs(actual - expected) < 1e-6, `{label}: expected {expected}, got {actual}`)
end

describe("Digging out of the ground", function()
	-- Fixture egg: 2 studs tall, server position y = 1, so its bottom starts at y = 0. Gap = 2 * HOVER_RATIO
	it("rests a size-scaled gap above the ground the client raycast finds", function()
		local visuals, world, folder = setup()
		local entry = visuals:Spawn(record(1))
		near(entry.Instance.Pivot.Position.Y, 1 + GAP, "bottom at ground 0 + gap")
		eq(world.rayIgnore, folder, "the ray ignores the local egg folder")

		world.groundY = -2
		entry = visuals:Spawn(record(2))
		near(entry.Instance.Pivot.Position.Y, -1 + GAP, "follows lower ground: bottom at -2 + gap")
	end)

	it("a Model is measured by its Root part, not the Hitbox", function()
		local visuals, world = setup()
		world.templates.SnowEgg = fakeModelTemplate("SnowEgg", world)
		local entry = visuals:Spawn(record(1))
		near(entry.Instance.Pivot.Position.Y, 1 + GAP, "same rest as a 2-stud egg; the 8-stud Hitbox is ignored")
	end)

	it("uses the server position as the bottom when the ray hits nothing", function()
		local visuals, world = setup()
		world.groundY = nil
		local entry = visuals:Spawn(record(1))
		near(entry.Instance.Pivot.Position.Y, 2 + GAP, "bottom at server y 1 + gap")
	end)

	it("starts fully buried and digs up to the resting spot", function()
		local visuals, world = setup()
		world.instantEmerge = false
		local entry = visuals:Spawn(record(1))
		local dig = world.emerges[1]
		truthy(dig, "dig started")
		near(dig.From.Position.Y, -1.0, "buried: top level with the ground")
		near(dig.To.Position.Y, 1 + GAP, "rests above the ground")
		near(entry.Instance.Pivot.Position.Y, -1.0, "shown buried first")
	end)

	it("hands the egg to idle animation only after it has emerged", function()
		local visuals, world = setup()
		world.instantEmerge = false
		visuals:Spawn(record(1))
		eq(#world.added, 0, "not while digging")
		world.emerges[1].Done()
		eq(#world.added, 1, "after emerging")
	end)

	it("removal mid-dig cancels the dig and never starts idle animation", function()
		local visuals, world = setup()
		world.instantEmerge = false
		visuals:Spawn(record(1))
		visuals:Remove(1, "Collected")
		truthy(world.emerges[1].Cancelled, "dig cancelled")
		eq(world.live, 0, "clone destroyed")
		world.emerges[1].Done() -- a late completion must do nothing
		eq(#world.added, 0, "never tracked")
	end)

	it("a repeated spawn for the same PickupId never duplicates", function()
		local visuals, world = setup()
		visuals:Spawn(record(1))
		eq(visuals:Spawn(record(1)), nil, "second spawn ignored")
		eq(world.clones, 1, "still one clone")
		eq(visuals:Count(), 1, "one entry")
	end)

	it("removal destroys the clone and a late spawn can't bring it back", function()
		local visuals, world = setup()
		visuals:Spawn(record(1))
		visuals:Remove(1, "Collected")
		eq(world.live, 0, "clone destroyed")
		eq(world.removed[1].Reason, "Collected", "reason passed on")
		eq(visuals:Spawn(record(1)), nil, "late spawn ignored")
		eq(world.live, 0, "nothing resurrected")
		eq(visuals:Remove(1, "Expired"), nil, "second removal is a no-op")
		eq(#world.removed, 1, "removed once")
	end)

	it("never removes on its own when the remaining lifetime runs out", function()
		local visuals = setup()
		local data = record(1)
		data.RemainingLifetime = 0
		visuals:Spawn(data)
		eq(visuals:Count(), 1, "kept until the server says so")
	end)
end)

describe("Snapshot reconciliation", function()
	it("replaces the set: stale eggs go, missing eggs come, existing eggs aren't recloned", function()
		local visuals, world = setup()
		visuals:Spawn(record(1))
		visuals:Spawn(record(2))
		visuals:ApplySnapshot({ record(2), record(3) })
		eq(visuals:Get(1), nil, "egg 1 removed")
		truthy(visuals:Get(2), "egg 2 kept")
		truthy(visuals:Get(3), "egg 3 added")
		eq(world.clones, 3, "egg 2 not cloned twice")
		eq(world.live, 2, "two live clones")
	end)

	it("applying the same snapshot twice changes nothing", function()
		local visuals, world = setup()
		visuals:ApplySnapshot({ record(1), record(2) })
		visuals:ApplySnapshot({ record(1), record(2) })
		eq(world.clones, 2, "no duplicates")
		eq(#world.removed, 0, "nothing removed")
	end)

	it("an empty snapshot clears everything", function()
		local visuals, world = setup()
		visuals:Spawn(record(1))
		visuals:ApplySnapshot({})
		eq(visuals:Count(), 0, "cleared")
		eq(world.live, 0, "clones destroyed")
	end)
end)

describe("Missing templates", function()
	it("falls back to the VisualFallback egg's model and warns, keeping the egg's identity", function()
		local visuals, world = setup()
		world.templates.IceEgg = nil
		local entry = visuals:Spawn(record(1, "IceEgg"))
		eq(entry.ItemTypeId, "IceEgg", "identity kept")
		eq(entry.Instance.SourceModel, "SnowEgg", "fallback visual")
		truthy(world.warnings[1]:find("MODEL OF IceEgg doesnt exist", 1, true), "warned")
	end)

	it("tracks the egg without a model when the fallback is missing too, without crashing", function()
		local visuals, world = setup()
		world.templates.IceEgg = nil
		world.templates.SnowEgg = nil
		local entry = visuals:Spawn(record(1, "IceEgg"))
		truthy(entry, "tracked")
		eq(entry.Instance, nil, "no model")
		eq(world.clones, 0, "nothing generated")
		truthy(visuals:Remove(1, "Expired"), "removal still works")
	end)
end)

describe("Proximity trigger", function()
	it("fires once on entering range, not again until the player leaves and returns", function()
		local visuals = setup()
		visuals:Spawn(record(10))
		local requests = 0
		local function onEnter()
			requests += 1
		end
		visuals:UpdateProximity(Vector3.new(0, 1, 0), 3, onEnter)
		eq(requests, 0, "out of range")
		visuals:UpdateProximity(Vector3.new(9, 1, 0), 3, onEnter)
		eq(requests, 1, "entered")
		for _ = 1, 5 do
			visuals:UpdateProximity(Vector3.new(9.5, 1, 0), 3, onEnter)
		end
		eq(requests, 1, "no retry while standing in range (e.g. full stack)")
		visuals:UpdateProximity(Vector3.new(0, 1, 0), 3, onEnter)
		visuals:UpdateProximity(Vector3.new(10, 1, 0), 3, onEnter)
		eq(requests, 2, "re-entering triggers again")
	end)

	it("only considers this player's own eggs", function()
		local visuals = setup()
		local seen = {}
		visuals:Spawn(record(1))
		visuals:UpdateProximity(Vector3.new(1, 1, 0), 3, function(entry)
			table.insert(seen, entry.PickupId)
		end)
		eq(#seen, 1, "one")
		eq(seen[1], 1, "its own egg")
		falsy(visuals:Get(2), "nothing else is known to this client")
	end)
end)

describe("Per-egg UI", function()
	it("decorates each new egg once and cleans the decoration up on removal, even mid-dig", function()
		local world = { clones = 0, live = 0 }
		local decorated, cleaned = {}, 0
		local visuals = SpawningVisuals.new({
			itemCatalog = TestKit.ItemCatalog(),
			getTemplate = function(modelName)
				return fakeTemplate(modelName, world)
			end,
			parent = {},
			findGroundY = function()
				return 0
			end,
			playEmerge = function()
				return function() end -- never finishes: the egg is still digging
			end,
			decorate = function(instance, entry)
				table.insert(decorated, { Instance = instance, Entry = entry })
				return function()
					cleaned += 1
				end
			end,
			warn = function() end,
		})
		local entry = visuals:Spawn(record(1))
		visuals:Spawn(record(1)) -- repeat
		eq(#decorated, 1, "decorated once")
		eq(decorated[1].Instance, entry.Instance, "with the egg's own clone")
		eq(decorated[1].Entry.RemainingLifetime, 30, "entry carries the lifetime to count down from")
		visuals:Remove(1, "Collected")
		eq(cleaned, 1, "cleaned up on removal")
	end)
end)
