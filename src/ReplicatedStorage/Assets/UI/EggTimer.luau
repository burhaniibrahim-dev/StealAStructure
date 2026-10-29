-- POST-LAUNCH POLISH / NOT WIRED FOR LAUNCH: used only by EggBillboard, which nothing requires yet.
--
-- Responsibility: An egg's lifetime countdown, "<seconds>s", where each digit rolls independently.
-- When a digit changes, the old one slides down out of its slot and the new one slides down in from above.
-- Digits that didn't change stay still (29 -> 28 only moves the last digit). When the number gets shorter
-- (10 -> 9), the leftover digit slides out while its slot shrinks away, so the number re-centres. The "s" never moves.
-- Counts on the client's own clock from `endsAt` (os.clock() based) and stops at 0; the egg itself is only removed
-- when the server says so.
--
-- props:
--   endsAt   number                os.clock() time the countdown reaches 0
--   style    { Props, Children }   snapshot of the authored Timer TextLabel (EggBillboard). Its layout props place the
--                                  timer; its text props and children (UIStroke etc.) dress every digit

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Packages.React)

local e = React.createElement

local SLIDE_TIME = 0.15 -- seconds for a digit to slide out / in
local SLIDE_STYLE = Enum.EasingStyle.Quad
local DIGIT_ASPECT = 0.6 -- slot width as a fraction of the timer's height (every digit gets the same width)
local SUFFIX_ASPECT = 0.5 -- width of the "s" slot, same units
local COLLAPSED_ASPECT = 0.001 -- an exiting slot shrinks to this before it's removed (an aspect ratio can't be 0)
local SUFFIX = "s"

local ABOVE = UDim2.fromScale(0, -1)
local CENTER = UDim2.fromScale(0, 0)
local BELOW = UDim2.fromScale(0, 1)

-- Timer props that place the whole timer; everything else styles the text
local LAYOUT_PROPS = {
	AnchorPoint = true,
	LayoutOrder = true,
	Position = true,
	Rotation = true,
	Size = true,
	SizeConstraint = true,
	Visible = true,
	ZIndex = true,
	AutomaticSize = true,
	BackgroundColor3 = true,
	BackgroundTransparency = true,
	BorderColor3 = true,
	BorderMode = true,
	BorderSizePixel = true,
	ClipsDescendants = true,
}

local function tween(instance, goal, time)
	local info = TweenInfo.new(time or SLIDE_TIME, SLIDE_STYLE, Enum.EasingDirection.Out)
	TweenService:Create(instance, info, goal):Play()
end

-- Authored children of the Timer label (UIStroke, UIGradient, UITextSizeConstraint...) copied onto each digit
local function renderChildren(nodes)
	local children = {}
	for _, node in nodes do
		children[node.Name] = e(node.ClassName, node.Props, renderChildren(node.Children))
	end
	return children
end

local function textProps(style, overrides)
	local props = {}
	for key, value in style.Props do
		if not LAYOUT_PROPS[key] then
			props[key] = value
		end
	end
	props.BackgroundTransparency = 1
	props.Size = UDim2.fromScale(1, 1)
	for key, value in overrides do
		props[key] = value
	end
	return props
end

-- One rolling glyph. Its starting Position is fixed at mount; tweens own Position after that
local function Glyph(props)
	local ref = React.useRef(nil)
	local start = React.useState(if props.phase == "enter" then ABOVE else CENTER)

	React.useLayoutEffect(function()
		local label = ref.current
		if not label then
			return
		end
		if props.phase == "enter" then
			tween(label, { Position = CENTER })
		elseif props.phase == "leave" then
			tween(label, { Position = BELOW })
		end
	end, { props.phase })

	return e(
		"TextLabel",
		textProps(props.style, { ref = ref, Text = props.digit, Position = start }),
		renderChildren(props.style.Children)
	)
end

