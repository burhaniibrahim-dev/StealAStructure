-- Responsibility: Egg stack HUD in the rubber-hose simulator style.
-- One chunky card per egg type with a big icon, outlined count, and fill bar. Cards pop when the count
-- rises and turn red with a wobbling FULL! sticker at max stack. A bouncy banner says "Inventory full".
-- Display only: values come from InventoryState, which the server keeps authoritative.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Packages.React)
local UiAssets = require(ReplicatedStorage.Shared.Configs.UI.UiAssets)
local EggIcon = require(script.Parent.EggIcon)
local Theme = require(script.Parent.Theme)

local e = React.createElement

local TOAST_SECONDS = 2.2
local CARD_WIDTH = 230
local CARD_HEIGHT = 64
local SHADOW_OFFSET = 5

local function sortedItems(itemDefinitions)
	local list = {}
	for itemTypeId, definition in itemDefinitions do
		table.insert(list, { Id = itemTypeId, Definition = definition })
	end
	table.sort(list, function(a, b)
		return a.Definition.Order < b.Definition.Order
	end)
	return list
end

-- Squash-and-stretch pop on a UIScale whenever `trigger` changes after the first render
local function usePop(trigger, peak)
	local scaleRef = React.useRef(nil)
	local first = React.useRef(true)
	React.useEffect(function()
		if first.current then
			first.current = false
			return
		end
		local scale = scaleRef.current
		if not scale then
			return
		end
		scale.Scale = peak
		local tween = TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		tween:Play()
		return function()
			tween:Cancel()
		end
	end, { trigger })
	return scaleRef
end

-- Rocks back and forth while mounted
local function useWobble(degrees)
	local ref = React.useRef(nil)
	React.useEffect(function()
		local instance = ref.current
		if not instance then
			return
		end
		instance.Rotation = -degrees
		local tween = TweenService:Create(
			instance,
			TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Rotation = degrees }
		)
		tween:Play()
		return function()
			tween:Cancel()
		end
	end, {})
	return ref
end

local function FullSticker()
	local wobbleRef = useWobble(8)
	return e("Frame", {
		ref = wobbleRef,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -10, 0, 4),
		Size = UDim2.fromOffset(62, 28),
		BackgroundColor3 = Theme.Gold,
		ZIndex = 6,
	}, {
		Corner = Theme.corner(10),
		Stroke = Theme.stroke(3),
		Label = Theme.label({ Text = "FULL!", TextSize = 18, TextColor3 = Theme.Danger, ZIndex = 7 }),
	})
end

local function StackCard(props)
	local definition = props.Definition
	local isFull = props.Count >= props.MaxStack
	local fill = math.clamp(props.Count / props.MaxStack, 0, 1)
	local base = if isFull then Theme.Danger else definition.Color
	local scaleRef = usePop(props.Count, 1.12)

	return e("Frame", {
		LayoutOrder = definition.Order,
		Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT + SHADOW_OFFSET),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { ref = scaleRef }),

		-- Solid offset shadow gives the "sticker on paper" depth
		Shadow = e("Frame", {
			Position = UDim2.fromOffset(0, SHADOW_OFFSET),
			Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT),
			BackgroundColor3 = Theme.Ink,
			ZIndex = 1,
		}, { Corner = Theme.corner(18) }),

		Card = e("Frame", {
			Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT),
			BackgroundColor3 = Theme.Paper,
			ZIndex = 2,
		}, {
			Corner = Theme.corner(18),
			Stroke = Theme.stroke(3),
			Fill = if isFull
				then Theme.gradient(Theme.lighten(Theme.Danger, 0.25), Theme.DangerDeep)
				else Theme.gradient(Theme.lighten(base, 0.55), Theme.lighten(base, 0.15)),

			-- Icon bursts out of the left edge
			IconBubble = e("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0, 22, 0.5, -2),
				Size = UDim2.fromOffset(70, 70),
				BackgroundColor3 = Theme.Cream,
				ZIndex = 3,
			}, {
				Corner = Theme.corner(UDim.new(0.5, 0)),
				Stroke = Theme.stroke(3),
				Icon = e(EggIcon, {
					Definition = definition,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(0.92, 0.92),
					Rotation = -8,
					ZIndex = 4,
				}),
			}),

			Title = Theme.label({
				Text = definition.DisplayName,
				TextSize = 15,
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.fromOffset(64, 5),
				Size = UDim2.new(1, -72, 0, 18),
				ZIndex = 4,
			}),
			Count = Theme.label({
				Text = `{props.Count}<font size="16" color="#FFF8E1">/{props.MaxStack}</font>`,
				RichText = true,
				TextSize = 28,
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.fromOffset(64, 20),
				Size = UDim2.new(1, -72, 0, 26),
				ZIndex = 4,
			}),

			Bar = e("Frame", {
				Position = UDim2.new(0, 64, 1, -14),
				Size = UDim2.new(1, -76, 0, 9),
				BackgroundColor3 = Theme.darken(base, 0.45),
				ZIndex = 4,
			}, {
				Corner = Theme.corner(UDim.new(0.5, 0)),
				Stroke = Theme.stroke(2),
				Fill = e("Frame", {
					Size = UDim2.fromScale(fill, 1),
					BackgroundColor3 = if isFull then Theme.Gold else Theme.Paper,
					ZIndex = 5,
				}, { Corner = Theme.corner(UDim.new(0.5, 0)) }),
			}),

			Sticker = if isFull then e(FullSticker) else nil,
		}),
	})
