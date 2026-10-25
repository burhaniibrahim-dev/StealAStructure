-- Responsibility: Client-only pickup presentation. Bobbing/spinning, collection effects, and sounds.
-- Pickup models are server-owned and replicate through Workspace.Pickups; this never grants or collects.
-- Pickups reserved for another player are hidden locally so nobody chases an egg they can't take.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local PickupVisuals = {}

local BOB_HEIGHT = 0.35
local BOB_SPEED = 2
local SPIN_SPEED = 1.5
local EFFECT_TIME = 0.35

local localPlayer = Players.LocalPlayer
local tracked = {} -- [Model] = { Visual, Base: CFrame, Phase }

local function hideLocally(model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 1
			descendant.Transparency = 1 -- local only; the server never changes pickup transparency
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
end

local function track(model)
	if not model:IsA("Model") or tracked[model] then
		return
	end
	local reservedUserId = model:GetAttribute("ReservedUserId")
	if reservedUserId and reservedUserId ~= localPlayer.UserId then
		hideLocally(model)
		return
	end
	local visual = model:WaitForChild("Visual", 5)
	if not visual or not model.Parent then
		return
	end
	tracked[model] = {
		Visual = visual,
		Base = visual:GetPivot(),
		Phase = math.random() * math.pi * 2,
	}
end

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

-- networker: Blink client module; itemDefinitions: shared ItemDefinitions
function PickupVisuals.start(networker, itemDefinitions)
	local folder = workspace:WaitForChild("Pickups")

	folder.ChildAdded:Connect(function(child)
		task.spawn(track, child)
	end)
	folder.ChildRemoved:Connect(function(child)
		tracked[child] = nil
	end)
	for _, child in folder:GetChildren() do
		task.spawn(track, child)
	end

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		for model, entry in tracked do
			if not model.Parent then
				tracked[model] = nil
				continue
			end
			local t = now + entry.Phase
			local offset = CFrame.new(0, math.sin(t * BOB_SPEED) * BOB_HEIGHT, 0) * CFrame.Angles(0, t * SPIN_SPEED, 0)
			entry.Visual:PivotTo(entry.Base * offset)
		end
	end)

	networker.PickupCollected.On(function(payload)
		local definition = itemDefinitions.Items[payload.ItemTypeId]
		playCollectEffect(payload.Position, if definition then definition.Color else Color3.new(1, 1, 1))
		if itemDefinitions.COLLECT_SOUND_ID ~= "" then
			local sound = Instance.new("Sound")
			sound.SoundId = itemDefinitions.COLLECT_SOUND_ID
			sound.Parent = SoundService
			sound.Ended:Once(function()
				sound:Destroy()
			end)
			sound:Play()
		end
	end)
end

return PickupVisuals
