-- Responsibility: Client-only egg presentation. Bobbing/spinning, collection effects, and sounds.
-- Egg models are local clones owned by SpawningVisuals, which calls track/untrack as it adds and removes them.
-- This module never creates or destroys egg models, and never grants or collects.

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local PickupVisuals = {}

local BOB_HEIGHT = 0.35
local BOB_SPEED = 2
local SPIN_SPEED = 1.5
local EFFECT_TIME = 0.35

local COLLECT_SOUND_ID = ""	-- Optional collect sound; SUBJECT TO CHANGE

local tracked = {} -- [PickupId] = { Instance, Base: CFrame, Phase }
local itemCatalog = nil
local renderConnection = nil

local function playCollectEffect(position, color)
	local burst = Instance.new("Part")
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.one
	burst.Color = color
	burst.Material = Enum.Material.Neon
	burst.Transparency = 0.2
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CanTouch = false
	burst.CFrame = CFrame.new(position)
	burst.Parent = workspace

	local tween = TweenService:Create(burst, TweenInfo.new(EFFECT_TIME), { Size = Vector3.one * 4, Transparency = 1 })
	tween.Completed:Once(function()
		burst:Destroy()
	end)
	tween:Play()
end

local function playCollectSound()
	if COLLECT_SOUND_ID == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = COLLECT_SOUND_ID
	sound.Parent = SoundService
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
end

-- SpawningVisuals onAdded. Eggs without a model (unresolved template) have nothing to animate
function PickupVisuals.track(entry)
	local instance = entry.Instance
	if not instance then
		return
	end
	tracked[entry.PickupId] = {
		Instance = instance,
		Base = instance:GetPivot(),
		Phase = math.random() * math.pi * 2,
	}
end

-- SpawningVisuals onRemoved. Only a server-confirmed collection plays the effect
function PickupVisuals.untrack(entry, reason)
	tracked[entry.PickupId] = nil
	if reason == "Collected" then
		local definition = itemCatalog and itemCatalog[entry.ItemTypeId]
		playCollectEffect(entry.Position, if definition then definition.Color else Color3.new(1, 1, 1))
		playCollectSound()
	end
end

-- catalog: Shared ItemDefintions. One render loop for every tracked egg
function PickupVisuals.start(catalog)
	itemCatalog = catalog
	if renderConnection then
		return
	end
	renderConnection = RunService.RenderStepped:Connect(function()
		local now = os.clock()
		for pickupId, entry in tracked do
			if not entry.Instance.Parent then
				tracked[pickupId] = nil
				continue
			end
			local t = now + entry.Phase
			local offset = CFrame.new(0, math.sin(t * BOB_SPEED) * BOB_HEIGHT, 0) * CFrame.Angles(0, t * SPIN_SPEED, 0)
			entry.Instance:PivotTo(entry.Base * offset)
		end
	end)
end

return PickupVisuals
