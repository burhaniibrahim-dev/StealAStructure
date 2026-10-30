-- Responsibility: Roblox side of targets. Looks up authored models in ReplicatedStorage.Assets.Targetables.Targets,
-- checks their pivots, and owns the server models in Workspace.Targets that every client sees.
-- Pure modules (TargetService, TargetPlacement) only see the small interface built here.
--
-- Model attributes (server-written, read-only for clients; TargetVisuals decides presentation from them):
--   TargetId, Kind ("Starter" | "Scoring"), TargetTypeId, OwnerUserId (0 for starters),
--   State ("Live" | "Leaving"), Revealed (starters true; scoring targets after the owner's acknowledgment),
--   MaxHealth, Health, Deadline (server time; 0 until acknowledged)
-- Folder attributes: AppearDuration, DisappearDuration, TargetTime (so clients animate and count down in step)

local RobloxTargetWorld = {}

local PIVOT_TOLERANCE = 0.05 -- studs between the pivot and the model's lowest point before we warn

local function folderOf(replicatedStorage)
	local assets = replicatedStorage:FindFirstChild("Assets")
	local targetables = assets and assets:FindFirstChild("Targetables")
	return targetables and targetables:FindFirstChild("Targets")
end

-- options: { replicatedStorage, workspace, config (TargetConfig) }
-- Returns the adapter and the Workspace.Targets folder (placement rays ignore it)
function RobloxTargetWorld.new(options)
	local folder = Instance.new("Folder")
	folder.Name = "Targets"
	folder:SetAttribute("AppearDuration", options.config.AppearDuration)
	folder:SetAttribute("DisappearDuration", options.config.DisappearDuration)
	folder:SetAttribute("TargetTime", options.config.TargetTime)
	folder.Parent = options.workspace

	local function getTemplate(modelName)
		local templates = folderOf(options.replicatedStorage)
		local template = templates and templates:FindFirstChild(modelName)
		return if template and template:IsA("Model") then template else nil
	end

	local adapter = {}

	-- Looked up live, so a model removed at runtime is noticed on the next spawn
	function adapter:HasModel(modelName)
		return getTemplate(modelName) ~= nil
	end

	-- Distance from the template's pivot to the bottom of its bounding box (0 = pivot at the base), or nil
	function adapter:PivotOffset(modelName)
		local template = getTemplate(modelName)
		if not template then
			return nil
		end
		local center, size = template:GetBoundingBox()
		return template:GetPivot().Position.Y - (center.Position.Y - size.Y / 2)
	end

	function adapter:Create(record, modelName)
		local template = getTemplate(modelName)
		if not template then
			return nil
		end
		local model = template:Clone()
		model.Name = `{record.Kind}_{record.TargetId}`
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic -- arrives whole, so clients style it in one go
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
			end
		end
		-- Upright at the ground point, keeping the authored rotation of the pivot
		model:PivotTo(CFrame.new(record.Position) * template:GetPivot().Rotation)
		model:SetAttribute("TargetId", record.TargetId)
		model:SetAttribute("Kind", record.Kind)
		model:SetAttribute("TargetTypeId", record.TargetTypeId)
		model:SetAttribute("OwnerUserId", record.OwnerUserId or 0)
		model:SetAttribute("State", "Live")
		model:SetAttribute("Revealed", record.Kind == "Starter")
		model:SetAttribute("MaxHealth", record.MaxHealth or 0)
		model:SetAttribute("Health", record.Health or 0)
		model:SetAttribute("Deadline", 0)
		model.Parent = folder
		return model
	end

	function adapter:SetAttributes(model, attributes)
		if not model then
			return
		end
		for name, value in attributes do
			model:SetAttribute(name, value)
		end
	end

	function adapter:Destroy(model)
		if model then
			model:Destroy()
		end
	end

	function adapter:DestroyAll()
		folder:Destroy()
	end

	return adapter, folder
end

-- Startup report: warns (never errors) for every type whose model is missing or not pivoted at its base
function RobloxTargetWorld.checkTypes(adapter, types, warnFn)
	for targetTypeId, definition in types do
		local offset = adapter:PivotOffset(definition.ModelName)
		if offset == nil then
			warnFn(`MODEL OF {definition.ModelName} doesnt exist; target type {targetTypeId} is disabled until it does`)
		elseif math.abs(offset) > PIVOT_TOLERANCE then
			warnFn(
				`[Targets] {definition.ModelName}'s pivot is {string.format("%.2f", offset)} studs from its base; `
					.. "targets won't sit flush. Move the pivot to the bottom of the model in Studio"
			)
		end
	end
end

return RobloxTargetWorld
