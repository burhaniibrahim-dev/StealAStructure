-- Responsibility: An egg icon. Uses the uploaded image when ItemDefinitions has an Icon id,
-- otherwise draws an outlined, glossy cartoon egg in the item's colour.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Theme = require(script.Parent.Theme)

local e = React.createElement

-- props: Definition, Size (UDim2), Position, AnchorPoint, Rotation, ZIndex
local function EggIcon(props)
	local definition = props.Definition
	if definition.Icon ~= "" then
		return e("ImageLabel", {
			Image = definition.Icon,
			BackgroundTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
			Size = props.Size,
			Position = props.Position,
			AnchorPoint = props.AnchorPoint,
			Rotation = props.Rotation,
			ZIndex = props.ZIndex,
		})
	end

	local zIndex = props.ZIndex or 1
	return e("Frame", {
		BackgroundTransparency = 1,
		Size = props.Size,
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Rotation = props.Rotation,
		ZIndex = zIndex,
	}, {
		Aspect = e("UIAspectRatioConstraint", { AspectRatio = 1 }),
		Shell = e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.54),
			Size = UDim2.fromScale(0.72, 0.88),
			BackgroundColor3 = Theme.Paper,
			ZIndex = zIndex,
		}, {
			Corner = Theme.corner(UDim.new(0.5, 0)),
			Stroke = Theme.stroke(3),
			Shade = e("UIGradient", {
				Rotation = 35,
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Theme.lighten(definition.Color, 0.35)),
					ColorSequenceKeypoint.new(0.6, definition.Color),
					ColorSequenceKeypoint.new(1, Theme.darken(definition.Color, 0.3)),
				}),
			}),
			Shine = e("Frame", {
				Position = UDim2.fromScale(0.2, 0.14),
				Size = UDim2.fromScale(0.22, 0.3),
				Rotation = -20,
				BackgroundColor3 = Theme.Paper,
				BackgroundTransparency = 0.1,
				ZIndex = zIndex + 1,
			}, { Corner = Theme.corner(UDim.new(0.5, 0)) }),
			Sparkle = e("Frame", {
				Position = UDim2.fromScale(0.5, 0.12),
				Size = UDim2.fromScale(0.1, 0.1),
				Rotation = 45,
				BackgroundColor3 = Theme.Paper,
				ZIndex = zIndex + 1,
			}),
		}),
	})
end

return EggIcon
