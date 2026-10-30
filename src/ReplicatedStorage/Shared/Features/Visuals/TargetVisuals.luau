-- Responsibility: How this client presents the server's target models (Workspace.Targets). Presentation only:
-- every model is a server entity everyone shares, and the server alone decides claims, damage, and timing.
-- Separate from the egg visuals (SpawningVisuals / PickupVisuals), which stay untouched.
--
-- Viewer modes (GetMode, pure):
--   Starter        Normal; Faded while this viewer is in a run; Gray while on reward cooldown
--   Scoring        Owner (fully visible) for its owner; for everyone else Hidden until the owner's acknowledgment
--                  (Revealed attribute), then Faded
-- Clicks resolve only to Normal starters and the viewer's own targets (IsClickable); the server re-checks everything.
--
-- How it hides and fades without fighting replication: it only ever adds local transparency
-- (LocalTransparencyModifier on BaseParts, Decals and Textures), so authored transparency (e.g. invisible hitboxes)
-- is never lowered. GUIs, particles, beams, trails, and lights are switched off locally while fully hidden and get
-- their authored Enabled back afterwards. Gray is a local Color/Material override with the originals restored;
-- transparency can't change colour.
--
-- Animations: appear (fade in, scale up from APPEAR_SCALE) when the model becomes visible to this viewer, leave
-- (the reverse) when the server sets State = "Leaving". Durations come from the folder's attributes.
-- The owner sends its display acknowledgment (onShown) as its appear animation starts.
--
-- Facing: every frame each target (starter or active scoring target) turns about the vertical axis only (yaw; never
-- tilts) to face the closest player with a living character. Done locally,
-- like the rest of presentation: the server never rotates targets and decides hits from position alone. Every
-- client picks the same player, so spectators see the same facing. The model's front is its pivot's LookVector.

local TargetVisuals = {}
TargetVisuals.__index = TargetVisuals

TargetVisuals.Mode = {
	Hidden = "Hidden",
	Normal = "Normal",
	Faded = "Faded",
	Gray = "Gray",
	Owner = "Owner",
}

local Mode = TargetVisuals.Mode

local VISIBILITY = { Hidden = 0, Normal = 1, Faded = 0.35, Gray = 1, Owner = 1 }
local APPEAR_SCALE = 0.5 -- model scale at the start of appearing / end of leaving
local GRAY_COLOR = Color3.fromRGB(140, 140, 140)
local TOGGLED_CLASSES = { "LayerCollector", "ParticleEmitter", "Beam", "Trail", "Light", "Fire", "Smoke", "Sparkles" }
local HUD_HEIGHT = 1.5 -- temporary owner HUD, studs above the model's top
local MIN_FACE_DISTANCE = 0.05 -- horizontal studs; closer than this the direction is undefined, so keep the facing
local FACE_EPSILON = 1e-4 -- skip PivotTo when the facing barely changed (1 - dot of the look vectors)

-- attributes: { Kind, OwnerUserId, Revealed }; viewer: { UserId, InRun, CooldownEndsAt, Now }
function TargetVisuals.GetMode(attributes, viewer)
	if attributes.Kind == "Starter" then
		if viewer.InRun then
			return Mode.Faded
		end
		if viewer.CooldownEndsAt > viewer.Now then
			return Mode.Gray
		end
		return Mode.Normal
	end
	if attributes.OwnerUserId == viewer.UserId then
		return Mode.Owner
	end
	return if attributes.Revealed then Mode.Faded else Mode.Hidden
end

function TargetVisuals.IsClickable(mode)
	return mode == Mode.Normal or mode == Mode.Owner
end

-- Where a target should look: the closest living player's root, or nil. roots: { [UserId] = Vector3 }
function TargetVisuals.GetFacePosition(position, roots)
	local closest, closestDistance = nil, math.huge
	for _, root in roots do
		local distance = (root - position).Magnitude
		if distance < closestDistance then
			closest, closestDistance = root, distance
		end
	end
	return closest
end

-- The pivot at `pivot`'s position turned (yaw only) toward `facePosition`, or nil when it's directly above/below
function TargetVisuals.FacingCFrame(pivot, facePosition)
	local position = pivot.Position
	local flat = Vector3.new(facePosition.X - position.X, 0, facePosition.Z - position.Z)
	if flat.Magnitude < MIN_FACE_DISTANCE then
		return nil
	end
	-- Built from axes (right = look x up) rather than CFrame.lookAt, so tests under Lune (whose lookAt ignores
	-- the target) check the same rotation Roblox produces. LookVector = -(right x up) = look
	local look = flat.Unit
	return CFrame.fromMatrix(position, look:Cross(Vector3.yAxis), Vector3.yAxis)
end

-- Roblox default: every player's living HumanoidRootPart position, by UserId
local function robloxGetPlayerRoots()
	local Players = game:GetService("Players")
	local roots = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			roots[player.UserId] = root.Position
		end
	end
	return roots
end

