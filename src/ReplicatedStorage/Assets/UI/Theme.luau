-- Responsibility: Shared look for the HUD. Rubber-hose simulator style: thick navy outlines, bright
-- gradients, chunky rounded type, and small helpers that build those pieces as React elements.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local e = React.createElement

local Theme = {}

Theme.Font = Enum.Font.FredokaOne
Theme.Ink = Color3.fromRGB(27, 31, 59) -- every outline
Theme.Paper = Color3.fromRGB(255, 255, 255)
Theme.Cream = Color3.fromRGB(255, 248, 225)
Theme.Sky = Color3.fromRGB(110, 200, 255)
Theme.SkyDeep = Color3.fromRGB(45, 130, 235)
Theme.Danger = Color3.fromRGB(255, 70, 85)
Theme.DangerDeep = Color3.fromRGB(190, 20, 50)
Theme.Gold = Color3.fromRGB(255, 214, 60)
Theme.StrokeThickness = 3

function Theme.darken(color, amount)
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

function Theme.lighten(color, amount)
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

function Theme.corner(radius)
	return e("UICorner", { CornerRadius = if typeof(radius) == "UDim" then radius else UDim.new(0, radius or 14) })
end

function Theme.stroke(thickness, color)
	return e("UIStroke", {
		Thickness = thickness or Theme.StrokeThickness,
		Color = color or Theme.Ink,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

-- Vertical gradient, light on top
function Theme.gradient(top, bottom)
	return e("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(top, bottom),
	})
end

-- Chunky outlined label
function Theme.label(props)
	return e("TextLabel", {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = props.Text,
		RichText = props.RichText == true,
		TextSize = props.TextSize or 22,
		TextColor3 = props.TextColor3 or Theme.Paper,
		TextStrokeColor3 = Theme.Ink,
		TextStrokeTransparency = if props.NoStroke then 1 else 0,
		TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Center,
		TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center,
		AnchorPoint = props.AnchorPoint,
		Position = props.Position,
		Size = props.Size or UDim2.fromScale(1, 1),
		Rotation = props.Rotation,
		ZIndex = props.ZIndex,
		LayoutOrder = props.LayoutOrder,
	}, props.children)
end

return Theme
