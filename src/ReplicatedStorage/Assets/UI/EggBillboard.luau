-- POST-LAUNCH POLISH / NOT WIRED FOR LAUNCH: nothing requires this module. Eggs keep their authored Studio UI.
-- To enable, require it in Client.client.luau and pass the commented `decorate` hook to SpawningVisuals.new.
--
-- Responsibility: The UI above each local egg. Reads the UI authored inside the egg's TextAttachment (Billboard,
-- Progress, Timer...), removes those instances, and renders the same tree with React so it looks the same, except
-- the Timer label, which becomes the rolling EggTimer countdown. The authored UI is the style source for now.
--
-- Copying: each authored instance becomes a React host element of the same class and name, carrying the
-- properties in COPIED_PROPS that its class actually has. A property missing from that list falls back to its default.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local EggTimer = require(script.Parent.EggTimer)

local e = React.createElement

local ATTACHMENT_NAME = "TextAttachment" -- the egg attachment whose UI is replaced
local TIMER_NAME = "Timer" -- the TextLabel that becomes the countdown

-- Writable properties worth carrying over. Each instance keeps only the ones its class has
local COPIED_PROPS = {
	-- LayerCollector / BillboardGui
	"Active", "AlwaysOnTop", "Brightness", "DistanceLowerLimit", "DistanceStep", "DistanceUpperLimit", "Enabled",
	"ExtentsOffset", "ExtentsOffsetWorldSpace", "LightInfluence", "MaxDistance", "SizeOffset", "StudsOffset",
	"StudsOffsetWorldSpace", "ZIndexBehavior",
	-- GuiObject
	"AnchorPoint", "AutomaticSize", "BackgroundColor3", "BackgroundTransparency", "BorderColor3", "BorderMode",
	"BorderSizePixel", "ClipsDescendants", "LayoutOrder", "Position", "Rotation", "Size", "SizeConstraint", "Visible",
	"ZIndex",
	-- Text
	"FontFace", "LineHeight", "RichText", "Text", "TextColor3", "TextScaled", "TextSize", "TextStrokeColor3",
	"TextStrokeTransparency", "TextTransparency", "TextTruncate", "TextWrapped", "TextXAlignment", "TextYAlignment",
	-- Image
	"Image", "ImageColor3", "ImageRectOffset", "ImageRectSize", "ImageTransparency", "ResampleMode", "ScaleType",
	"SliceCenter", "SliceScale", "TileSize",
	-- UI modifiers
	"ApplyStrokeMode", "Color", "LineJoinMode", "Thickness", "Transparency", "CornerRadius", "Offset",
	"PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight", "FillDirection", "HorizontalAlignment",
	"VerticalAlignment", "Padding", "SortOrder", "Scale", "AspectRatio", "AspectType", "DominantAxis", "MaxTextSize",
	"MinTextSize", "MaxSize", "MinSize",
}

local function readProps(instance)
	local props = {}
	for _, name in COPIED_PROPS do
		local ok, value = pcall(function()
			return (instance :: any)[name]
		end)
		if ok and value ~= nil then
			props[name] = value
		end
	end
	return props
end

-- { ClassName, Name, Props, Children } for an instance and everything under it
local function snapshot(instance)
	local node = { ClassName = instance.ClassName, Name = instance.Name, Props = readProps(instance), Children = {} }
	for _, child in instance:GetChildren() do
		table.insert(node.Children, snapshot(child))
	end
	return node
end

local function render(node, endsAt)
	if node.Name == TIMER_NAME and node.ClassName == "TextLabel" then
		return e(EggTimer, { style = node, endsAt = endsAt })
	end
	local children = {}
	for _, child in node.Children do
		children[child.Name] = render(child, endsAt)
	end
	return e(node.ClassName, node.Props, children)
end

local EggBillboard = {}

-- Replaces the UI in `egg`'s TextAttachment with the React version, counting down to `endsAt` (os.clock() time).
-- Returns a cleanup that unmounts it, or nil when the egg has no TextAttachment
function EggBillboard.mount(egg, endsAt)
	local attachment = egg:FindFirstChild(ATTACHMENT_NAME, true)
	if not attachment then
		return nil
	end

	local nodes = {}
	for _, child in attachment:GetChildren() do
		table.insert(nodes, snapshot(child))
		child:Destroy()
	end

	local tree = {}
	for _, node in nodes do
		tree[node.Name] = render(node, endsAt)
	end

	local root = ReactRoblox.createRoot(attachment)
	root:render(e(React.Fragment, nil, tree))
	return function()
		root:unmount()
	end
end

return EggBillboard