-- deps:
--   localUserId     number
--   getServerTime   () -> number   workspace:GetServerTimeNow (the server's target clock)
--   onShown         (targetId) -> ()   the owner's display acknowledgment
--   showOwnerHud    boolean?   temporary time/health readout over the owner's target
--   getPlayerRoots  (() -> { [UserId]: Vector3 })?   defaults to every living character's HumanoidRootPart
function TargetVisuals.new(deps)
	return setmetatable({
		_userId = deps.localUserId,
		_getServerTime = deps.getServerTime,
		_getPlayerRoots = deps.getPlayerRoots or robloxGetPlayerRoots,
		_onShown = deps.onShown,
		_showOwnerHud = deps.showOwnerHud == true,
		_status = { InRun = false, CooldownEndsAt = 0 },
		_folder = nil,
		_entries = {}, -- [Model] = entry
		_connections = {},
	}, TargetVisuals)
end

function TargetVisuals:SetStatus(status)
	self._status = { InRun = status.InRun, CooldownEndsAt = status.CooldownEndsAt }
end

-- Starts presenting `folder` (Workspace.Targets). Call once
function TargetVisuals:Attach(folder)
	local RunService = game:GetService("RunService")
	self._folder = folder
	table.insert(self._connections, folder.ChildAdded:Connect(function(model)
		self:_add(model)
	end))
	table.insert(self._connections, folder.ChildRemoved:Connect(function(model)
		self:_remove(model)
	end))
	for _, model in folder:GetChildren() do
		self:_add(model)
	end
	table.insert(self._connections, RunService.RenderStepped:Connect(function()
		self:_update()
	end))
end

function TargetVisuals:_duration(name)
	return self._folder:GetAttribute(name) or 0.1
end

function TargetVisuals:_collect(entry, instance)
	if instance:IsA("BasePart") then
		table.insert(entry.Parts, instance)
	elseif instance:IsA("Decal") then -- Textures are Decals
		table.insert(entry.Decals, instance)
	else
		for _, className in TOGGLED_CLASSES do
			if instance:IsA(className) then
				entry.Toggles[instance] = instance.Enabled
				break
			end
		end
	end
end

function TargetVisuals:_add(model)
	if not model:IsA("Model") or self._entries[model] then
		return
	end
	local entry = {
		Model = model,
		TargetId = model:GetAttribute("TargetId"),
		Parts = {},
		Decals = {},
		Toggles = {},
		Saved = nil, -- gray restore: { [instance] = { Color, Material? } }
		Mode = Mode.Hidden,
		Anim = nil, -- { Kind = "Appear" | "Leave", Start, Duration, From }
		Alpha = 0, -- animation visibility 0..1
		Scale = 1,
		Acked = false,
		Hud = nil,
		Connections = {},
	}
	for _, descendant in model:GetDescendants() do
		self:_collect(entry, descendant)
	end
	-- Models stream atomically; this only catches parts added later
	table.insert(entry.Connections, model.DescendantAdded:Connect(function(descendant)
		self:_collect(entry, descendant)
		self:_apply(entry)
	end))
	self._entries[model] = entry
	self:_apply(entry) -- hidden before the first frame renders
	self:_step(entry, os.clock(), self._getPlayerRoots())
end

function TargetVisuals:_remove(model)
	local entry = self._entries[model]
	if not entry then
		return
	end
	self._entries[model] = nil
	for _, connection in entry.Connections do
		connection:Disconnect()
	end
	if entry.Hud then
		entry.Hud:Destroy()
	end
end

function TargetVisuals:_viewer()
	return {
		UserId = self._userId,
		InRun = self._status.InRun,
		CooldownEndsAt = self._status.CooldownEndsAt,
		Now = self._getServerTime(),
	}
end

function TargetVisuals:_setGray(entry, gray)
	if gray and not entry.Saved then
		entry.Saved = {}
		for _, part in entry.Parts do
			entry.Saved[part] = { Color = part.Color, Material = part.Material }
			part.Color = GRAY_COLOR
			part.Material = Enum.Material.SmoothPlastic
		end
		for _, decal in entry.Decals do
			entry.Saved[decal] = { Color = decal.Color3 }
			decal.Color3 = GRAY_COLOR
		end
	elseif not gray and entry.Saved then
		for instance, look in entry.Saved do
			if instance:IsA("BasePart") then
				instance.Color = look.Color
				instance.Material = look.Material
			else
				instance.Color3 = look.Color
			end
		end
		entry.Saved = nil
	end
end

-- Pushes the entry's current mode and animation onto the model
function TargetVisuals:_apply(entry)
	local visible = entry.Alpha * VISIBILITY[entry.Mode]
	local modifier = 1 - visible
	for _, part in entry.Parts do
		part.LocalTransparencyModifier = modifier
	end
	for _, decal in entry.Decals do
		decal.LocalTransparencyModifier = modifier
	end
	for instance, authored in entry.Toggles do
		instance.Enabled = authored and visible > 0
	end
end

function TargetVisuals:_startAnim(entry, kind, now)
	entry.Anim = {
		Kind = kind,
		Start = now,
		Duration = self:_duration(if kind == "Appear" then "AppearDuration" else "DisappearDuration"),
		FromAlpha = entry.Alpha,
	}
end

-- Turns the model (yaw only) toward its player, if it has one this frame
function TargetVisuals:_face(entry, roots)
	local model = entry.Model
	local pivot = model:GetPivot()
	local facePosition = TargetVisuals.GetFacePosition(pivot.Position, roots)
	local facing = facePosition and TargetVisuals.FacingCFrame(pivot, facePosition)
	if facing and 1 - facing.LookVector:Dot(pivot.LookVector) > FACE_EPSILON then
		model:PivotTo(facing)
	end
end

-- One frame for one entry: mode changes, animation, facing, acknowledgment, HUD
function TargetVisuals:_step(entry, now, roots)
	local model = entry.Model
	local mode = TargetVisuals.GetMode({
		Kind = model:GetAttribute("Kind"),
		OwnerUserId = model:GetAttribute("OwnerUserId"),
		Revealed = model:GetAttribute("Revealed"),
	}, self:_viewer())
	local leaving = model:GetAttribute("State") == "Leaving"

	if leaving and not (entry.Anim and entry.Anim.Kind == "Leave") then
		self:_startAnim(entry, "Leave", now)
	elseif not leaving and mode ~= Mode.Hidden and entry.Alpha == 0 and not entry.Anim then
		-- Becoming visible to this viewer: on arrival, or a spectator seeing the owner's acknowledgment
		self:_startAnim(entry, "Appear", now)
		if mode == Mode.Owner and model:GetAttribute("Kind") == "Scoring" and not entry.Acked then
			entry.Acked = true
			self._onShown(entry.TargetId)
		end
	end
	if mode ~= entry.Mode then
		self:_setGray(entry, mode == Mode.Gray)
		entry.Mode = mode
	end

	local anim = entry.Anim
	if anim then
		local progress = if anim.Duration > 0 then math.clamp((now - anim.Start) / anim.Duration, 0, 1) else 1
		local target = if anim.Kind == "Appear" then 1 else 0
		entry.Alpha = anim.FromAlpha + (target - anim.FromAlpha) * progress
		local scale = APPEAR_SCALE + (1 - APPEAR_SCALE) * entry.Alpha
		if math.abs(scale - entry.Scale) > 1e-3 then
			entry.Scale = scale
			model:ScaleTo(scale)
		end
		if progress >= 1 and anim.Kind == "Appear" then
			entry.Anim = nil
			if entry.Scale ~= 1 then
				entry.Scale = 1
				model:ScaleTo(1)
			end
		end
	end
	self:_apply(entry)
	if not leaving then
		self:_face(entry, roots)
	end

	if self._showOwnerHud and mode == Mode.Owner and not leaving then
		self:_updateHud(entry)
	elseif entry.Hud then
		entry.Hud:Destroy()
		entry.Hud = nil
		entry.HudLabel = nil
	end
end

function TargetVisuals:_update()
	local now = os.clock()
	local roots = self._getPlayerRoots() -- once per frame, shared by every target
	for _, entry in self._entries do
		self:_step(entry, now, roots)
	end
end

-- Temporary readout (no authored target UI yet): seconds left and health over the owner's target
function TargetVisuals:_updateHud(entry)
	local model = entry.Model
	if not entry.Hud then
		local adornee = model.PrimaryPart or entry.Parts[1]
		if not adornee then
			return
		end
		local center, size = model:GetBoundingBox()
		local gui = Instance.new("BillboardGui")
		gui.Name = "TargetHud"
		gui.Adornee = adornee
		gui.AlwaysOnTop = true
		gui.Size = UDim2.fromOffset(180, 36)
		gui.StudsOffsetWorldSpace = Vector3.new(0, center.Position.Y + size.Y / 2 - adornee.Position.Y + HUD_HEIGHT, 0)
		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0.4
		label.Parent = gui
		gui.Parent = model -- local child: never replicates, destroyed with the model
		entry.Hud = gui
		entry.HudLabel = label
	end
	local targetTime = self._folder:GetAttribute("TargetTime") or 0
	local deadline = model:GetAttribute("Deadline") or 0
	local remaining = if deadline > 0
		then math.clamp(deadline - self._getServerTime(), 0, targetTime)
		else targetTime
	entry.HudLabel.Text = string.format(
		"%.2fs   %.0f / %.0f",
		remaining,
		model:GetAttribute("Health") or 0,
		model:GetAttribute("MaxHealth") or 0
	)
end

-- The TargetId behind a clicked part when this viewer may hit it, else nil
function TargetVisuals:ResolveTargetId(instance)
	local folder = self._folder
	local current = instance
	while current and current.Parent ~= folder do
		current = current.Parent
	end
	local entry = current and self._entries[current]
	if not entry or entry.Model:GetAttribute("State") == "Leaving" or not TargetVisuals.IsClickable(entry.Mode) then
		return nil
	end
	return entry.TargetId
end

function TargetVisuals:GetFolder()
	return self._folder
end

function TargetVisuals:Destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	for model in table.clone(self._entries) do
		self:_remove(model)
	end
end

return TargetVisuals