-- One digit place. Keeps the leaving glyph until its slide finishes, then drops it.
-- props: digit, style, layoutOrder, entering (slot appears: grows in), exiting (slot goes: slides out and shrinks)
local function DigitSlot(props)
	local nextKey = React.useRef(1)
	local glyphs, setGlyphs = React.useState(function()
		return { { Key = 1, Digit = props.digit, Phase = if props.entering then "enter" else "idle" } }
	end)
	local aspectRef = React.useRef(nil)

	-- A changed digit: the current glyph leaves, a new one enters
	React.useEffect(function()
		local current = glyphs[#glyphs]
		if props.exiting or current.Digit == props.digit then
			return
		end
		nextKey.current += 1
		local key = nextKey.current
		setGlyphs(function(previous)
			local updated = {}
			for _, glyph in previous do
				table.insert(updated, { Key = glyph.Key, Digit = glyph.Digit, Phase = "leave" })
			end
			table.insert(updated, { Key = key, Digit = props.digit, Phase = "enter" })
			return updated
		end)
		local timer = task.delay(SLIDE_TIME, function()
			setGlyphs(function(previous)
				local kept = {}
				for _, glyph in previous do
					if glyph.Phase ~= "leave" then
						table.insert(kept, glyph)
					end
				end
				return kept
			end)
		end)
		return function()
			task.cancel(timer)
		end
	end, { props.digit, props.exiting == true } :: { any }) -- a nil in a deps list would change its length

	-- The slot itself: grows in when it appears, slides its digit out and shrinks when it goes
	React.useLayoutEffect(function()
		local aspect = aspectRef.current
		if not aspect then
			return
		end
		if props.exiting then
			setGlyphs(function(previous)
				local updated = {}
				for _, glyph in previous do
					table.insert(updated, { Key = glyph.Key, Digit = glyph.Digit, Phase = "leave" })
				end
				return updated
			end)
			tween(aspect, { AspectRatio = COLLAPSED_ASPECT })
		elseif props.entering then
			tween(aspect, { AspectRatio = DIGIT_ASPECT })
		end
	end, { props.exiting == true })

	local children = {
		Aspect = e("UIAspectRatioConstraint", {
			ref = aspectRef,
			AspectRatio = if props.entering then COLLAPSED_ASPECT else DIGIT_ASPECT,
			AspectType = Enum.AspectType.ScaleWithParentSize,
			DominantAxis = Enum.DominantAxis.Height,
		}),
	}
	for _, glyph in glyphs do
		children[`Glyph{glyph.Key}`] = e(Glyph, { digit = glyph.Digit, phase = glyph.Phase, style = props.style })
	end

	return e("Frame", {
		BackgroundTransparency = 1,
		ClipsDescendants = true, -- hides digits above and below the slot
		LayoutOrder = props.layoutOrder,
		Size = UDim2.fromScale(1, 1),
	}, children)
end

-- Whole seconds left, rounded up, never below 0
local function secondsLeft(endsAt)
	return math.max(0, math.ceil(endsAt - os.clock()))
end

-- Digits keyed by place from the right (units = 0), so a place keeps its slot as the number changes
local function placesOf(seconds)
	local text = tostring(seconds)
	local places = {}
	for place = 0, #text - 1 do
		places[place] = string.sub(text, #text - place, #text - place)
	end
	return places, #text
end

local function EggTimer(props)
	local seconds, setSeconds = React.useState(function()
		return secondsLeft(props.endsAt)
	end)
	local mounted = React.useRef(false)
	local alive = React.useRef(true)
	local lastPlaces = React.useRef(nil)
	local exiting, setExiting = React.useState({}) -- [place] = digit, sliding out after the number got shorter

	React.useEffect(function()
		local connection = RunService.Heartbeat:Connect(function()
			local now = secondsLeft(props.endsAt)
			setSeconds(function(previous)
				return if previous == now then previous else now
			end)
		end)
		return function()
			connection:Disconnect()
		end
	end, { props.endsAt })

	local places, count = placesOf(seconds)

	-- Places the number just stopped needing. Worked out during render (from the previous render's places) so the
	-- slot never unmounts for a frame before it starts sliding out
	local leaving = {}
	local previous = lastPlaces.current
	if previous and previous.Count > count then
		for place = count, previous.Count - 1 do
			leaving[place] = previous.Places[place]
		end
	end

	-- Keep them as exiting until their slide finishes, then drop them
	React.useEffect(function()
		if next(leaving) == nil then
			return
		end
		setExiting(function(current)
			local updated = table.clone(current)
			for place, digit in leaving do
				updated[place] = digit
			end
			return updated
		end)
		task.delay(SLIDE_TIME, function()
			if not alive.current then
				return
			end
			setExiting(function(current)
				local updated = table.clone(current)
				for place in leaving do
					updated[place] = nil
				end
				return updated
			end)
		end)
	end, { count })

	-- What this render showed, for the next render's leaving check
	React.useEffect(function()
		lastPlaces.current = { Places = places, Count = count }
	end)

	React.useEffect(function()
		mounted.current = true
		return function()
			alive.current = false
		end
	end, {})

	local style = props.style
	local children = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Suffix = e("Frame", {
			BackgroundTransparency = 1,
			LayoutOrder = 1, -- after every digit (digits use negative orders)
			Size = UDim2.fromScale(1, 1),
		}, {
			Aspect = e("UIAspectRatioConstraint", {
				AspectRatio = SUFFIX_ASPECT,
				AspectType = Enum.AspectType.ScaleWithParentSize,
				DominantAxis = Enum.DominantAxis.Height,
			}),
			Label = e("TextLabel", textProps(style, { Text = SUFFIX }), renderChildren(style.Children)),
		}),
	}
	for _, source in { exiting, leaving } do
		for place, digit in source do
			if place >= count then
				children[`Place{place}`] = e(DigitSlot, { digit = digit, style = style, layoutOrder = -place, exiting = true })
			end
		end
	end
	for place, digit in places do
		children[`Place{place}`] = e(DigitSlot, {
			digit = digit,
			style = style,
			layoutOrder = -place,
			entering = mounted.current, -- a place added after the first render grows in
		})
	end

	-- The container takes the authored Timer's placement and background
	local frameProps = {}
	for key, value in style.Props do
		if LAYOUT_PROPS[key] then
			frameProps[key] = value
		end
	end
	frameProps.ClipsDescendants = false
	return e("Frame", frameProps, children)
end

return EggTimer