end

local function Header()
	return e("Frame", {
		LayoutOrder = 0,
		Size = UDim2.fromOffset(CARD_WIDTH, 46),
		BackgroundTransparency = 1,
	}, {
		Pill = e("Frame", {
			Position = UDim2.fromOffset(38, 8),
			Size = UDim2.fromOffset(120, 34),
			Rotation = -3,
			BackgroundColor3 = Theme.Sky,
		}, {
			Corner = Theme.corner(UDim.new(0.5, 0)),
			Stroke = Theme.stroke(3),
			Fill = Theme.gradient(Theme.lighten(Theme.Sky, 0.3), Theme.SkyDeep),
			Label = Theme.label({ Text = "EGGS", TextSize = 24, Position = UDim2.fromOffset(14, 0) }),
		}),
		Basket = if UiAssets.EggBasket ~= ""
			then e("ImageLabel", {
				Image = UiAssets.EggBasket,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(56, 56),
				Position = UDim2.fromOffset(-4, -6),
				Rotation = -10,
				ZIndex = 3,
			})
			else nil,
	})
end

local function Toast(props)
	local scaleRef = React.useRef(nil)
	React.useEffect(function()
		local scale = scaleRef.current
		if not scale then
			return
		end
		scale.Scale = 0.4
		local tween = TweenService:Create(scale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		tween:Play()
		return function()
			tween:Cancel()
		end
	end, { props.Serial })

	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 70),
		Size = UDim2.fromOffset(360, 74),
		Rotation = -2,
		BackgroundColor3 = Theme.Danger,
	}, {
		Scale = e("UIScale", { ref = scaleRef }),
		Corner = Theme.corner(22),
		Stroke = Theme.stroke(4),
		Fill = Theme.gradient(Theme.lighten(Theme.Danger, 0.2), Theme.DangerDeep),
		Icon = e(EggIcon, {
			Definition = props.Definition,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, 14, 0.5, 0),
			Size = UDim2.fromOffset(78, 78),
			Rotation = 12,
			ZIndex = 3,
		}),
		Title = Theme.label({
			Text = "INVENTORY FULL!",
			TextSize = 30,
			Position = UDim2.fromOffset(52, 6),
			Size = UDim2.new(1, -62, 0, 36),
			ZIndex = 2,
		}),
		Subtitle = Theme.label({
			Text = `Your {props.Definition.DisplayName} stack is maxed`,
			TextSize = 16,
			TextColor3 = Theme.Cream,
			Position = UDim2.fromOffset(52, 40),
			Size = UDim2.new(1, -62, 0, 22),
			ZIndex = 2,
		}),
	})
end

-- props: inventoryState (InventoryState), itemDefinitions, subscribeFull: (callback(itemTypeId)) -> () -> ()
local function InventoryHud(props)
	local inventory, setInventory = React.useState(props.inventoryState:Get())
	local toast, setToast = React.useState(nil)

	React.useEffect(function()
		local unsubscribe = props.inventoryState:Subscribe(function()
			setInventory(props.inventoryState:Get())
		end)
		local serial = 0
		local unsubscribeFull = props.subscribeFull(function(itemTypeId)
			serial += 1
			local mine = serial
			setToast({ ItemTypeId = itemTypeId, Serial = mine })
			task.delay(TOAST_SECONDS, function()
				setToast(function(current)
					return if current and current.Serial == mine then nil else current
				end)
			end)
		end)
		return function()
			unsubscribe()
			unsubscribeFull()
		end
	end, {})

	local stack = {
		Layout = e("UIListLayout", {
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
		}),
		Header = e(Header),
	}
	for _, item in sortedItems(props.itemDefinitions) do
		stack[item.Id] = e(StackCard, {
			Definition = item.Definition,
			Count = inventory.Counts[item.Id] or 0,
			MaxStack = inventory.MaxStack,
		})
	end

	local toastDefinition = toast and props.itemDefinitions[toast.ItemTypeId]

	return e("ScreenGui", { Name = "InventoryHud", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, {
		Stacks = e("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 34, 1, -16),
			Size = UDim2.fromOffset(CARD_WIDTH, 400),
			BackgroundTransparency = 1,
		}, stack),
		Toast = if toastDefinition then e(Toast, { Definition = toastDefinition, Serial = toast.Serial }) else nil,
	})
end

return InventoryHud
