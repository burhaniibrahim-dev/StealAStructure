--Responsibility: Detect player clicks and raycast from the click's X/Y screen position into the world
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Networker = require(game:GetService("ReplicatedStorage").Shared.Networker.Client)

local ACTION_NAME = "ClickServiceClick"
local RAY_DISTANCE = 1000

local ClickService = {}

local initialized = false
local clickedCallbacks: { (result: RaycastResult?, position: Vector2) -> () } = {}

--Casts a ray through the given screen X/Y (as given by InputObject.Position, GUI inset excluded)
function Raycast(x: number, y: number): RaycastResult?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local ray = camera:ScreenPointToRay(x, y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = Players.LocalPlayer.Character
	params.FilterDescendantsInstances = if character then { character } else {}

	return workspace:Raycast(ray.Origin, ray.Direction * RAY_DISTANCE, params)
end

--Register a function that runs on every click with (RaycastResult?, Vector2 click position)
function ClickService.OnClick(callback: (result: RaycastResult?, position: Vector2) -> ())
	table.insert(clickedCallbacks, callback)
end

local function handleClick(_actionName: string, state: Enum.UserInputState, input: InputObject)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	local position = Vector2.new(input.Position.X, input.Position.Y)
	local result = Raycast(position.X, position.Y)

    for _, callback in clickedCallbacks do
		task.spawn(callback, result, position)
	end


    if result then
        if CollectionService:HasTag(result.Instance, "HITBOX") then
			print("Click")
			Networker.ClickEvent.Fire({
                Position = result.Position, 
                Tag = result.Instance.Name
            })
        end
    end

	return Enum.ContextActionResult.Pass
end

function ClickService.Init()
	if initialized then
		return
	end
	initialized = true

	ContextActionService:BindAction(ACTION_NAME, handleClick, false, Enum.UserInputType.MouseButton1, Enum.UserInputType.Touch)
end

return ClickService
