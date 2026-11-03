local Library = {
	Flags = {},
	Options = {},
	Themes = {},
	ThemeOrder = {},
	IconsUrl = "https://raw.githubusercontent.com/egor5050/Zenin-Library/refs/heads/main/Icons/Icons",
	IconsCache = "zenin_lucide_icons.lua",
	ConfigFolder = nil,
	GuiName = "ZeninUI",
	ActiveWindow = nil,
}

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")

local LocalPlayer = Players.LocalPlayer

local function Method(obj, name, fn)
	obj[name] = function(first, ...)
		if first == obj then
			return fn(...)
		end
		return fn(first, ...)
	end
end

local function SafeCall(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, res = pcall(fn, ...)
	if not ok then
		warn("[Zenin] callback error: " .. tostring(res))
		return nil
	end
	return res
end

-- Maid: owns cleanup tasks and releases them all at once, newest first.
-- Accepted tasks: RBXScriptConnection, Instance, thread, Tween, function, a Maid, or any table
-- with Destroy/Disconnect/Cancel. Named slots (maid.Name = task) replace and clean the old task.
local Maid = {}
Maid.__index = function(self, k)
	local m = Maid[k]
	if m ~= nil then return m end
	local named = rawget(self, "_named")
	return named and named[k]
end
Maid.__newindex = function(self, k, job)
	if Maid[k] ~= nil then error("[Zenin] Maid: '" .. tostring(k) .. "' is reserved", 2) end
	local named = rawget(self, "_named")
	local old = named[k]
	if old == job then return end
	named[k] = job
	if job ~= nil and rawget(self, "_dead") then
		named[k] = nil
		Maid.CleanTask(job)
		return
	end
	if old ~= nil then Maid.CleanTask(old) end
end

function Maid.new()
	return setmetatable({_tasks = {}, _named = {}, _dead = false, _cleaning = false}, Maid)
end

function Maid.Is(v)
	return type(v) == "table" and getmetatable(v) == Maid
end

function Maid.CleanTask(job)
	local kind = typeof(job)
	local ok, err = pcall(function()
		if kind == "RBXScriptConnection" then
			job:Disconnect()
		elseif kind == "Instance" then
			if job:IsA("Tween") then job:Cancel() end
			job:Destroy()
		elseif kind == "thread" then
			-- A thread can't cancel itself; one that is running ends through its own guards.
			if coroutine.status(job) == "suspended" then task.cancel(job) end
		elseif kind == "function" then
			job()
		elseif kind == "table" then
			if Maid.Is(job) then
				job:Destroy()
			elseif type(job.Destroy) == "function" then
				job:Destroy()
			elseif type(job.Disconnect) == "function" then
				job:Disconnect()
			elseif type(job.Cancel) == "function" then
				job:Cancel()
			end
		end
	end)
	if not ok then warn("[Zenin] cleanup error: " .. tostring(err)) end
end

-- Returns the task so it can be written inline: local c = maid:Give(sig:Connect(fn)).
function Maid:Give(job)
	if job == nil then return nil end
	if self._dead then
		Maid.CleanTask(job)
		return job
	end
	table.insert(self._tasks, job)
	if Maid.Is(job) then rawset(job, "_parent", self) end
	return job
end
Maid.GiveTask = Maid.Give
Maid.Add = Maid.Give

function Maid:Connect(signal, fn)
	return self:Give(signal:Connect(fn))
end

-- Runs fn on a thread owned by the maid: cancelled if the maid is cleaned first, and dropped
-- from the maid once it finishes, so repeated spawns don't pile up.
local function Owned(self, start, fn, ...)
	if self._dead then return nil end
	local done, thread = false, nil
	thread = start(function(...)
		local ok, err = pcall(fn, ...)
		if not ok then warn("[Zenin] task error: " .. tostring(err)) end
		done = true
		if thread then self:Remove(thread, true) end
	end, ...)
	if not done then self:Give(thread) end
	return thread
end

function Maid:Spawn(fn, ...)
	return Owned(self, task.spawn, fn, ...)
end

-- Runs fn after t seconds unless the maid is cleaned first.
function Maid:Delay(t, fn, ...)
	return Owned(self, function(f, ...) return task.delay(t, f, ...) end, fn, ...)
end

-- A sub-maid that is cleaned with this one, and detaches itself when destroyed on its own.
function Maid:Child()
	return self:Give(Maid.new())
end

-- Stops tracking a task; cleans it too unless keep is true.
function Maid:Remove(job, keep)
	for i = #self._tasks, 1, -1 do
		if self._tasks[i] == job then
			table.remove(self._tasks, i)
			if Maid.Is(job) then rawset(job, "_parent", nil) end
			if not keep then Maid.CleanTask(job) end
			return true
		end
	end
	for k, v in pairs(self._named) do
		if v == job then
			self._named[k] = nil
			if not keep then Maid.CleanTask(job) end
			return true
		end
	end
	return false
end

function Maid:Has(job)
	if table.find(self._tasks, job) then return true end
	for _, v in pairs(self._named) do
		if v == job then return true end
	end
	return false
end

-- Number of tasks; deep also counts tasks inside child maids.
function Maid:Count(deep)
	local n = 0
	for _, t in ipairs(self._tasks) do
		n = n + 1
		if deep and Maid.Is(t) then n = n + t:Count(true) end
	end
	for _, t in pairs(self._named) do
		n = n + 1
		if deep and Maid.Is(t) then n = n + t:Count(true) end
	end
	return n
end

-- Cleans every task, newest first. Tasks given while cleaning are cleaned in the same pass.
-- The maid stays usable afterwards.
function Maid:Clean()
	if self._cleaning then return end
	self._cleaning = true
	local named = self._named
	local k, job = next(named)
	while k ~= nil do
		named[k] = nil
		Maid.CleanTask(job)
		k, job = next(named)
	end
	local tasks = self._tasks
	while #tasks > 0 do
		local t = table.remove(tasks)
		if Maid.Is(t) then rawset(t, "_parent", nil) end
		Maid.CleanTask(t)
	end
	self._cleaning = false
end
Maid.DoCleaning = Maid.Clean

-- Cleans and retires the maid: anything given afterwards is cleaned immediately.
function Maid:Destroy()
	if self._dead then return end
	self._dead = true
	local parent = rawget(self, "_parent")
	if parent then
		rawset(self, "_parent", nil)
		parent:Remove(self, true)
	end
	self:Clean()
end

function Maid:IsAlive()
	return not self._dead
end

Library.Maid = Maid
Library.Windows = {}

-- Shared across executions (getgenv when available) so a re-run can unload the old window.
local SharedEnv = (type(getgenv) == "function" and getgenv()) or shared
SharedEnv.__ZeninLiveWindows = SharedEnv.__ZeninLiveWindows or {}
local LiveWindows = SharedEnv.__ZeninLiveWindows

local function Opts(o)
	if type(o) == "string" then return {Name = o} end
	return o or {}
end

local function CopyList(t)
	local out = {}
	for i, v in ipairs(t or {}) do out[i] = v end
	return out
end

local function IndexOf(t, v)
	for i, x in ipairs(t) do
		if x == v then return i end
	end
	return nil
end

local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end

Library.Themes.Dark = {
	WindowBg = rgb(14, 14, 14), BarBg = rgb(18, 18, 18), BarLine = rgb(22, 22, 22),
	CardBg = rgb(18, 18, 18), BoxBg = rgb(22, 22, 22), BoxBorder = rgb(26, 26, 26),
	TileBg = rgb(22, 22, 22), TileHover = rgb(30, 30, 30),
	DropdownBg = rgb(22, 22, 22), DropdownBorder = rgb(42, 42, 42), DropdownBorderOff = rgb(28, 28, 28),
	PopupBg = rgb(14, 14, 14), PopupHover = rgb(22, 22, 22),
	SliderTrack = rgb(22, 22, 22), KnobFill = rgb(14, 14, 14), KnobStroke = rgb(246, 246, 249), KnobStrokeOff = rgb(150, 150, 156),
	ToggleOffBg = rgb(22, 22, 22), ToggleOffDot = rgb(44, 44, 44),
	ToggleOffBgOff = rgb(19, 19, 19), ToggleOffDotOff = rgb(32, 32, 32), ToggleOnDot = rgb(255, 255, 255),
	Text = rgb(255, 255, 255), TextGray = rgb(160, 160, 168), TextDim = rgb(88, 88, 96),
	ValueOff = rgb(110, 110, 110), NavGray = rgb(180, 180, 188), Divider = rgb(34, 34, 38),
	ScrollTrack = rgb(18, 18, 18), ScrollThumb = rgb(22, 22, 22), ScrollHover = rgb(30, 30, 30), ScrollDrag = rgb(40, 40, 40),
	WmBg = rgb(14, 14, 14), WmStroke = rgb(38, 38, 43), WmDivider = rgb(42, 42, 47), WmText = rgb(255, 255, 255),
	WmDetailIcon = rgb(205, 205, 210), WmSiteIcon = rgb(104, 122, 232),
}
Library.ThemeOrder[1] = "Dark"

local ThemeHooks = {}

local SURFACE_TOKENS = {"WindowBg", "BarBg", "CardBg", "PopupBg", "DropdownBg", "BoxBg", "TileBg", "WmBg"}

-- Partial themes: every missing token is derived from the theme's own background and text
-- colours, so scrollbars, popups, borders, hovers etc. match instead of falling back to Dark's greys.
local function DeriveTheme(given)
	local bg
	for _, k in ipairs(SURFACE_TOKENS) do
		if typeof(given[k]) == "Color3" then bg = given[k] break end
	end
	local light = bg and (0.299 * bg.R + 0.587 * bg.G + 0.114 * bg.B) > 0.5
	local base = (light and Library.Themes.Light) or Library.Themes.Dark
	local t = {}
	for k, v in pairs(given) do t[k] = v end
	if bg then
		local text = given.Text or (light and rgb(20, 20, 24) or rgb(255, 255, 255))
		local function def(k, v) if t[k] == nil then t[k] = v end end
		def("WindowBg", bg)
		bg = t.WindowBg
		def("Text", text)
		def("BarBg", bg:Lerp(text, 0.02))
		def("CardBg", t.BarBg)
		def("BoxBg", t.CardBg:Lerp(text, 0.03))
		def("TileBg", t.BoxBg)
		def("DropdownBg", t.BoxBg)
		def("SliderTrack", t.DropdownBg)
		def("ToggleOffBg", t.DropdownBg)
		def("BarLine", t.BarBg:Lerp(text, 0.04))
		def("BoxBorder", t.BoxBg:Lerp(text, 0.03))
		def("DropdownBorder", t.DropdownBg:Lerp(text, 0.1))
		def("DropdownBorderOff", t.DropdownBg:Lerp(text, 0.03))
		def("TileHover", t.TileBg:Lerp(text, 0.04))
		def("PopupBg", bg)
		def("PopupHover", t.PopupBg:Lerp(text, 0.04))
		def("KnobFill", bg)
		def("KnobStroke", text:Lerp(bg, 0.03))
		def("KnobStrokeOff", text:Lerp(bg, 0.4))
		def("ToggleOffDot", t.ToggleOffBg:Lerp(text, 0.1))
		def("ToggleOffBgOff", t.ToggleOffBg:Lerp(bg, 0.4))
		def("ToggleOffDotOff", t.ToggleOffDot:Lerp(bg, 0.4))
		def("TextGray", text:Lerp(bg, 0.37))
		def("TextDim", text:Lerp(bg, 0.65))
		def("ValueOff", text:Lerp(bg, 0.57))
		def("NavGray", text:Lerp(bg, 0.28))
		def("Divider", t.BarBg:Lerp(text, 0.08))
		def("ScrollTrack", t.BarBg)
		def("ScrollThumb", t.BoxBg)
		def("ScrollHover", t.TileHover)
		def("ScrollDrag", t.ScrollHover:Lerp(text, 0.05))
		def("WmBg", bg)
		def("WmStroke", t.WmBg:Lerp(text, 0.1))
		def("WmDivider", t.WmBg:Lerp(text, 0.12))
		def("WmText", text)
		def("WmDetailIcon", text:Lerp(bg, 0.2))
	end
	for k, v in pairs(base) do
		if t[k] == nil then t[k] = v end
	end
	return t
end

local function AddTheme(name, tokens)
	local t = DeriveTheme(type(tokens) == "table" and tokens or {})
	if not Library.Themes[name] then
		table.insert(Library.ThemeOrder, name)
	end
	Library.Themes[name] = t
	for _, fn in ipairs(ThemeHooks) do SafeCall(fn, name) end
	return t
end
Method(Library, "AddTheme", AddTheme)

AddTheme("Light", {
	WindowBg = rgb(240, 240, 242), BarBg = rgb(255, 255, 255), BarLine = rgb(228, 228, 232),
	CardBg = rgb(231, 231, 233), BoxBg = rgb(224, 224, 226), BoxBorder = rgb(210, 210, 214),
	TileBg = rgb(240, 240, 242), TileHover = rgb(222, 222, 226),
	DropdownBg = rgb(217, 217, 219), DropdownBorder = rgb(191, 191, 193), DropdownBorderOff = rgb(212, 212, 216),
	PopupBg = rgb(240, 240, 242), PopupHover = rgb(226, 226, 230),
	SliderTrack = rgb(217, 217, 219), KnobFill = rgb(255, 255, 255), KnobStroke = rgb(20, 20, 24), KnobStrokeOff = rgb(160, 160, 168),
	ToggleOffBg = rgb(217, 217, 219), ToggleOffDot = rgb(174, 174, 176),
	ToggleOffBgOff = rgb(226, 226, 228), ToggleOffDotOff = rgb(200, 200, 204), ToggleOnDot = rgb(21, 19, 24),
	Text = rgb(20, 20, 24), TextGray = rgb(70, 70, 78), TextDim = rgb(150, 150, 158),
	ValueOff = rgb(150, 150, 158), NavGray = rgb(110, 110, 118), Divider = rgb(221, 220, 225),
	ScrollTrack = rgb(228, 228, 230), ScrollThumb = rgb(214, 214, 216), ScrollHover = rgb(200, 200, 204), ScrollDrag = rgb(186, 186, 190),
	WmBg = rgb(242, 242, 242), WmStroke = rgb(197, 198, 202), WmDivider = rgb(214, 214, 218), WmText = rgb(20, 20, 24),
	WmDetailIcon = rgb(90, 90, 100),
})

local Icons, IconsTried

local function LoadIcons()
	if IconsTried then return Icons end
	IconsTried = true
	local function Parse(src)
		if type(src) ~= "string" or #src < 200 or not loadstring then return nil end
		local fn = loadstring(src)
		if not fn then return nil end
		local ok, res = pcall(fn)
		if ok and type(res) == "table" and type(res["48px"]) == "table" then return res end
		return nil
	end
	local function Download(url)
		local ok, res = pcall(function() return game:HttpGet(url) end)
		if ok and type(res) == "string" and #res > 200 then return res end
		local req = (syn and syn.request) or (http and http.request) or http_request or request
		if req then
			local ok2, r = pcall(req, {Url = url, Method = "GET"})
			if ok2 and type(r) == "table" and type(r.Body) == "string" then return r.Body end
		end
		return nil
	end
	local cached
	if isfile and readfile then
		local ok, data = pcall(function()
			if isfile(Library.IconsCache) then return readfile(Library.IconsCache) end
			return nil
		end)
		if ok then cached = data end
	end
	Icons = Parse(cached)
	if not Icons then
		local src = Download(Library.IconsUrl)
		Icons = Parse(src)
		if Icons and writefile then pcall(writefile, Library.IconsCache, src) end
	end
	return Icons
end

local function IsImage(s)
	if type(s) == "number" then return true end
	if type(s) ~= "string" then return false end
	return s:find("^rbxasset") ~= nil or s:find("^rbxthumb") ~= nil or s:find("^https?://") ~= nil or tonumber(s) ~= nil
end

local function ResolveIcon(name)
	local set = LoadIcons()
	if not set then return nil end
	for _, sheet in ipairs({"48px", "256px"}) do
		local s = set[sheet]
		local e = s and s[name]
		if e then return e end
	end
	return nil
end

local function ApplyIcon(img, spec)
	if spec == nil or spec == false then
		img.Image = ""
		return false
	end
	local list = type(spec) == "table" and spec or {spec}
	for _, s in ipairs(list) do
		if IsImage(s) then
			img.Image = tonumber(s) and ("rbxassetid://" .. tostring(s)) or s
			img.ImageRectSize = Vector2.new(0, 0)
			img.ImageRectOffset = Vector2.new(0, 0)
			return true
		end
		local e = type(s) == "string" and ResolveIcon(s)
		if e then
			img.Image = "rbxassetid://" .. tostring(e[1])
			img.ImageRectSize = Vector2.new(e[2][1], e[2][2])
			img.ImageRectOffset = Vector2.new(e[3][1], e[3][2])
			return true
		end
	end
	img.Image = ""
	return false
end

Method(Library, "GetIcon", function(name)
	local e = ResolveIcon(name)
	if not e then return nil end
	return {
		Image = "rbxassetid://" .. tostring(e[1]),
		ImageRectSize = Vector2.new(e[2][1], e[2][2]),
		ImageRectOffset = Vector2.new(e[3][1], e[3][2]),
	}
end)

local WIN_W, WIN_H = 480, 338
local HEADER_H, BOTTOM_H = 36, 35
local BODY_H = WIN_H - HEADER_H - BOTTOM_H
local TRK_TOP, TRK_BOT = 9, 10
local TRK_LEN = BODY_H - TRK_TOP - TRK_BOT
local BAR_RIGHT = WIN_W - 8
local TEXT = 11
local TI_FAST = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SCALE_OPTIONS = {"1.0x", "1.5x", "2.0x", "2.5x"}
local SCALE_MAP = {["1.0x"] = 0.8, ["1.5x"] = 0.9, ["2.0x"] = 0.95, ["2.5x"] = 1}
local function ScaleLabelFor(scale)
	local best, bestDiff = SCALE_OPTIONS[#SCALE_OPTIONS], math.huge
	for _, name in ipairs(SCALE_OPTIONS) do
		local diff = math.abs(SCALE_MAP[name] - (tonumber(scale) or 1))
		if diff < bestDiff then best, bestDiff = name, diff end
	end
	return best
end
-- Tab-switch presets, picked with Window.SetTransition / the settings dropdown. Two phases: "out"
-- covers the old page with the veil (W.Fader) while it drifts away, "in" lifts the veil while the
-- new page drifts/zooms into place. Drift is in pixels, signed by tab order unless Fixed = true;
-- Zoom is the starting scale. Push slides both pages across without a veil; Cross Dissolve fades the
-- old page out while the new one fades in on top of it (both visible at once); None cuts instantly.
local PAGE_TRANSITIONS = (function()
	local E, D = Enum.EasingStyle, Enum.EasingDirection
	local list = {
		{Name = "Cross Dissolve", Cross = true, In = {0.32, E.Sine, D.InOut}},
		{Name = "Soft Dissolve", Out = {0.14, E.Sine, D.InOut, 6}, In = {0.36, E.Cubic, D.Out, 10}, Reveal = {0.3, E.Sine, D.Out, 0.05}},
		{Name = "Classic Slide", Out = {0.1, E.Quad, D.In, 9}, In = {0.4, E.Quint, D.Out, 18}, Reveal = {0.3, E.Quart, D.Out, 0}},
		{Name = "Fade", Out = {0.16, E.Sine, D.InOut, 0}, In = {0.3, E.Sine, D.Out, 0}, Reveal = {0.26, E.Sine, D.Out, 0}},
		{Name = "Rise", Axis = "Y", Fixed = true, Out = {0.14, E.Quad, D.In, -4}, In = {0.42, E.Quint, D.Out, 16}, Reveal = {0.3, E.Quad, D.Out, 0.03}},
		{Name = "Zoom In", Out = {0.14, E.Quad, D.In, 0, 1.03}, In = {0.4, E.Quint, D.Out, 0, 0.94}, Reveal = {0.28, E.Sine, D.Out, 0.02}},
		{Name = "Zoom Out", Out = {0.14, E.Quad, D.In, 0, 0.97}, In = {0.4, E.Quint, D.Out, 0, 1.06}, Reveal = {0.28, E.Sine, D.Out, 0.02}},
		{Name = "Push", Push = true, In = {0.42, E.Quint, D.Out}},
		{Name = "Spring", Out = {0.12, E.Quad, D.In, 8}, In = {0.55, E.Back, D.Out, 22}, Reveal = {0.22, E.Quad, D.Out, 0}},
		{Name = "Snappy", Out = {0.06, E.Linear, D.In, 4}, In = {0.18, E.Quart, D.Out, 8}, Reveal = {0.16, E.Quad, D.Out, 0}},
		{Name = "Instant", None = true},
	}
	for _, t in ipairs(list) do list[t.Name] = t end
	return list
end)()
local DETAIL_MODES = {"Time", "FPS", "Ping", "Product Type"}
local DETAIL_ICONS = {Time = "clock", FPS = "activity", Ping = "wifi", ["Product Type"] = "monitor"}
local WHITE = Color3.new(1, 1, 1)

local WEIGHTS = {
	Regular = Enum.FontWeight.Regular,
	Medium = Enum.FontWeight.Medium,
	SemiBold = Enum.FontWeight.SemiBold,
	Bold = Enum.FontWeight.Bold,
}
local FontCache = {}
local function ApplyFont(obj, weight)
	local ok = pcall(function()
		local f = FontCache[weight]
		if not f then
			f = Font.new("rbxasset://fonts/families/Roboto.json", WEIGHTS[weight] or Enum.FontWeight.Medium, Enum.FontStyle.Normal)
			FontCache[weight] = f
		end
		obj.FontFace = f
	end)
	if not ok then
		obj.Font = (weight == "Bold" or weight == "SemiBold") and Enum.Font.GothamBold or Enum.Font.GothamMedium
	end
end

local function Create(class, props)
	local obj = Instance.new(class)
	-- Roblox's built-in press tint flashes a grey/white box on transparent buttons.
	if (class == "TextButton" or class == "ImageButton") and props.AutoButtonColor == nil then
		obj.AutoButtonColor = false
	end
	local parent
	for k, v in pairs(props) do
		if k == "Parent" then
			parent = v
		elseif k == "Weight" then
			ApplyFont(obj, v)
		else
			obj[k] = v
		end
	end
	if parent then obj.Parent = parent end
	return obj
end

local function Corner(parent, r)
	return Create("UICorner", {CornerRadius = UDim.new(0, r), Parent = parent})
end

local function Stroke(parent, color, thickness, trans)
	return Create("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = trans or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function Label(parent, text, o)
	o = o or {}
	return Create("TextLabel", {
		BackgroundTransparency = 1,
		Size = o.Size or UDim2.new(1, 0, 1, 0),
		Position = o.Position or UDim2.new(),
		Text = tostring(text),
		TextColor3 = o.Color or Library.Themes.Dark.TextGray,
		TextSize = o.TextSize or TEXT,
		Weight = o.Weight or "Medium",
		TextXAlignment = o.Align or Enum.TextXAlignment.Left,
		TextTruncate = o.Truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
		AutomaticSize = o.AutoX and Enum.AutomaticSize.X or Enum.AutomaticSize.None,
		Parent = parent,
	})
end

local function CreateIcon(parent, spec, size, pos, color)
	local img = Create("ImageLabel", {
		Size = UDim2.fromOffset(size, size),
		Position = pos or UDim2.new(0, 0, 0.5, -size / 2),
		BackgroundTransparency = 1,
		ImageColor3 = color or WHITE,
		ScaleType = Enum.ScaleType.Stretch,
		Parent = parent,
	})
	ApplyIcon(img, spec)
	return img
end

local function IsClickOrTouch(i)
	return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
end

-- Roblox fires MouseEnter on a tap but often never fires MouseLeave afterwards, so hover
-- highlights would stay stuck on phones. Hover is therefore mouse-only.
local function OnMouseEnter(obj, fn)
	return obj.MouseEnter:Connect(function(...)
		if UserInputService:GetLastInputType() == Enum.UserInputType.Touch
			or (UserInputService.TouchEnabled and not UserInputService.MouseEnabled) then return end
		fn(...)
	end)
end

local ActiveTweens = setmetatable({}, {__mode = "k"})
local function Tween(obj, info, props)
	local t = TweenService:Create(obj, info, props)
	local list = ActiveTweens[obj]
	if not list then
		list = {}
		ActiveTweens[obj] = list
	end
	list[t] = props
	t.Completed:Connect(function() list[t] = nil end)
	t:Play()
	return t
end

local HOVER_TI = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MOVE_TI = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local POP_IN = TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local POP_SIZE = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

-- Instant set that cancels only the running tweens touching these properties (their other
-- targets are applied immediately), so theme repaints never get overwritten by stale tweens.
local function SetProps(obj, props)
	local list = ActiveTweens[obj]
	if list then
		for t, tp in pairs(list) do
			if type(tp) == "table" then
				for k in pairs(props) do
					if tp[k] ~= nil then
						list[t] = nil
						pcall(function() t:Cancel() end)
						for k2, v2 in pairs(tp) do
							if props[k2] == nil then obj[k2] = v2 end
						end
						break
					end
				end
			end
		end
	end
	for k, v in pairs(props) do obj[k] = v end
end

local function Anim(obj, props, animate, ti)
	if animate then return Tween(obj, ti or HOVER_TI, props) end
	SetProps(obj, props)
	return nil
end

-- Cancels running tweens so an instant theme/accent repaint isn't overwritten by a stale tween target.
local function StopTweens(...)
	for i = 1, select("#", ...) do
		local obj = select(i, ...)
		local list = obj and ActiveTweens[obj]
		if list then
			ActiveTweens[obj] = nil
			for t in pairs(list) do pcall(function() t:Cancel() end) end
		end
	end
end

-- Fades content in/out by wrapping it in a CanvasGroup only for the duration of the tween,
-- so text stays crisp at rest. done(current) always runs; current is false if superseded.
local FadeTokens = setmetatable({}, {__mode = "k"})
local function FadeContent(content, parent, size, show, ti, z, done)
	FadeTokens[content] = (FadeTokens[content] or 0) + 1
	local tok = FadeTokens[content]
	local cur = content.Parent
	local ok, fx = pcall(Create, "CanvasGroup", {
		Size = size,
		BackgroundTransparency = 1,
		GroupTransparency = show and 1 or 0,
		ZIndex = z or 1,
		Parent = parent,
	})
	if not ok or not fx then
		if done then done(true) end
		return
	end
	if cur and cur ~= parent and cur.ClassName == "CanvasGroup" then
		fx.GroupTransparency = cur.GroupTransparency
	end
	content.Parent = fx
	if cur and cur ~= parent and cur ~= fx and cur.ClassName == "CanvasGroup" then pcall(function() cur:Destroy() end) end
	local t = Tween(fx, ti, {GroupTransparency = show and 0 or 1})
	t.Completed:Connect(function()
		local current = FadeTokens[content] == tok
		if current then
			pcall(function() content.Parent = parent end)
			pcall(function() fx:Destroy() end)
		end
		if done then done(current) end
	end)
end

local function TextWidth(text, size)
	local ok, v = pcall(function()
		return TextService:GetTextSize(tostring(text), size, Enum.Font.GothamMedium, Vector2.new(1000, 100)).X
	end)
	return ok and v or #tostring(text) * size * 0.55
end

local function Decimals(step)
	local s = tostring(step)
	if s:find("e") then
		local mantissa, exp = s:match("^([%d%.]+)e%-(%d+)$")
		if not exp then return 0 end
		local dot = mantissa:find("%.")
		return math.min(tonumber(exp) + (dot and #mantissa - dot or 0), 15)
	end
	local d = s:find("%.")
	return d and (#s - d) or 0
end

local function FormatNumber(v, decimals)
	if decimals > 0 then
		return string.format("%." .. decimals .. "f", v)
	end
	return tostring(math.floor(v + 0.5))
end

local function Byte(x)
	return math.clamp(math.floor((tonumber(x) or 0) * 255 + 0.5), 0, 255)
end

local function ToHex(c)
	if typeof(c) ~= "Color3" then return "FFFFFF" end
	return string.format("%02X%02X%02X", Byte(c.R), Byte(c.G), Byte(c.B))
end

local function FromHex(hex)
	if type(hex) ~= "string" then return nil end
	hex = hex:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^#", "")
	if #hex == 3 then hex = hex:gsub(".", "%0%0") end
	if #hex ~= 6 then return nil end
	local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
	if not (r and g and b) then return nil end
	return Color3.fromRGB(r, g, b)
end

-- Normalizes Color3 / "#hex" input to an in-range Color3, or nil.
local function ToColor(c)
	if typeof(c) == "Color3" then
		return Color3.new(math.clamp(c.R, 0, 1), math.clamp(c.G, 0, 1), math.clamp(c.B, 0, 1))
	end
	if type(c) == "string" then return FromHex(c) end
	return nil
end

local function ToAlpha(a)
	a = tonumber(a)
	if not a or a ~= a then return nil end
	return math.clamp(a, 0, 1)
end

local function Luminance(c)
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
end

-- Text/dot colour that stays readable on top of the accent.
local function OnAccent(W)
	if W.AccentAlpha < 0.5 then return W.Theme.Text end
	return Luminance(W.Accent) > 0.62 and rgb(20, 20, 24) or WHITE
end

-- Picks `preferred` unless it would vanish against the accent (e.g. a white dot on a white accent).
local function OnAccentOr(W, preferred)
	local bg = W.Theme.ToggleOffBg:Lerp(W.Accent, W.AccentAlpha)
	if math.abs(Luminance(preferred) - Luminance(bg)) >= 0.3 then return preferred end
	return Luminance(bg) > 0.5 and rgb(20, 20, 24) or WHITE
end

-- Soft accent wash on the left edge of a header. A UIGradient is baked into a small texture, so a
-- ramp squeezed into the first ~16% of a full-width header renders blocky; giving the ramp its own
-- narrow frame uses the gradient's full range. Returns a repaint function(accent, alpha).
local WASH_FADE = NumberSequence.new(0, 1)
local function AccentWash(header, radius, strength, width)
	-- One layer only, so the tint is uniform top to bottom. The frame is taller than the header by
	-- the corner radius and clipped back: the top-left corner matches the header's rounding, the
	-- bottom corners are cut square where the header continues into the body.
	-- Same ZIndex as its siblings: above the header's corner fill (created before it), below the
	-- brand/title (created after it).
	local clip = Create("Frame", {
		Size = UDim2.new(0, width or 96, 1, 0),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Parent = header,
	})
	local wash = Create("Frame", {Size = UDim2.new(1, 0, 1, radius), BorderSizePixel = 0, Parent = clip})
	Corner(wash, radius)
	Create("UIGradient", {Transparency = WASH_FADE, Parent = wash})
	return function(accent, alpha)
		wash.BackgroundColor3 = accent
		wash.BackgroundTransparency = 1 - strength * (alpha or 1)
	end
end

local function MakeDraggable(W, handle, target, opts)
	opts = opts or {}
	local THRESH = 4

	local function OverButton(pos)
		for _, d in ipairs(handle:GetDescendants()) do
			if d:IsA("GuiButton") and d.Visible then
				local p, sz = d.AbsolutePosition, d.AbsoluteSize
				if pos.X >= p.X and pos.X <= p.X + sz.X and pos.Y >= p.Y and pos.Y <= p.Y + sz.Y then
					return true
				end
			end
		end
		return false
	end

	W.Connect(handle.InputBegan, function(input)
		if not IsClickOrTouch(input) then return end
		local origin = Vector2.new(input.Position.X, input.Position.Y)
		if OverButton(origin) then return end
		local startPos, started = target.Position, false
		W.BeginDrag(input, function(inp)
			local delta = Vector2.new(inp.Position.X, inp.Position.Y) - origin
			if not started then
				if delta.Magnitude < THRESH then return end
				started = true
			end
			target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end, function(_, cancelled)
			if not started and not cancelled and opts.OnClick then opts.OnClick() end
		end)
	end)
end

local CHECK_LIGHT, CHECK_DARK = rgb(206, 206, 206), rgb(132, 132, 132)
local function Checker(parent, x, y, w, h, sq)
	local base = Create("Frame", {
		Size = UDim2.fromOffset(w, h),
		Position = UDim2.fromOffset(x, y),
		BackgroundColor3 = CHECK_LIGHT,
		BorderSizePixel = 0,
		Parent = parent,
	})
	for row = 0, h / sq - 1 do
		for col = 0, w / sq - 1 do
			if (row + col) % 2 == 1 then
				Create("Frame", {
					Size = UDim2.fromOffset(sq, sq),
					Position = UDim2.fromOffset(col * sq, row * sq),
					BackgroundColor3 = CHECK_DARK,
					BorderSizePixel = 0,
					Parent = base,
				})
			end
		end
	end
	return base
end

local function NormalizeLogo(spec, title)
	if spec == nil or spec == false then
		local first = tostring(title or "Z"):match("[%w]") or "Z"
		return {Text = first:upper()}
	end
	if type(spec) == "number" then return {Image = spec} end
	if type(spec) == "string" then
		if IsImage(spec) then return {Image = spec} end
		if #spec <= 2 then return {Text = spec} end
		return {Icon = spec}
	end
	if type(spec) ~= "table" then return NormalizeLogo(nil, title) end
	return spec
end

local function CreateLogo(W, parent, spec, size, textSize)
	local box = Create("Frame", {Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1, Parent = parent})
	local fades = {}
	local target, prop
	if spec.Text then
		box.Size = UDim2.fromOffset(0, size)
		box.AutomaticSize = Enum.AutomaticSize.X
		local lbl = Label(box, spec.Text, {
			Size = UDim2.new(0, 0, 1, 0),
			AutoX = true,
			TextSize = spec.TextSize or textSize,
			Weight = "Bold",
			Align = Enum.TextXAlignment.Center,
		})
		target, prop = lbl, "TextColor3"
		table.insert(fades, {lbl, "TextTransparency", 0})
	else
		local img = Create("ImageLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ImageColor3 = WHITE,
			ScaleType = spec.Image and Enum.ScaleType.Fit or Enum.ScaleType.Stretch,
			Parent = box,
		})
		ApplyIcon(img, spec.Image or spec.Icon)
		if spec.Corner then Corner(img, spec.Corner) end
		if not spec.Image or spec.Tint then
			target, prop = img, "ImageColor3"
		end
		table.insert(fades, {img, "ImageTransparency", 0})
	end
	if spec.Color and target then
		target[prop] = spec.Color
	elseif target then
		W.Bind(function(_, accent) target[prop] = accent end, target)
	end
	return box, fades
end

local function NewElement(W, S, kind, o, height)
	S.Order = S.Order + 1
	local row = Create("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		LayoutOrder = S.Order,
		Parent = S.Content,
	})
	local el = {
		_win = W,
		Type = kind,
		Name = o.Name or o.Title,
		Flag = o.Flag,
		Enabled = o.Enabled ~= false and o.Disabled ~= true,
		Visible = o.Visible ~= false,
		Row = row,
		Maid = W.Maid:Child(),
		_deps = {},
		_depOn = {},
	}
	row.Visible = el.Visible
	local listeners = {}
	el._apply = function(_animate) end

	function el._sync(value)
		if el.Flag then Library.Flags[el.Flag] = value end
		for _, fn in ipairs(el._deps) do SafeCall(fn, value) end
	end
	function el._fire(value, extra)
		el._sync(value)
		SafeCall(o.Callback, value, extra)
		for _, fn in ipairs(listeners) do SafeCall(fn, value, extra) end
	end

	Method(el, "OnChanged", function(fn)
		table.insert(listeners, fn)
		return el
	end)
	Method(el, "SetCallback", function(fn) o.Callback = fn end)
	Method(el, "SetEnabled", function(b)
		el.Enabled = b ~= false
		if not el.Enabled then W.ClosePopupOf(el) end
		el._apply(true)
	end)
	Method(el, "IsEnabled", function() return el.Enabled end)
	Method(el, "SetVisible", function(b)
		el.Visible = b ~= false
		row.Visible = el.Visible
		if not el.Visible then W.ClosePopupOf(el) end
	end)
	Method(el, "IsVisible", function() return el.Visible end)
	Method(el, "DependsOn", function(other, invert)
		if type(other) == "string" then other = Library.Options[other] end
		if type(other) ~= "table" or not other._deps then return el end
		local function Upd(v)
			if type(v) == "table" then
				v = next(v) ~= nil
			else
				v = v and true or false
			end
			if invert then v = not v end
			el.SetEnabled(v)
		end
		table.insert(other._deps, Upd)
		table.insert(el._depOn, {other, Upd})
		Upd(other.Get())
		return el
	end)
	Method(el, "Destroy", function()
		W.ClosePopupOf(el)
		if el.Flag and Library.Options[el.Flag] == el then
			Library.Flags[el.Flag] = nil
			Library.Options[el.Flag] = nil
		end
		local i = IndexOf(W.Elements, el)
		if i then table.remove(W.Elements, i) end
		for _, link in ipairs(el._depOn) do
			local j = IndexOf(link[1]._deps, link[2])
			if j then table.remove(link[1]._deps, j) end
		end
		table.clear(el._depOn)
		table.clear(el._deps)
		el.Maid:Destroy()
		row:Destroy()
		W.Prune()
	end)

	Method(el, "GiveTask", function(job) return el.Maid:Give(job) end)
	if el.Flag then Library.Options[el.Flag] = el end
	table.insert(W.Elements, el)
	return el, row
end

local function ApplyFlag(el, v)
	if el._deserialize then
		pcall(el._deserialize, v)
	elseif el.Set then
		pcall(el.Set, v)
	end
end

local function SerializeFlag(el)
	if el._serialize then return el._serialize() end
	return el.Get()
end

local function Finish(el, o)
	if el.Flag then Library.Flags[el.Flag] = el.Get() end
	if o.DependsOn then el.DependsOn(o.DependsOn, o.InvertDependency) end
	el._apply(false)
	do
		local ok, d = pcall(SerializeFlag, el)
		if ok then el._default = d end
	end
	if el.Flag then
		local pending = el._win.PendingFlags
		if pending and pending[el.Flag] ~= nil then
			local v = pending[el.Flag]
			pending[el.Flag] = nil
			ApplyFlag(el, v)
		end
	end
	return el
end

local ElementApi
local PANEL_W = 228

local function AttachSettings(W, el, place)
	Method(el, "AddSettings", function(so)
		if el.Settings then return el.Settings end
		so = Opts(so)
		local size, pos = place()
		local gear = Create("TextButton", {
			Size = UDim2.fromOffset(size, size),
			Position = pos,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 2,
			Parent = el.Row,
		})
		Corner(gear, 5)
		local gs = Stroke(gear, WHITE, 1)
		local isz = size >= 20 and 12 or 10
		local gi = CreateIcon(gear, {"settings", "cog"}, isz, UDim2.new(0.5, -isz / 2, 0.5, -isz / 2))
		local open, hover = false, false
		local function PaintGear(animate)
			local T = W.Theme
			Anim(gear, {BackgroundColor3 = (hover and not open) and T.TileHover or T.DropdownBg}, animate)
			Anim(gs, {Color = open and W.Accent or T.DropdownBorder, Transparency = open and (1 - W.AccentAlpha) or 0}, animate)
			Anim(gi, {ImageColor3 = (open or hover) and T.Text or T.NavGray}, animate)
		end
		W.Bind(function() PaintGear(false) end, gear)
		OnMouseEnter(gear, function() hover = true PaintGear(true) end)
		gear.MouseLeave:Connect(function() hover = false PaintGear(true) end)

		local frame = Create("Frame", {
			Size = UDim2.fromOffset(PANEL_W, 26),
			BorderSizePixel = 0,
			Active = true,
			ClipsDescendants = true,
			Visible = false,
			Parent = W.PopupLayer,
		})
		W.Paint(frame, "BackgroundColor3", "WindowBg")
		Corner(frame, 4)
		local fs = Stroke(frame, WHITE, 1)
		W.Paint(fs, "Color", "BoxBorder")

		local header = Create("Frame", {Size = UDim2.new(1, 0, 0, 26), BorderSizePixel = 0, Parent = frame})
		Corner(header, 4)
		W.Paint(header, "BackgroundColor3", "BarBg")
		local hfill = Create("Frame", {Size = UDim2.new(1, 0, 0, 13), Position = UDim2.fromOffset(0, 13), BorderSizePixel = 0, Parent = header})
		W.Paint(hfill, "BackgroundColor3", "BarBg")
		local wash = AccentWash(header, 4, 0.1)
		W.Bind(function(_, accent, alpha) wash(accent, alpha) end, header)
		local line = Create("Frame", {Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BorderSizePixel = 0, Parent = header})
		W.Paint(line, "BackgroundColor3", "BarLine")
		local brand = Create("Frame", {
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			Position = UDim2.fromOffset(9, 0),
			BackgroundTransparency = 1,
			Parent = header,
		})
		Create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 7),
			Parent = brand,
		})
		local logo
		local function BuildLogo()
			if not brand.Parent then return end
			if logo then logo:Destroy() end
			logo = CreateLogo(W, brand, W.LogoSpec, 10, 12)
			logo.LayoutOrder = 1
		end
		BuildLogo()
		table.insert(W.LogoHooks, BuildLogo)
		el.Maid:Give(function()
			local i = IndexOf(W.LogoHooks, BuildLogo)
			if i then table.remove(W.LogoHooks, i) end
		end)
		local title = Label(brand, so.Title or so.Name or ((el.Name or "Element") .. " Settings"), {AutoX = true, Size = UDim2.new(0, 0, 1, 0), Weight = "SemiBold"})
		title.LayoutOrder = 2
		W.Paint(title, "TextColor3", "Text")

		local content = Create("Frame", {Size = UDim2.new(1, -18, 0, 0), Position = UDim2.fromOffset(9, 35), BackgroundTransparency = 1, Parent = frame})
		local layout = Create("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = content})
		local function Height()
			local sc = W.Scale.Scale
			local h = sc > 0 and layout.AbsoluteContentSize.Y / sc or 0
			content.Size = UDim2.new(1, -18, 0, h)
			return 35 + h + 10
		end
		-- Content that settles while the panel is still growing retargets the running tween
		-- instead of snapping, so the open animation stays smooth to the end.
		local sizing
		local function Resize(animate)
			local target = UDim2.fromOffset(PANEL_W, Height())
			if sizing then
				pcall(function() sizing:Cancel() end)
				sizing = nil
			end
			if animate then
				sizing = Tween(frame, POP_SIZE, {Size = target})
			else
				SetProps(frame, {Size = target})
			end
		end
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			if open then Resize(sizing ~= nil and sizing.PlaybackState == Enum.PlaybackState.Playing) end
		end)

		local P = {Order = 0, Content = content, Frame = frame}
		ElementApi(W, P)
		local owner = {el = el}
		Method(P, "Open", function()
			if open or not el.Enabled or not W.PreparePopup(owner, gear) then return end
			local sc = W.Scale.Scale
			local rel = (gear.AbsolutePosition - W.Main.AbsolutePosition) / sc
			frame.Position = UDim2.fromOffset(rel.X, rel.Y + gear.AbsoluteSize.Y / sc + 8)
			frame.Size = UDim2.fromOffset(PANEL_W, 26)
			-- Fade = false: the clip-reveal is the animation; a CanvasGroup re-rasterising a
			-- resizing frame every frame (and the reparent when it ends) is what caused the hitch.
			W.PushPopup(frame, owner, {Keep = true, Fade = false, OnClose = function()
				open = false
				PaintGear(true)
			end})
			open = true
			PaintGear(true)
			Resize(true)
		end)
		Method(P, "Close", function() W.ClosePopupOf(owner) end)
		Method(P, "IsOpen", function() return open end)
		Method(P, "Toggle", function() if open then P.Close() else P.Open() end end)
		Method(P, "SetTitle", function(t) title.Text = tostring(t) end)
		gear.MouseButton1Click:Connect(function()
			if open then P.Close() else P.Open() end
		end)

		local destroy = el.Destroy
		Method(el, "Destroy", function()
			W.ClosePopupOf(owner)
			for i = #W.Elements, 1, -1 do
				local x = W.Elements[i]
				if x and x.Row:IsDescendantOf(frame) then x.Destroy() end
			end
			frame:Destroy()
			destroy()
		end)
		el.Settings = P
		return P
	end)
end

local function OpenList(W, owner, btn, options, isSelected, onPick, multi, onClose)
	if not W.PreparePopup(owner, btn) then return end
	local T = W.Theme
	local sc = W.Scale.Scale
	local rel = (btn.AbsolutePosition - W.Main.AbsolutePosition) / sc
	local w = btn.AbsoluteSize.X / sc
	local itemH = 21
	local maxVisible = owner.MaxVisible or 8
	local count = math.max(#options, 1)
	local listH = math.min(count, maxVisible) * itemH
	local totalH = listH + 8
	local py = math.clamp(rel.Y + 12.5 - totalH / 2, 6, math.max(6, WIN_H - 6 - totalH))

	local popup = Create("Frame", {
		Size = UDim2.fromOffset(w, 0),
		Position = UDim2.fromOffset(rel.X, py),
		BackgroundColor3 = T.PopupBg,
		ClipsDescendants = true,
		Active = true,
	})
	Corner(popup, 5)
	local popupStroke = Stroke(popup, T.DropdownBorder, 1)
	local scrolls = #options > maxVisible
	local list = Create("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, listH),
		Position = UDim2.fromOffset(0, 4),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = scrolls and 2 or 0,
		ScrollBarImageColor3 = T.DropdownBorder,
		ScrollingEnabled = scrolls,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.fromOffset(0, #options * itemH),
		Parent = popup,
	})
	Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = list})

	local items = {}
	local function Paint(it)
		local sel = isSelected(it.opt)
		it.btn.TextColor3 = sel and W.Accent or W.Theme.Text
		ApplyFont(it.btn, sel and "SemiBold" or "Medium")
	end

	local empty
	if #options == 0 then
		empty = Label(list, "No options", {Position = UDim2.fromOffset(7, 0), Size = UDim2.new(1, -7, 0, itemH), Color = T.TextDim})
	end
	for i, opt in ipairs(options) do
		local ob = Create("TextButton", {
			Size = UDim2.new(1, 0, 0, itemH),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Text = tostring(opt),
			TextSize = TEXT,
			Weight = "Medium",
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = list,
		})
		Create("UIPadding", {PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7), Parent = ob})
		local it = {opt = opt, btn = ob}
		table.insert(items, it)
		Paint(it)
		ob.MouseButton1Click:Connect(function()
			onPick(opt)
			if multi then
				for _, x in ipairs(items) do Paint(x) end
			else
				W.ClosePopupOf(owner)
			end
		end)
	end

	W.Bind(function(th)
		popup.BackgroundColor3 = th.PopupBg
		popupStroke.Color = th.DropdownBorder
		list.ScrollBarImageColor3 = th.DropdownBorder
		if empty then empty.TextColor3 = th.TextDim end
		for _, x in ipairs(items) do Paint(x) end
	end, popup)
	W.PushPopup(popup, owner, {OnClose = onClose})
	Tween(popup, POP_SIZE, {Size = UDim2.fromOffset(w, totalH)})
end

local function AddToggle(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Toggle", o, 21)
	local state = o.Default == true or o.Value == true
	el.Value = state

	local lbl = Label(row, o.Name or o.Title or "Toggle", {Size = UDim2.new(1, -34, 1, 0), Truncate = true})
	local click = Create("TextButton", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = row})
	local sw = Create("TextButton", {
		Size = UDim2.fromOffset(26, 14),
		Position = UDim2.new(1, -26, 0.5, -7),
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 2,
		Parent = row,
	})
	Corner(sw, 7)
	local dot = Create("Frame", {Size = UDim2.fromOffset(8, 8), BorderSizePixel = 0, ZIndex = 2, Parent = sw})
	Corner(dot, 4)

	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		local bg, bgT, dotC, dotPos
		if state then
			bg, bgT = W.Accent, 1 - W.AccentAlpha * (enabled and 1 or 0.45)
			dotC, dotPos = OnAccentOr(W, T.ToggleOnDot), UDim2.new(1, -11, 0.5, -4)
		else
			bg = enabled and T.ToggleOffBg or T.ToggleOffBgOff
			bgT = 0
			dotC = enabled and T.ToggleOffDot or T.ToggleOffDotOff
			dotPos = UDim2.new(0, 3, 0.5, -4)
		end
		local lc = (not enabled) and T.TextDim or ((state or el._hover) and T.Text or T.TextGray)
		if animate then
			local ti = TweenInfo.new(0.14, Enum.EasingStyle.Quad)
			Tween(lbl, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {TextColor3 = lc})
			Tween(dot, ti, {Position = dotPos, BackgroundColor3 = dotC})
			Tween(sw, ti, {BackgroundColor3 = bg, BackgroundTransparency = bgT})
		else
			StopTweens(lbl, dot, sw)
			lbl.TextColor3 = lc
			dot.Position, dot.BackgroundColor3 = dotPos, dotC
			sw.BackgroundColor3, sw.BackgroundTransparency = bg, bgT
		end
	end
	W.Bind(function() el._apply(false) end, row)

	Method(el, "Set", function(v, silent)
		v = v and true or false
		local changed = v ~= state
		state = v
		el.Value = v
		el._apply(true)
		if changed and not silent then
			el._fire(v)
		else
			el._sync(v)
		end
	end)
	Method(el, "Get", function() return state end)
	Method(el, "Toggle", function() el.Set(not state) end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)

	local function OnClick()
		if el.Enabled then el.Set(not state) end
	end
	click.MouseButton1Click:Connect(OnClick)
	sw.MouseButton1Click:Connect(OnClick)
	local function Hover(b)
		el._hover = b
		el._apply(true)
	end
	OnMouseEnter(click, function() Hover(true) end)
	click.MouseLeave:Connect(function() Hover(false) end)
	AttachSettings(W, el, function()
		lbl.Size = UDim2.new(1, -34 - 27, 1, 0)
		return 21, UDim2.new(1, -26 - 6 - 21, 0.5, -10.5)
	end)
	return Finish(el, o)
end

local function AddSlider(W, S, o)
	o = Opts(o)
	local EXTRA = 2
	local el, row = NewElement(W, S, "Slider", o, 28 + EXTRA)
	local minV, maxV = o.Min or 0, o.Max or 100
	if maxV <= minV then maxV = minV + 1 end
	local step = o.Step or o.Increment or 1
	local decimals = o.Decimals or Decimals(step)

	local function Fmt(v)
		if type(o.Format) == "function" then return tostring(o.Format(v)) end
		return FormatNumber(v, decimals) .. (o.Suffix or "")
	end
	local function Round(v)
		v = tonumber(v) or minV
		if step > 0 then v = math.floor((v - minV) / step + 0.5) * step + minV end
		v = math.clamp(v, minV, maxV)
		return tonumber(FormatNumber(v, decimals)) or v
	end
	local value = Round(o.Default or o.Value or minV)
	el.Value = value

	local lbl = Label(row, o.Name or o.Title or "Slider", {Position = UDim2.fromOffset(0, EXTRA), Size = UDim2.new(0.65, 0, 0, 15), Truncate = true})
	local valLbl = Label(row, Fmt(value), {
		Position = UDim2.new(0.65, 0, 0, EXTRA),
		Size = UDim2.new(0.35, 0, 0, 15),
		Align = Enum.TextXAlignment.Right,
	})
	local hit = Create("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.fromOffset(0, EXTRA + 12.5),
		BackgroundTransparency = 1,
		Active = true,
		Parent = row,
	})
	local track = Create("Frame", {
		Size = UDim2.new(1, 0, 0, 4),
		Position = UDim2.new(0, 0, 0.5, -2),
		BorderSizePixel = 0,
		Parent = hit,
	})
	Corner(track, 2)
	local R = 5.5
	local fill = Create("Frame", {BorderSizePixel = 0, Parent = track})
	Corner(fill, 2)
	local knob = Create("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(7, 7), BorderSizePixel = 0, ZIndex = 3, Parent = track})
	Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = knob})
	local ks = Stroke(knob, WHITE, 2)

	local SLIDE = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local function Layout(animate)
		local p = (value - minV) / (maxV - minV)
		local fs = UDim2.new(p, R * (1 - 2 * p), 1, 0)
		local kp = UDim2.new(p, R * (1 - 2 * p), 0.5, 0)
		if animate then
			Tween(fill, SLIDE, {Size = fs})
			Tween(knob, SLIDE, {Position = kp})
		else
			fill.Size, knob.Position = fs, kp
		end
		valLbl.Text = Fmt(value)
	end
	Layout(false)

	function el._apply()
		local T, enabled = W.Theme, el.Enabled
		lbl.TextColor3 = enabled and T.TextGray or T.TextDim
		valLbl.TextColor3 = enabled and T.TextGray or T.TextDim
		track.BackgroundColor3 = T.SliderTrack
		fill.BackgroundColor3 = W.Accent
		fill.BackgroundTransparency = 1 - W.AccentAlpha * (enabled and 1 or 0.45)
		knob.BackgroundColor3 = T.KnobFill
		ks.Color = enabled and T.KnobStroke or T.KnobStrokeOff
	end
	W.Bind(function() el._apply() end, row)

	local function SetValue(v, silent)
		v = Round(v)
		local changed = v ~= value
		value = v
		el.Value = v
		Layout(true)
		if changed and not silent then
			el._fire(v)
		else
			el._sync(v)
		end
	end

	Method(el, "Set", SetValue)
	Method(el, "Get", function() return value end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	Method(el, "SetRange", function(mn, mx)
		minV, maxV = tonumber(mn) or minV, tonumber(mx) or maxV
		if maxV <= minV then maxV = minV + 1 end
		SetValue(value)
	end)
	Method(el, "SetMin", function(mn) el.SetRange(mn, maxV) end)
	Method(el, "SetMax", function(mx) el.SetRange(minV, mx) end)
	Method(el, "SetSuffix", function(s) o.Suffix = s Layout() end)
	Method(el, "SetFormat", function(fn) o.Format = fn Layout() end)

	local function Update(input)
		local sc = W.Scale.Scale
		local left = track.AbsolutePosition.X + R * sc
		local width = track.AbsoluteSize.X - 2 * R * sc
		if width <= 0 then return end
		local p = math.clamp((input.Position.X - left) / width, 0, 1)
		SetValue(minV + (maxV - minV) * p)
	end
	hit.InputBegan:Connect(function(input)
		if el.Enabled and IsClickOrTouch(input) and W.BeginDrag(input, Update) then
			Update(input)
		end
	end)
	AttachSettings(W, el, function()
		valLbl.Size = UDim2.new(0.35, -20, 0, 15)
		return 15, UDim2.new(1, -15, 0, EXTRA)
	end)
	return Finish(el, o)
end

local function AddDropdown(W, S, o, multi)
	o = Opts(o)
	local el, row = NewElement(W, S, multi and "MultiDropdown" or "Dropdown", o, 25)
	local options = CopyList(o.Options or o.Values or o.List)
	local value
	local selected = {}
	el.MaxVisible = o.MaxVisible or 8

	-- Accepts {a, b} lists, {a = true} maps, or a single scalar.
	local function ParseSelection(src)
		local out = {}
		if type(src) ~= "table" then src = {src} end
		for k, v in pairs(src) do
			if type(k) == "number" then
				out[v] = true
			elseif v then
				out[k] = true
			end
		end
		return out
	end

	if multi then
		selected = ParseSelection(o.Default or o.Value or {})
	else
		value = o.Default or o.Value
		if value == nil and not o.AllowNone then value = options[1] end
	end

	local leftPad, icon = 0, nil
	if o.Icon then
		icon = CreateIcon(row, o.Icon, 12, UDim2.new(0, -1.5, 0.5, -6))
		leftPad = 14
	end
	local lbl = Label(row, o.Name or o.Title or "Dropdown", {Position = UDim2.fromOffset(leftPad, 0), Size = UDim2.new(0.5, -leftPad - 4, 1, 0), Truncate = true})
	local btn = Create("TextButton", {
		Size = UDim2.new(0.5, 0, 0, 25),
		Position = UDim2.new(0.5, 0, 0, 0),
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = row,
	})
	Corner(btn, 5)
	local bs = Stroke(btn, WHITE, 1)
	local valLbl = Label(btn, "", {Position = UDim2.fromOffset(7, 0), Size = UDim2.new(1, -24, 1, 0), Truncate = true})
	local chev = CreateIcon(btn, {"chevron-down"}, 12, UDim2.new(1, -17, 0.5, -6))

	local function List()
		local out = {}
		for _, opt in ipairs(options) do
			if selected[opt] then table.insert(out, opt) end
		end
		return out
	end
	local function Current()
		if multi then return List() end
		return value
	end
	local function Sync()
		el.Value = Current()
		if multi then
			local names = {}
			for i, v in ipairs(el.Value) do names[i] = tostring(v) end
			valLbl.Text = #names > 0 and table.concat(names, ", ") or (o.Placeholder or "None")
		else
			valLbl.Text = value ~= nil and tostring(value) or (o.Placeholder or "None")
		end
	end
	local function SelectedMap()
		local m = {}
		for _, v in ipairs(List()) do m[v] = true end
		return m
	end
	local function Fire()
		if multi then
			el._fire(el.Value, SelectedMap())
		else
			el._fire(value)
		end
	end
	Sync()

	local isOpen, ddHover = false, false
	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		Anim(lbl, {TextColor3 = enabled and T.TextGray or T.TextDim}, animate)
		Anim(btn, {BackgroundColor3 = (ddHover and enabled and not isOpen) and T.TileHover or T.DropdownBg}, animate)
		Anim(valLbl, {TextColor3 = enabled and T.Text or T.ValueOff}, animate)
		Anim(bs, {
			Color = isOpen and W.Accent or (enabled and T.DropdownBorder or T.DropdownBorderOff),
			Transparency = isOpen and (1 - W.AccentAlpha) or 0,
		}, animate)
		Anim(chev, {ImageColor3 = enabled and (isOpen and T.Text or T.TextGray) or T.TextDim, Rotation = isOpen and 180 or 0}, animate, MOVE_TI)
		if icon then Anim(icon, {ImageColor3 = enabled and T.TextGray or T.TextDim}, animate) end
	end
	W.Bind(function() el._apply() end, row)
	OnMouseEnter(btn, function() ddHover = true el._apply(true) end)
	btn.MouseLeave:Connect(function() ddHover = false el._apply(true) end)

	local function IsSelected(opt)
		if multi then return selected[opt] == true end
		return opt == value
	end

	btn.MouseButton1Click:Connect(function()
		if not el.Enabled then return end
		OpenList(W, el, btn, options, IsSelected, function(opt)
			if multi then
				selected[opt] = (not selected[opt]) or nil
				Sync()
				Fire()
			elseif opt ~= value then
				value = opt
				Sync()
				Fire()
			end
		end, multi, function()
			isOpen = false
			if row.Parent then el._apply(true) end
		end)
		if W.PopupOf(el) then
			isOpen = true
			el._apply(true)
		end
	end)

	local function Key()
		if multi then
			local names = {}
			for i, v in ipairs(List()) do names[i] = tostring(v) end
			return table.concat(names, "\0")
		end
		return value == nil and "\0" or tostring(value)
	end
	-- Closes any open list so it can't show stale selection state, then publishes the change.
	local function Commit(before, silent)
		W.ClosePopupOf(el)
		Sync()
		if Key() ~= before and not silent then
			Fire()
		else
			el._sync(el.Value)
		end
	end

	Method(el, "Set", function(v, silent)
		local before = Key()
		if multi then
			selected = ParseSelection(v)
		else
			if v == nil and not o.AllowNone then return end
			if v ~= nil and not IndexOf(options, v) then return end
			value = v
		end
		Commit(before, silent)
	end)
	Method(el, "Get", function()
		if multi then return List() end
		return value
	end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	Method(el, "GetOptions", function() return CopyList(options) end)
	Method(el, "SetOptions", function(list, silent)
		local before = Key()
		options = CopyList(list)
		if multi then
			for k in pairs(selected) do
				if not IndexOf(options, k) then selected[k] = nil end
			end
		elseif value ~= nil and not IndexOf(options, value) then
			value = (not o.AllowNone) and options[1] or nil
		elseif value == nil and not o.AllowNone then
			value = options[1]
		end
		Commit(before, silent)
	end)
	el.Refresh = el.SetOptions
	Method(el, "AddOption", function(opt, silent)
		if IndexOf(options, opt) then return end
		local list = CopyList(options)
		table.insert(list, opt)
		el.SetOptions(list, silent)
	end)
	Method(el, "RemoveOption", function(opt, silent)
		local i = IndexOf(options, opt)
		if not i then return end
		local list = CopyList(options)
		table.remove(list, i)
		el.SetOptions(list, silent)
	end)
	if multi then
		Method(el, "IsSelected", function(opt) return selected[opt] == true end)
		Method(el, "Select", function(opt, silent)
			if not IndexOf(options, opt) or selected[opt] then return end
			local before = Key()
			selected[opt] = true
			Commit(before, silent)
		end)
		Method(el, "Deselect", function(opt, silent)
			if not selected[opt] then return end
			local before = Key()
			selected[opt] = nil
			Commit(before, silent)
		end)
		Method(el, "ToggleOption", function(opt, silent)
			if selected[opt] then el.Deselect(opt, silent) else el.Select(opt, silent) end
		end)
		Method(el, "Clear", function(silent) el.Set({}, silent) end)
		Method(el, "SelectAll", function(silent) el.Set(CopyList(options), silent) end)
	end
	AttachSettings(W, el, function()
		btn.Size = UDim2.new(0.5, -29, 0, 25)
		btn.Position = UDim2.new(0.5, 29, 0, 0)
		return 25, UDim2.new(0.5, 0, 0, 0)
	end)
	return Finish(el, o)
end

local function AddCardButton(W, S, o)
	o = Opts(o)
	local cb = o.Callback
	local el, row = NewElement(W, S, "Button", {Name = o.Name or o.Title, Enabled = o.Enabled, Disabled = o.Disabled, Visible = o.Visible}, 40)
	local title = o.Name or o.Title or "Button"
	local desc = o.Description or o.Desc
	local buttonText = o.ButtonText or o.Text or "Open"
	local iconSpec = o.Icon

	local box = Create("Frame", {Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = row})
	Corner(box, 3)
	local boxStroke = Stroke(box, WHITE, 1)
	local tile = Create("Frame", {Size = UDim2.fromOffset(25, 25), Position = UDim2.fromOffset(8, 7.5), BorderSizePixel = 0, Parent = box})
	Corner(tile, 2)
	local icon = CreateIcon(tile, iconSpec, 12, UDim2.new(0.5, -6, 0.5, -6))
	local titleLbl = Label(box, title, {Truncate = true})
	local descLbl = Label(box, desc or "", {TextSize = 10, Truncate = true})
	local action = Create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(59, 25),
		BorderSizePixel = 0,
		Text = buttonText,
		TextSize = TEXT,
		Weight = "Medium",
		AutoButtonColor = false,
		Parent = box,
	})
	Corner(action, 3)
	local actionStroke = Stroke(action, WHITE, 1)
	local hovering = false

	local function Layout()
		local hasIcon = iconSpec ~= nil
		local hasDesc = desc ~= nil and desc ~= ""
		tile.Visible = hasIcon
		local bw = math.clamp(math.floor(TextWidth(action.Text, TEXT) + 24), 59, 120)
		action.Size = UDim2.fromOffset(bw, 25)
		local x = hasIcon and 42 or 10
		local w = -(x + bw + 16)
		titleLbl.Position = UDim2.fromOffset(x, hasDesc and 6 or 0)
		titleLbl.Size = UDim2.new(1, w, 0, hasDesc and 15 or 40)
		descLbl.Visible = hasDesc
		descLbl.Position = UDim2.fromOffset(x, 20)
		descLbl.Size = UDim2.new(1, w, 0, 13)
	end
	Layout()

	local cardPressed = false
	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		local a = W.AccentAlpha * (enabled and 1 or 0.45)
		box.BackgroundColor3 = T.DropdownBg
		boxStroke.Color = enabled and T.DropdownBorder or T.DropdownBorderOff
		local ic = ToColor(o.IconColor) or W.Accent
		tile.BackgroundColor3 = T.CardBg:Lerp(ic, 0.22 * a)
		icon.ImageColor3 = ic
		icon.ImageTransparency = 1 - a
		titleLbl.TextColor3 = enabled and T.TextGray or T.TextDim
		descLbl.TextColor3 = T.TextDim
		Anim(action, {
			BackgroundColor3 = (cardPressed and enabled) and T.TileHover:Lerp(T.Text, 0.06) or ((hovering and enabled) and T.TileHover or T.TileBg),
			TextColor3 = not enabled and T.TextDim or (hovering and T.Text or T.TextGray),
		}, animate)
		Anim(actionStroke, {Color = (hovering and enabled) and T.DropdownBorder:Lerp(T.Text, 0.12) or (enabled and T.DropdownBorder or T.DropdownBorderOff)}, animate)
	end
	W.Bind(function() el._apply() end, row)

	OnMouseEnter(action, function() hovering = true el._apply(true) end)
	action.MouseLeave:Connect(function() hovering = false cardPressed = false el._apply(true) end)
	action.InputBegan:Connect(function(i) if IsClickOrTouch(i) then cardPressed = true el._apply(true) end end)
	action.InputEnded:Connect(function(i) if IsClickOrTouch(i) then cardPressed = false el._apply(true) end end)

	local flashToken = 0
	Method(el, "Flash", function(text, duration)
		flashToken = flashToken + 1
		local token = flashToken
		action.Text = tostring(text)
		Layout()
		task.delay(duration or 1.2, function()
			if token == flashToken then
				action.Text = buttonText
				Layout()
			end
		end)
	end)
	Method(el, "Get", function() return nil end)
	Method(el, "SetName", function(t) title = tostring(t) titleLbl.Text = title end)
	el.SetTitle = el.SetName
	Method(el, "SetDescription", function(t) desc = t descLbl.Text = tostring(t or "") Layout() end)
	Method(el, "SetButtonText", function(t)
		buttonText = tostring(t)
		flashToken = flashToken + 1
		action.Text = buttonText
		Layout()
	end)
	Method(el, "SetIcon", function(spec)
		iconSpec = spec
		ApplyIcon(icon, spec)
		Layout()
	end)
	Method(el, "SetIconColor", function(c) o.IconColor = c el._apply() end)

	Method(el, "SetCallback", function(fn) cb = fn end)
	Method(el, "Fire", function()
		if not el.Enabled then return end
		local res = SafeCall(cb)
		el._fire(nil)
		if type(res) == "string" then el.Flash(res) end
	end)

	action.MouseButton1Click:Connect(function()
		el.Fire()
	end)
	if o.DependsOn then el.DependsOn(o.DependsOn, o.InvertDependency) end
	el._apply()
	return el
end

local function OpenColorModal(W, owner, anchor, color, alpha, onChange, state)
	local T = W.Theme
	color = ToColor(color) or WHITE
	local h, s, v = color:ToHSV()
	-- Gray/black colors carry no hue; reuse the last picked hue so it isn't reset to red.
	if state and state.h and (s == 0 or v == 0) then h = state.h end
	if state and state.s and v == 0 then s = state.s end
	h = math.clamp(h, 0, 0.999)
	local a = 1 - (ToAlpha(alpha) or 1)

	local MW, MH = 208, 184
	local SV, BW, BH = 144, 16, 144
	local HX, AX = 160, 184
	local sc = W.Scale.Scale
	local rel = (anchor.AbsolutePosition - W.Main.AbsolutePosition) / sc
	local mx = math.clamp(rel.X + 18 + 13, 6, WIN_W - MW - 6)
	local my = math.clamp(rel.Y + 9 - MH / 2, HEADER_H + 6, WIN_H - BOTTOM_H - 6 - MH)

	local modal = Create("Frame", {
		Size = UDim2.fromOffset(MW, MH),
		Position = UDim2.fromOffset(mx, my),
		BackgroundColor3 = T.PopupBg,
		BorderSizePixel = 0,
		Active = true,
	})
	Corner(modal, 4)
	local modalStroke = Stroke(modal, T.BoxBorder, 1)

	local svBox = Create("Frame", {
		Size = UDim2.fromOffset(SV, SV),
		Position = UDim2.fromOffset(8, 8),
		BackgroundColor3 = Color3.fromHSV(h, 1, 1),
		BorderSizePixel = 0,
		Parent = modal,
	})
	local wL = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2, Parent = svBox})
	Create("UIGradient", {
		Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)}),
		Parent = wL,
	})
	local bL = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 3, Parent = svBox})
	Create("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0)}),
		Parent = bL,
	})
	local cursor = Create("Frame", {Size = UDim2.fromOffset(9, 9), BorderSizePixel = 0, ZIndex = 5, Parent = svBox})
	Corner(cursor, 5)
	Stroke(cursor, rgb(245, 245, 245), 1.5)
	local svHit = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Active = true, ZIndex = 9, Parent = svBox})

	local hueBar = Create("Frame", {
		Size = UDim2.fromOffset(BW, BH),
		Position = UDim2.fromOffset(HX, 8),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Parent = modal,
	})
	Create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, rgb(255, 0, 0)),
			ColorSequenceKeypoint.new(0.17, rgb(255, 255, 0)),
			ColorSequenceKeypoint.new(0.33, rgb(0, 255, 0)),
			ColorSequenceKeypoint.new(0.5, rgb(0, 255, 255)),
			ColorSequenceKeypoint.new(0.67, rgb(0, 0, 255)),
			ColorSequenceKeypoint.new(0.83, rgb(255, 0, 255)),
			ColorSequenceKeypoint.new(1, rgb(255, 0, 0)),
		}),
		Parent = hueBar,
	})
	local hueHit = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Active = true, ZIndex = 9, Parent = hueBar})

	local alphaBar = Checker(modal, AX, 8, BW, BH, 8)
	local alphaTint = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = 5, Parent = alphaBar})
	Create("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)}),
		Parent = alphaTint,
	})
	local alphaHit = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Active = true, ZIndex = 9, Parent = alphaBar})

	local function Marker(x, pointRight)
		local clip = Create("Frame", {
			Size = UDim2.fromOffset(3, 6),
			Position = UDim2.fromOffset(x, 0),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			ZIndex = 10,
			Parent = modal,
		})
		Create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(4.2426, 4.2426),
			Position = pointRight and UDim2.fromOffset(0, 3) or UDim2.fromOffset(3, 3),
			Rotation = 45,
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			ZIndex = 10,
			Parent = clip,
		})
		return clip
	end
	local hueL, hueR = Marker(HX, true), Marker(HX + BW - 3, false)
	local alL, alR = Marker(AX, true), Marker(AX + BW - 3, false)

	local swatchBg = Checker(modal, 8, 162, 24, 12, 6)
	local swatch = Create("Frame", {Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ZIndex = 5, Parent = swatchBg})
	local hexLbl = Label(modal, "", {Position = UDim2.fromOffset(40, 158), Size = UDim2.fromOffset(90, 20), TextSize = 10, Color = T.TextGray})
	local alphaLbl = Label(modal, "", {Position = UDim2.fromOffset(MW - 78, 158), Size = UDim2.fromOffset(70, 20), TextSize = 10, Align = Enum.TextXAlignment.Right, Color = T.TextGray})

	local function Refresh()
		local col = Color3.fromHSV(h, s, v)
		local alpha = 1 - a
		svBox.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		cursor.Position = UDim2.new(s, -4.5, 1 - v, -4.5)
		cursor.BackgroundColor3 = col
		alphaTint.BackgroundColor3 = col
		swatch.BackgroundColor3 = col
		swatch.BackgroundTransparency = 1 - alpha
		local hy = 8 + h * BH - 3
		hueL.Position = UDim2.fromOffset(HX, hy)
		hueR.Position = UDim2.fromOffset(HX + BW - 3, hy)
		local ay = 8 + a * BH - 3
		alL.Position = UDim2.fromOffset(AX, ay)
		alR.Position = UDim2.fromOffset(AX + BW - 3, ay)
		hexLbl.Text = "#" .. ToHex(col)
		alphaLbl.Text = math.floor(alpha * 100 + 0.5) .. "%"
	end
	Refresh()
	W.Bind(function(th)
		modal.BackgroundColor3 = th.PopupBg
		modalStroke.Color = th.BoxBorder
		hexLbl.TextColor3 = th.TextGray
		alphaLbl.TextColor3 = th.TextGray
	end, modal)

	local mode, last = nil, nil
	local function Ratio(pos, frame, axis)
		local size = frame.AbsoluteSize[axis]
		if size <= 0 then return nil end
		return math.clamp((pos[axis] - frame.AbsolutePosition[axis]) / size, 0, 1)
	end
	local function Process(inp)
		if not modal.Parent then return end
		local pos = inp.Position
		if mode == "SV" then
			local x, y = Ratio(pos, svBox, "X"), Ratio(pos, svBox, "Y")
			if not (x and y) then return end
			s, v = x, 1 - y
		elseif mode == "H" then
			local y = Ratio(pos, hueBar, "Y")
			if not y then return end
			h = math.min(y, 0.999)
		elseif mode == "A" then
			local y = Ratio(pos, alphaBar, "Y")
			if not y then return end
			a = y
		else
			return
		end
		if state then state.h, state.s = h, s end
		local key = h .. "," .. s .. "," .. v .. "," .. a
		if key == last then return end
		last = key
		Refresh()
		onChange(Color3.fromHSV(h, s, v), 1 - a)
	end
	local function Begin(m)
		return function(i)
			if IsClickOrTouch(i) and W.BeginDrag(i, Process, function() mode = nil end, "popup") then
				mode = m
				Process(i)
			end
		end
	end
	svHit.InputBegan:Connect(Begin("SV"))
	hueHit.InputBegan:Connect(Begin("H"))
	alphaHit.InputBegan:Connect(Begin("A"))
	W.PushPopup(modal, owner)
end

local function AccentPicker(W, S, labelText)
	local el, row = NewElement(W, S, "AccentPicker", {}, 25)
	local hueState = {}
	local icon = CreateIcon(row, {"palette"}, 12, UDim2.new(0, -1.5, 0.5, -6))
	local lbl = Label(row, labelText, {Position = UDim2.fromOffset(14, 0), Size = UDim2.new(0.7, -14, 1, 0)})
	local circle = Create("TextButton", {
		Size = UDim2.fromOffset(18, 18),
		Position = UDim2.new(1, -18, 0.5, -9),
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = row,
	})
	Corner(circle, 9)
	local circleStroke = Stroke(circle, WHITE, 1)
	local acHover = false
	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		icon.ImageColor3 = enabled and T.TextGray or T.TextDim
		lbl.TextColor3 = enabled and T.TextGray or T.TextDim
		circle.BackgroundColor3 = W.Accent
		circle.BackgroundTransparency = 1 - W.AccentAlpha * (enabled and 1 or 0.45)
		Anim(circleStroke, {Color = (acHover and enabled) and T.TextDim or T.BoxBorder, Thickness = (acHover and enabled) and 1.5 or 1}, animate)
	end
	OnMouseEnter(circle, function() acHover = true el._apply(true) end)
	circle.MouseLeave:Connect(function() acHover = false el._apply(true) end)
	W.Bind(function() el._apply() end, row)
	W.AccentPickerEl = el
	Method(el, "Get", function() return W.Accent, W.AccentAlpha end)
	Method(el, "Set", function(c, a) W.SetAccentExternal(c, a) end)
	circle.MouseButton1Click:Connect(function()
		if not el.Enabled or not W.PreparePopup(el, circle) then return end
		OpenColorModal(W, el, circle, W.Accent, W.AccentAlpha, function(c, a) W.SetAccent(c, a) end, hueState)
	end)
	return el
end

local MAX_COLORS = 4
local function AddColorPicker(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "ColorPicker", o, 21)
	local def = o.Default or o.Value or o.Color or o.Colors or WHITE
	local multi = type(def) == "table"
	local list = multi and def or {def}
	local colors, alphas = {}, {}
	for i = 1, math.min(#list, MAX_COLORS) do
		colors[i] = ToColor(list[i]) or WHITE
		local al = o.Alpha
		if type(al) == "table" then al = al[i] end
		alphas[i] = ToAlpha(al) or 1
	end
	if #colors == 0 then colors[1], alphas[1] = WHITE, 1 end
	local n = #colors
	local CS, GAP = 18, 5
	local cw = n * CS + (n - 1) * GAP

	local lbl = Label(row, o.Name or o.Title or "Color", {Size = UDim2.new(1, -(cw + 8), 1, 0), Truncate = true})
	local circles = {}
	for i = 1, n do
		local c = Create("TextButton", {
			Size = UDim2.fromOffset(CS, CS),
			Position = UDim2.new(1, -cw + (i - 1) * (CS + GAP), 0.5, -CS / 2),
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 2,
			Parent = row,
		})
		Corner(c, CS / 2)
		local ci = {btn = c, el = el, index = i, stroke = Stroke(c, WHITE, 1)}
		circles[i] = ci
		OnMouseEnter(c, function() ci.hover = true el._apply(true) end)
		c.MouseLeave:Connect(function() ci.hover = false el._apply(true) end)
	end

	local function Value()
		if multi then return CopyList(colors) end
		return colors[1]
	end
	local function AlphaValue()
		if multi then return CopyList(alphas) end
		return alphas[1]
	end
	el.Value = Value()

	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		lbl.TextColor3 = enabled and T.TextGray or T.TextDim
		for i, c in ipairs(circles) do
			c.btn.BackgroundColor3 = colors[i]
			c.btn.BackgroundTransparency = 1 - alphas[i] * (enabled and 1 or 0.45)
			Anim(c.stroke, {Color = (c.hover and enabled) and T.TextDim or T.BoxBorder, Thickness = (c.hover and enabled) and 1.5 or 1}, animate)
		end
	end
	W.Bind(function() el._apply() end, row)

	local function Snapshot()
		local parts = {}
		for i = 1, n do parts[i] = ToHex(colors[i]) .. ":" .. alphas[i] end
		return table.concat(parts, "|")
	end
	local function Commit(before, silent)
		el.Value = Value()
		el._apply()
		if before ~= Snapshot() and not silent then
			el._fire(el.Value, AlphaValue())
		else
			el._sync(el.Value)
		end
	end

	for i, c in ipairs(circles) do
		c.btn.MouseButton1Click:Connect(function()
			if not el.Enabled or not W.PreparePopup(c, c.btn) then return end
			OpenColorModal(W, c, c.btn, colors[i], alphas[i], function(col, a)
				if not el.Enabled then return end
				local before = Snapshot()
				colors[i], alphas[i] = col, a
				Commit(before)
			end, c)
		end)
	end

	Method(el, "Set", function(v, a, silent)
		local before = Snapshot()
		if type(v) ~= "table" then v = {v} end
		for i = 1, n do
			local col = ToColor(v[i])
			if col then colors[i] = col end
			local ai
			if type(a) == "table" then ai = a[i] else ai = a end
			if ToAlpha(ai) then alphas[i] = ToAlpha(ai) end
		end
		W.ClosePopupOf(el)
		Commit(before, silent)
	end)
	Method(el, "SetColor", function(i, col, a, silent)
		i = tonumber(i) or 1
		if not colors[i] then return end
		local before = Snapshot()
		col = ToColor(col)
		if col then colors[i] = col end
		if ToAlpha(a) then alphas[i] = ToAlpha(a) end
		W.ClosePopupOf(circles[i])
		Commit(before, silent)
	end)
	Method(el, "Get", Value)
	Method(el, "GetColor", function(i) return colors[i or 1] end)
	Method(el, "GetAlpha", function(i)
		if i then return alphas[i] end
		return AlphaValue()
	end)
	Method(el, "GetCount", function() return n end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	function el._serialize()
		local out = {}
		for i = 1, n do out[i] = {ToHex(colors[i]), alphas[i]} end
		return out
	end
	function el._deserialize(data)
		if type(data) ~= "table" then return end
		local cs, as = {}, {}
		for i = 1, n do
			local d = data[i]
			if type(d) == "table" then
				cs[i] = FromHex(d[1]) or colors[i]
				as[i] = ToAlpha(d[2]) or alphas[i]
			elseif type(d) == "string" then
				cs[i] = FromHex(d) or colors[i]
			end
		end
		el.Set(cs, as)
	end

	AttachSettings(W, el, function()
		lbl.Size = UDim2.new(1, -(cw + 8 + 27), 1, 0)
		return 21, UDim2.new(1, -(cw + 6 + 21), 0.5, -10.5)
	end)
	return Finish(el, o)
end

local function AddPlainButton(W, S, o)
	o = Opts(o)
	local cb = o.Callback
	local el, row = NewElement(W, S, "Button", {Name = o.Name or o.Title or o.Text, Enabled = o.Enabled, Disabled = o.Disabled, Visible = o.Visible}, 27)
	local text = tostring(o.Name or o.Title or o.Text or "Button")
	local b = Create("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = text,
		TextSize = TEXT,
		Weight = "Medium",
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	Corner(b, 3)
	local st = Stroke(b, WHITE, 1)
	local hover, pressed = false, false
	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		local bg = T.DropdownBg
		if enabled and pressed then
			bg = T.TileHover:Lerp(T.Text, 0.06)
		elseif enabled and hover then
			bg = T.TileHover
		end
		Anim(b, {BackgroundColor3 = bg, TextColor3 = not enabled and T.TextDim or (hover and T.Text or T.TextGray)}, animate)
		Anim(st, {Color = (hover and enabled) and T.DropdownBorder:Lerp(T.Text, 0.12) or (enabled and T.DropdownBorder or T.DropdownBorderOff)}, animate)
	end
	W.Bind(function() el._apply() end, row)
	OnMouseEnter(b, function() hover = true el._apply(true) end)
	b.MouseLeave:Connect(function() hover = false pressed = false el._apply(true) end)
	b.InputBegan:Connect(function(i) if IsClickOrTouch(i) then pressed = true el._apply(true) end end)
	b.InputEnded:Connect(function(i) if IsClickOrTouch(i) then pressed = false el._apply(true) end end)

	local flashToken = 0
	Method(el, "Flash", function(t, duration)
		flashToken = flashToken + 1
		local token = flashToken
		b.Text = tostring(t)
		task.delay(duration or 1.2, function()
			if token == flashToken then b.Text = text end
		end)
	end)
	Method(el, "Fire", function()
		if not el.Enabled then return end
		local res = SafeCall(cb)
		el._fire(nil)
		if type(res) == "string" then el.Flash(res) end
	end)
	Method(el, "Get", function() return nil end)
	Method(el, "SetName", function(t)
		text = tostring(t)
		flashToken = flashToken + 1
		b.Text = text
	end)
	el.SetText = el.SetName
	Method(el, "SetCallback", function(fn) cb = fn end)
	b.MouseButton1Click:Connect(function() el.Fire() end)
	if o.DependsOn then el.DependsOn(o.DependsOn, o.InvertDependency) end
	el._apply()
	return el
end

local VKB, TouchDevice, AttachKeyboard
do -- on-screen keyboard
-- On-screen keyboard used instead of the phone's native one. Full-width docked by default (like a
-- normal phone keyboard); the minimise button turns it into a small draggable panel.
-- One shared instance; it follows whichever TextBox was tapped. Everything is driven by the
-- Library.Keyboard config (KB_DEFAULTS); the legacy Library.CustomKeyboard / KeyboardCompact /
-- KeyboardScale fields still work. It stays inactive until a window has fully loaded, so the
-- key-verification prompt always uses the device's own keyboard.
local VKB_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local VKB_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local VKB_HIDDEN = 0.94

local function VKeys(row)
	local out = {}
	for c in row:gmatch(".") do table.insert(out, {c, c:upper(), letter = true}) end
	return out
end
local function VJoin(...)
	local out = {}
	for _, part in ipairs({...}) do
		if type(part[1]) == "table" then
			for _, k in ipairs(part) do table.insert(out, k) end
		else
			table.insert(out, part)
		end
	end
	return out
end

-- Built-in actions. A string in a layout row or the toolbar refers to one of these by name.
local VKB_ACTIONS = {
	back = {icon = {"delete"}, label = "Back"}, wordback = {label = "Del word"}, clear = {label = "Clear"},
	caps = {label = "Caps"}, shift = {label = "Shift"}, enter = {label = "Enter"}, space = {label = "space"},
	left = {icon = {"chevron-left"}, label = "<"}, right = {icon = {"chevron-right"}, label = ">"},
	home = {label = "Home"}, ["end"] = {label = "End"}, select = {label = "Select"}, all = {label = "All"},
	undo = {label = "Undo"}, redo = {label = "Redo"}, cut = {label = "Cut"}, copy = {label = "Copy"}, paste = {label = "Paste"},
	mode = {icon = {"minimize-2"}, label = "-"}, hide = {icon = {"keyboard-off", "chevron-down"}, label = "Hide"},
}
local VKB_REPEAT = {back = true, wordback = true, left = true, right = true, undo = true, redo = true}

-- Layouts: {Rows = {...}, Width = docked width fraction, CompactSize = {w, h}, Tools = toolbar override}.
-- Row items: {"a", "A"} (shifted variant optional, letter = true follows Caps), an action name,
-- {act = ..., w = width units, label/icon}, {text = "...", label = "..."}, {gap = units} (spacer),
-- {act = "layout", to = "Name"}, {act = "custom", id = "name"} or {action = function(keyboard) end}.
local VKB_LAYOUTS = {}
VKB_LAYOUTS.Default = {
	Rows = {
		VJoin({"`", "~"}, {"1", "!"}, {"2", "@"}, {"3", "#"}, {"4", "$"}, {"5", "%"}, {"6", "^"}, {"7", "&"},
			{"8", "*"}, {"9", "("}, {"0", ")"}, {"-", "_"}, {"=", "+"}, {act = "back", w = 2}),
		VJoin({act = "clear", w = 1.5}, VKeys("qwertyuiop"), {"[", "{"}, {"]", "}"}, {"\\", "|", w = 1.5}),
		VJoin({act = "caps", w = 1.75}, VKeys("asdfghjkl"), {";", ":"}, {"'", "\""}, {act = "enter", w = 2.25}),
		VJoin({act = "shift", w = 2.25}, VKeys("zxcvbnm"), {",", "<"}, {".", ">"}, {"/", "?"}, {act = "shift", w = 2.75}),
		VJoin({act = "layout", to = "Numeric", w = 1.5, label = "123"}, {act = "left", w = 1.25}, {act = "right", w = 1.25},
			{act = "space", w = 8.5}, {act = "wordback", w = 2.5}),
	},
}
VKB_LAYOUTS.Simple = {
	Rows = {
		VKeys("qwertyuiop"),
		VJoin({gap = 0.5}, VKeys("asdfghjkl"), {gap = 0.5}),
		VJoin({act = "shift", w = 1.5}, VKeys("zxcvbnm"), {act = "back", w = 1.5}),
		VJoin({act = "layout", to = "Numeric", w = 1.5, label = "123"}, {",", ";"}, {act = "space", w = 5}, {".", ":"}, {act = "enter", w = 1.5}),
	},
}
VKB_LAYOUTS.Numeric = {
	Width = 0.5,
	CompactSize = {240, 250},
	Tools = false,
	Rows = {
		VJoin({"7"}, {"8"}, {"9"}, {act = "back"}),
		VJoin({"4"}, {"5"}, {"6"}, {act = "clear"}),
		VJoin({"1"}, {"2"}, {"3"}, {act = "enter"}),
		VJoin({act = "layout", to = "Default", label = "ABC"}, {"0"}, {"."}, {"-"}),
	},
}

local KB_DEFAULTS = {
	Mode = "Auto",            -- "Auto": touch-only devices. "Always": every device. "Off".
	Compact = false,          -- start as the small draggable panel
	Scale = 1,                -- size multiplier (height when docked, whole panel when compact)
	Dock = "Bottom",          -- "Bottom" | "Top"
	Align = "Center",         -- "Left" | "Center" | "Right" when Width < 1
	Width = 1,                -- docked width as a fraction of the screen width
	Height = 0.56,            -- docked height as a fraction of the screen height
	KeyAspect = 1.2,          -- a key is never taller than KeyAspect * its unit width
	MaxAspect = nil,          -- optional hard cap: docked height <= panel width * MaxAspect
	MinHeight = 190,          -- docked minimum height (px)
	CompactSize = {414, 204}, -- compact panel size at Scale 1 (shrinks to fit small screens)
	CompactPosition = nil,    -- Vector2 centre of the compact panel; nil = bottom centre
	Layout = "Default",       -- starting layout
	Tools = {"undo", "redo", "select", "all", "home", "end"}, -- toolbar; false hides it
	ModeButton = true, HideButton = true, Preview = true, Grip = true,
	Padding = 0.15, Gap = 0.1, KeyRadius = 0.18, -- fractions of one row height
	PanelRadius = 10, CompactRadius = 6, TextScale = 1,
	HeaderHeight = 1, ToolbarHeight = 0.8, -- in row heights
	RepeatDelay = 0.4, RepeatRate = 0.05, FastRepeatAfter = 20, WordDeleteAfter = 15, -- hold-to-repeat
	UndoLimit = 100, DoubleTapSelect = true, SwipeCaret = true, ShiftOnce = true, CloseOnEnter = true,
	CapitalizeFirst = false,  -- Shift is on when a box opens empty
	Animations = true, Transparency = 0,
	-- Colour overrides (Color3); anything nil comes from the window theme:
	-- Panel, Stroke, Grip, Field, FieldStroke, Text, Placeholder, Caret, Selection,
	-- Key, KeyText, ActionKey, ActionText, Tool, ToolText, Enter, EnterText, Active, Pressed
	Colors = {},
}

VKB = {Covers = setmetatable({}, {__mode = "k"}), Held = {}, Undo = {}, Redo = {}, Actions = {},
	Hooks = {Open = {}, Close = {}, Key = {}, Change = {}, Layout = {}, Enter = {}}, Ready = true,
	Shift = false, Caps = false, SelectMode = false}
VKB.Cfg = {Colors = {}}
for k, v in pairs(KB_DEFAULTS) do
	if type(v) == "table" then
		local t = {}
		for a, b in pairs(v) do t[a] = b end
		VKB.Cfg[k] = t
	else
		VKB.Cfg[k] = v
	end
end
VKB.DefaultTheme = {Theme = Library.Themes.Dark, Accent = rgb(255, 89, 89), AccentAlpha = 1}

local function NormMode(m)
	if m == false or m == "Off" or m == "off" or m == "Never" then return "Off" end
	if m == "Always" or m == "always" or m == "Force" then return "Always" end
	return "Auto"
end
-- Phones/tablets only; PC (and touch laptops with a keyboard) keep the normal keyboard.
function TouchDevice()
	return UserInputService.TouchEnabled == true
		and UserInputService.KeyboardEnabled ~= true
		and UserInputService.MouseEnabled ~= true
end
local function UseVKeyboard()
	if not VKB.Ready then return false end
	local m = NormMode(VKB.Cfg.Mode)
	if m == "Off" then return false end
	if m == "Always" then return true end
	return TouchDevice()
end

local function RichEscape(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;"))
end
local function HexOf(c)
	return ("#%02X%02X%02X"):format(math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function PrevChar(text, cur)
	if cur <= 0 then return 0 end
	local ok, p = pcall(utf8.offset, text, -1, cur + 1)
	return (ok and p or cur) - 1
end
local function NextChar(text, cur)
	if cur >= #text then return #text end
	local ok, p = pcall(utf8.offset, text, 2, cur + 1)
	return ok and p and (p - 1) or cur + 1
end
local function WordLeft(text, cur)
	local i = cur
	while i > 0 and text:sub(i, i):match("%s") do i = i - 1 end
	while i > 0 and not text:sub(i, i):match("%s") do i = i - 1 end
	return i
end
local function WordRight(text, cur)
	local n, i = #text, cur
	while i < n and text:sub(i + 1, i + 1):match("%s") do i = i + 1 end
	while i < n and not text:sub(i + 1, i + 1):match("%s") do i = i + 1 end
	return i
end
-- Byte offsets of every character boundary (0 .. #text).
local function Boundaries(text)
	local out = {0}
	if text == "" then return out end
	local ok = pcall(function()
		for p in utf8.codes(text) do
			if p > 1 then table.insert(out, p - 1) end
		end
	end)
	if not ok then
		out = {}
		for i = 0, #text do out[i + 1] = i end
		return out
	end
	table.insert(out, #text)
	return out
end

local function ReadClipboard()
	local f = getclipboard or fromclipboard or (Clipboard and Clipboard.get)
	if type(f) ~= "function" then return nil end
	local ok, r = pcall(f)
	if ok and type(r) == "string" and r ~= "" then return r end
	return nil
end
local function WriteClipboard(s)
	local f = setclipboard or toclipboard or (Clipboard and Clipboard.set)
	if type(f) == "function" then pcall(f, s) end
end
-- TextBoxes here are single-line.
local function OneLine(s)
	return (tostring(s):gsub("\r\n", " "):gsub("[\r\n\t]", " "))
end

local function InputLive(input)
	local st = input.UserInputState
	return st == Enum.UserInputState.Begin or st == Enum.UserInputState.Change
end
local function Inside(gui, pos)
	local p, sz = gui.AbsolutePosition, gui.AbsoluteSize
	return pos.X >= p.X and pos.X <= p.X + sz.X and pos.Y >= p.Y and pos.Y <= p.Y + sz.Y
end
local function MouseOnly(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
end
local function StillDown(input)
	local live = InputLive(input)
	if live and MouseOnly(input) then live = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end
	return live
end
-- Screen position in the keyboard's (IgnoreGuiInset) space. Touch positions exclude the top inset.
local function PointerPos(input)
	if MouseOnly(input) then return UserInputService:GetMouseLocation() end
	local ok, inset = pcall(function() return game:GetService("GuiService"):GetGuiInset() end)
	local p = Vector2.new(input.Position.X, input.Position.Y)
	return ok and p + inset or p
end

-- Hooks return false to cancel the event (Key / Enter) where that applies.
function VKB.Fire(name, ...)
	local list = VKB.Hooks[name]
	if not list then return true end
	local allow = true
	for _, fn in ipairs(CopyList(list)) do
		if SafeCall(fn, ...) == false then allow = false end
	end
	return allow
end
function VKB.Hook(name, fn)
	local list = VKB.Hooks[name]
	if type(fn) ~= "function" or not list then return function() end end
	table.insert(list, fn)
	return function()
		local i = IndexOf(list, fn)
		if i then table.remove(list, i) end
	end
end

-- Normalises a layout entry (string shorthand, action name or table) into a key spec.
local function NormKey(spec)
	if type(spec) == "string" then
		if VKB_ACTIONS[spec] then
			spec = {act = spec}
		elseif (utf8.len(spec) or #spec) == 1 then
			spec = {spec, spec:upper(), letter = spec:match("%a") ~= nil}
		else
			spec = {text = spec, label = spec}
		end
	end
	if type(spec) ~= "table" then return nil end
	if spec.gap then return {spacer = true, w = tonumber(spec.gap) or 1} end
	if type(spec.action) == "function" then spec.act = spec.act or "custom" end
	if spec.act and VKB_ACTIONS[spec.act] then
		local base = VKB_ACTIONS[spec.act]
		if spec.label == nil and spec.icon == nil then
			spec.label, spec.icon = base.label, base.icon
		end
	end
	if spec.text ~= nil and spec.label == nil then spec.label = tostring(spec.text) end
	if spec.act and spec.label == nil and spec.icon == nil then spec.label = spec.id or spec.act end
	return spec
end
local function NormLayout(spec)
	if type(spec) ~= "table" then return nil end
	if spec.Rows == nil and type(spec[1]) == "table" then spec = {Rows = spec} end
	if type(spec.Rows) ~= "table" or #spec.Rows == 0 then return nil end
	local rows, cols = {}, 1
	for _, row in ipairs(spec.Rows) do
		local out, sum = {}, 0
		for _, item in ipairs(row) do
			local k = NormKey(item)
			if k then
				table.insert(out, k)
				sum = sum + (tonumber(k.w) or 1)
			end
		end
		out.sum = sum
		if sum > cols then cols = sum end
		table.insert(rows, out)
	end
	return {Rows = rows, Cols = cols, Width = spec.Width, CompactSize = spec.CompactSize, Tools = spec.Tools,
		Height = spec.Height, KeyAspect = spec.KeyAspect}
end
for name, spec in pairs(VKB_LAYOUTS) do VKB_LAYOUTS[name] = NormLayout(spec) end

function VKB.CurrentLayout()
	local name = VKB.LayoutName or VKB.Cfg.Layout or "Default"
	local lay = VKB_LAYOUTS[name]
	if not lay then
		lay, VKB.LayoutName = VKB_LAYOUTS.Default, "Default"
	end
	return lay
end

function VKB.MakeKey(spec, parent)
	local b = Create("TextButton", {BorderSizePixel = 0, Text = "", Parent = parent})
	local corner = Corner(b, 4)
	local k = {spec = spec, btn = b, corner = corner, stroke = Stroke(b, WHITE, 1)}
	if spec.icon then
		k.icon = CreateIcon(b, nil, 12, UDim2.new(0.5, -6, 0.5, -6))
		k.icon.Visible = ApplyIcon(k.icon, spec.icon)
		if not k.icon.Visible then k.icon = nil end
	end
	if not k.icon then
		k.label = Label(b, spec.label or spec[1] or "", {Align = Enum.TextXAlignment.Center, Weight = spec.act and "SemiBold" or "Medium"})
	end
	b.InputBegan:Connect(function(input)
		if IsClickOrTouch(input) then VKB.Press(k, input) end
	end)
	table.insert(VKB.Keys, k)
	return k
end

-- (Re)creates the toolbar and the character rows for the current layout; header keys persist.
function VKB.BuildKeys()
	if not VKB.Panel then return end
	for _, k in ipairs(VKB.ToolKeys or {}) do pcall(function() k.btn:Destroy() end) end
	for _, row in ipairs(VKB.RowKeys or {}) do
		for _, k in ipairs(row) do
			if k.btn then pcall(function() k.btn:Destroy() end) end
		end
	end
	VKB.Keys = {}
	for _, k in ipairs(VKB.HeaderKeys) do table.insert(VKB.Keys, k) end
	VKB.ToolKeys, VKB.RowKeys = {}, {}
	local lay = VKB.CurrentLayout()
	local tools = lay.Tools
	if tools == nil then tools = VKB.Cfg.Tools end
	if type(tools) == "table" then
		for _, t in ipairs(tools) do
			local spec = NormKey(t)
			if spec and not spec.spacer then
				local k = VKB.MakeKey(spec, VKB.Panel)
				k.place = "tool"
				table.insert(VKB.ToolKeys, k)
			end
		end
	end
	for r, row in ipairs(lay.Rows) do
		VKB.RowKeys[r] = {sum = row.sum}
		for _, spec in ipairs(row) do
			if spec.spacer then
				table.insert(VKB.RowKeys[r], {spacer = true, spec = spec})
			else
				table.insert(VKB.RowKeys[r], VKB.MakeKey(spec, VKB.Panel))
			end
		end
	end
end

function VKB.Build()
	if VKB.Keys then return end
	VKB.Keys = {}
	if VKB.Compact == nil then VKB.Compact = Library.KeyboardCompact == true or VKB.Cfg.Compact == true end
	local gui = Create("ScreenGui", {
		Name = "ZeninKeyboard",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 200,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	local root = Create("Frame", {BackgroundTransparency = 1, Visible = false, Parent = gui})
	local scaler = Create("UIScale", {Parent = root})
	local panel = Create("Frame", {Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Active = true, Parent = root})
	local panelCorner = Corner(panel, 6)
	local stroke = Stroke(panel, WHITE, 1)

	local grip = Create("Frame", {BackgroundTransparency = 1, Active = true, Parent = panel})
	local gripIcon = CreateIcon(grip, {"grip-vertical", "grip", "move"}, 14, UDim2.new(0.5, -7, 0.5, -7))
	local field = Create("Frame", {BorderSizePixel = 0, ClipsDescendants = true, Active = true, Parent = panel})
	Corner(field, 5)
	local fieldStroke = Stroke(field, WHITE, 1)
	local preview = Create("TextLabel", {
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Text = "",
		RichText = true,
		Weight = "Medium",
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = field,
	})
	local measure = Create("TextLabel", {
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Position = UDim2.fromOffset(0, -1000),
		BackgroundTransparency = 1,
		TextTransparency = 1,
		Text = "",
		Weight = "Medium",
		Parent = field,
	})
	local caret = Create("Frame", {Size = UDim2.fromOffset(2, 14), BorderSizePixel = 0, Parent = field})

	VKB.Gui, VKB.Root, VKB.Scaler, VKB.Panel, VKB.PanelCorner = gui, root, scaler, panel, panelCorner
	VKB.Stroke, VKB.Grip, VKB.GripIcon, VKB.Field, VKB.FieldStroke = stroke, grip, gripIcon, field, fieldStroke
	VKB.Preview, VKB.Measure, VKB.Caret = preview, measure, caret

	VKB.HeaderKeys = {}
	for _, name in ipairs({"mode", "hide"}) do
		local k = VKB.MakeKey(NormKey(name), panel)
		k.place = "header"
		table.insert(VKB.HeaderKeys, k)
	end
	VKB.BuildKeys()

	grip.InputBegan:Connect(function(input)
		if not IsClickOrTouch(input) or not VKB.Compact then return end
		VKB.Drag = {input = input, from = PointerPos(input), start = VKB.Pos or Vector2.new(0, 0)}
		VKB.Track()
	end)
	field.InputBegan:Connect(function(input)
		if IsClickOrTouch(input) and VKB.Target then VKB.FieldDown(input) end
	end)

	-- Screen rotation / resize.
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if VKB.Target and gui.AbsoluteSize.X >= 1 then VKB.Layout() end
	end)
end

function VKB.Viewport()
	local vp = VKB.Gui.AbsoluteSize
	if vp.X < 1 then vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600) end
	return vp
end

function VKB.ScaleMult()
	return math.clamp(tonumber(Library.KeyboardScale) or tonumber(VKB.Cfg.Scale) or 1, 0.3, 3)
end

-- Everything is derived from one row height, so the proportions are identical at any panel
-- size, in both docked and compact mode and for every layout.
function VKB.Layout()
	if not VKB.Root then return end
	local C = VKB.Cfg
	local vp = VKB.Viewport()
	local mult = VKB.ScaleMult()
	local lay = VKB.CurrentLayout()
	local hasTools = #VKB.ToolKeys > 0
	local showMode, showHide = C.ModeButton ~= false, C.HideButton ~= false
	local hasHeader = C.Preview ~= false or showMode or showHide or VKB.Compact
	local headH = hasHeader and (tonumber(C.HeaderHeight) or 1) or 0
	local toolH = hasTools and (tonumber(C.ToolbarHeight) or 0.8) or 0
	local bands = #lay.Rows + (hasTools and 1 or 0) + (hasHeader and 1 or 0)
	local padU, gapU = math.max(0, tonumber(C.Padding) or 0.15), math.max(0, tonumber(C.Gap) or 0.1)
	local hUnits = #lay.Rows + headH + toolH + padU * 2 + gapU * (bands - 1)
	local cols = math.max(1, lay.Cols)

	local w, h
	if VKB.Compact then
		local cs = lay.CompactSize or C.CompactSize or {414, 204}
		local cw, ch = tonumber(cs[1]) or 414, tonumber(cs[2]) or 204
		local fit = math.max(0.5, math.min(1, (vp.X - 16) / cw, (vp.Y * 0.6) / ch)) * mult
		w, h = math.floor(cw * fit), math.floor(ch * fit)
		VKB.Root.AnchorPoint = Vector2.new(0.5, 0.5)
		VKB.PanelCorner.CornerRadius = UDim.new(0, tonumber(C.CompactRadius) or 6)
	else
		local frac = math.clamp(tonumber(lay.Width) or tonumber(C.Width) or 1, 0.2, 1)
		w = math.floor(vp.X * frac)
		-- Key height is capped relative to its width, so a 4-column pad can be tall and a
		-- 15-column keyboard stays flat in landscape.
		local aspect = math.max(0.3, tonumber(lay.KeyAspect) or tonumber(C.KeyAspect) or 1.2)
		-- Largest row height whose unit width still satisfies u <= aspect * unit (unit depends on u
		-- through the padding/gap, hence the solved form).
		local uMax = aspect * w / math.max(0.1, cols + aspect * (2 * padU - gapU))
		local hMax = uMax * hUnits
		if tonumber(C.MaxAspect) then hMax = math.min(hMax, w * tonumber(C.MaxAspect)) end
		h = math.min(vp.Y * (tonumber(lay.Height) or tonumber(C.Height) or 0.56), hMax) * mult
		h = math.floor(math.clamp(h, math.min(tonumber(C.MinHeight) or 190, vp.Y * 0.85), vp.Y * 0.85))
		local ax = C.Align == "Left" and 0 or (C.Align == "Right" and 1 or 0.5)
		if C.Dock == "Top" then
			VKB.Root.AnchorPoint = Vector2.new(ax, 0)
			VKB.Root.Position = UDim2.fromScale(ax, 0)
		else
			VKB.Root.AnchorPoint = Vector2.new(ax, 1)
			VKB.Root.Position = UDim2.fromScale(ax, 1)
		end
		VKB.PanelCorner.CornerRadius = UDim.new(0, tonumber(C.PanelRadius) or 10)
	end
	VKB.Size = Vector2.new(w, h)
	VKB.Root.Size = UDim2.fromOffset(w, h)

	local u = h / hUnits -- one row
	local pad, gap = u * padU, u * gapU
	local unit = (w - pad * 2 + gap) / cols
	VKB.Unit = unit
	local ts = tonumber(C.TextScale) or 1
	local base = math.min(u, unit * 1.3) * ts -- narrow keys shrink their text, never overflow
	local keyText = math.max(8, math.floor(base * 0.42 + 0.5))
	local actText = math.max(7, math.floor(base * 0.32 + 0.5))
	local iconSz = math.max(8, math.floor(base * 0.45 + 0.5))
	local radius = math.max(2, math.floor(u * (tonumber(C.KeyRadius) or 0.18) + 0.5))

	local function Put(k, x, y, kw, kh, textSize)
		k.btn.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
		k.btn.Size = UDim2.fromOffset(math.max(1, math.floor(kw + 0.5)), math.max(1, math.floor(kh + 0.5)))
		k.corner.CornerRadius = UDim.new(0, radius)
		if k.label then k.label.TextSize = textSize end
		if k.icon then
			k.icon.Size = UDim2.fromOffset(iconSz, iconSz)
			k.icon.Position = UDim2.new(0.5, -iconSz / 2, 0.5, -iconSz / 2)
		end
	end

	-- Header: [grip] [text field] [mode] [hide]
	local y, x = pad, pad
	local hh = u * headH
	VKB.Grip.Visible = hasHeader and VKB.Compact and C.Grip ~= false
	if VKB.Grip.Visible then
		local gw = math.max(22, hh * 0.9)
		VKB.Grip.Position = UDim2.fromOffset(x, y)
		VKB.Grip.Size = UDim2.fromOffset(gw, hh)
		x = x + gw + gap
	end
	local right = w - pad
	for i = #VKB.HeaderKeys, 1, -1 do
		local k = VKB.HeaderKeys[i]
		local show = hasHeader and ((k.spec.act == "mode" and showMode) or (k.spec.act == "hide" and showHide))
		k.btn.Visible = show
		if show then
			local bw = hh * 1.25
			right = right - bw
			Put(k, right, y, bw, hh, actText)
			right = right - gap
		end
	end
	VKB.Field.Visible = hasHeader and C.Preview ~= false
	VKB.Field.Position = UDim2.fromOffset(math.floor(x), y)
	VKB.Field.Size = UDim2.fromOffset(math.max(1, math.floor(right - x)), math.floor(hh))
	local fieldText = math.max(8, math.floor(hh * 0.45 * ts + 0.5))
	VKB.Preview.TextSize, VKB.Measure.TextSize = fieldText, fieldText
	VKB.Caret.Size = UDim2.fromOffset(2, math.floor(fieldText * 1.25))
	VKB.BarW = nil
	if hasHeader then y = y + hh + gap end

	-- Toolbar
	if hasTools then
		local n = #VKB.ToolKeys
		local th = u * toolH
		local tw = (w - pad * 2 - gap * (n - 1)) / n
		for i, k in ipairs(VKB.ToolKeys) do
			Put(k, pad + (i - 1) * (tw + gap), y, tw, th, actText)
		end
		y = y + th + gap
	end

	-- Keys; rows narrower than the widest row are centred.
	for _, row in ipairs(VKB.RowKeys) do
		x = pad + (cols - (row.sum or cols)) * unit / 2
		for _, k in ipairs(row) do
			local kw = (tonumber(k.spec.w) or 1) * unit - gap
			if not k.spacer then
				Put(k, x, y, kw, u, k.spec.act and actText or keyText)
			end
			x = x + kw + gap
		end
		y = y + u + gap
	end

	if VKB.Compact then
		local p = VKB.Pos or C.CompactPosition or Vector2.new(vp.X / 2, vp.Y - h / 2 - 12)
		VKB.Place(p.X, p.Y)
	end
	if VKB.Target then
		VKB.Labels()
		VKB.Render()
	end
	VKB.Fire("Layout", VKB.LayoutName or "Default", VKB.Size, VKB.Compact)
end

-- Keeps the compact keyboard fully on screen; position is the panel centre.
function VKB.Place(x, y)
	local vp, sz = VKB.Viewport(), VKB.Size
	local hw, hh = sz.X / 2, sz.Y / 2
	x = math.clamp(x, hw, math.max(hw, vp.X - hw))
	y = math.clamp(y, hh, math.max(hh, vp.Y - hh))
	VKB.Root.Position = UDim2.fromOffset(x, y)
	VKB.Pos = Vector2.new(x, y)
end

function VKB.SetCompact(b)
	b = b == true
	VKB.Cfg.Compact = b
	if VKB.Compact == b then return end
	VKB.Compact = b
	if not VKB.Root then return end
	VKB.Layout()
	if VKB.Shown and VKB.Target and VKB.Cfg.Animations ~= false then
		StopTweens(VKB.Scaler)
		VKB.Scaler.Scale = 0.97
		Tween(VKB.Scaler, VKB_IN, {Scale = 1})
	end
	VKB.Labels()
end

-- Switches the character rows (and toolbar) to a named layout.
function VKB.UseLayout(name, quiet)
	name = VKB_LAYOUTS[name] and name or "Default"
	local changed = VKB.LayoutName ~= name
	VKB.LayoutName = name
	if not VKB.Root then return end
	if changed or #VKB.RowKeys == 0 then VKB.BuildKeys() end
	if quiet then return end
	VKB.Layout()
	VKB.Labels()
	VKB.Paint()
end

local function ThemeSrc()
	local src = VKB.Opts and VKB.Opts.theme or VKB.DefaultTheme
	return src.Theme or Library.Themes.Dark, src.Accent or VKB.DefaultTheme.Accent, src.AccentAlpha or 1
end
local function Col(name, fallback)
	local c = VKB.Cfg.Colors and VKB.Cfg.Colors[name]
	if typeof(c) == "Color3" then return c end
	return fallback
end

function VKB.Paint()
	if not VKB.Panel then return end
	local T, accent, alpha = ThemeSrc()
	VKB.Panel.BackgroundColor3 = Col("Panel", T.WmBg)
	VKB.Panel.BackgroundTransparency = math.clamp(tonumber(VKB.Cfg.Transparency) or 0, 0, 0.95)
	VKB.Stroke.Color = Col("Stroke", T.WmStroke)
	VKB.GripIcon.ImageColor3 = Col("Grip", T.NavGray)
	VKB.Field.BackgroundColor3 = Col("Field", T.DropdownBg)
	VKB.FieldStroke.Color = Col("FieldStroke", accent)
	VKB.FieldStroke.Transparency = Col("FieldStroke") and 0 or (1 - alpha)
	VKB.Preview.TextColor3 = Col("Text", T.Text)
	VKB.Caret.BackgroundColor3 = Col("Caret", accent)
	for _, k in ipairs(VKB.Keys) do VKB.PaintKey(k) end
end

function VKB.PaintKey(k)
	local T, accent, alpha = ThemeSrc()
	local act = k.spec.act
	local active = Col("Active", accent)
	local on = (act == "shift" and VKB.Shift) or (act == "caps" and VKB.Caps) or (act == "select" and VKB.SelectMode)
		or (act == "layout" and k.spec.to == VKB.LayoutName)
	local bg, bgT, fg
	if k.place == "tool" or k.place == "header" then
		bg, bgT = Col("Tool", T.DropdownBg), k.down and 0 or 0.45
		fg = Col("ToolText", T.TextGray)
	elseif act == "enter" then
		bg, bgT = Col("Enter", T.DropdownBg:Lerp(accent, 0.35 * alpha)), 0
		fg = Col("EnterText", T.Text)
	elseif act then
		bg, bgT = Col("ActionKey", T.DropdownBg:Lerp(T.WmBg, 0.55)), 0
		fg = Col("ActionText", T.TextGray)
	else
		bg, bgT = Col("Key", T.DropdownBg), 0
		fg = Col("KeyText", T.Text)
	end
	if k.down then bg = Col("Pressed", T.TileHover:Lerp(T.Text, 0.1)) end
	if on then fg = active end
	k.btn.BackgroundColor3 = bg
	k.btn.BackgroundTransparency = bgT
	k.stroke.Color = on and active or T.DropdownBorder
	k.stroke.Transparency = on and (1 - alpha) or ((k.place == "tool" or k.place == "header") and 1 or 0.4)
	if k.label then k.label.TextColor3 = fg end
	if k.icon then k.icon.ImageColor3 = fg end
end

function VKB.Labels()
	if not VKB.Keys then return end
	local upper = VKB.Caps ~= VKB.Shift
	for _, k in ipairs(VKB.Keys) do
		local s = k.spec
		if k.label then
			if not s.act and s.text == nil then
				if s.letter then
					k.label.Text = upper and (s[2] or s[1]) or s[1]
				else
					k.label.Text = VKB.Shift and (s[2] or s[1]) or s[1]
				end
			elseif s.act == "mode" then
				k.label.Text = VKB.Compact and "+" or "-"
			end
		end
		if k.icon and s.act == "mode" then
			ApplyIcon(k.icon, VKB.Compact and {"maximize-2"} or {"minimize-2"})
		end
		VKB.PaintKey(k)
	end
end

-- Width of text in the field's font. Trailing spaces count (measured against a "|" sentinel).
function VKB.TextWidth(s)
	local m = VKB.Measure
	if not VKB.BarW then
		m.Text = "|"
		VKB.BarW = m.TextBounds.X
	end
	m.Text = s .. "|"
	return m.TextBounds.X - VKB.BarW
end

local function Selection()
	local a, c = VKB.Anchor, VKB.Cursor
	if a and a ~= c then return math.min(a, c), math.max(a, c) end
	return nil
end

function VKB.Render()
	if not VKB.Target or not VKB.Field then return end
	local T, accent = ThemeSrc()
	local text, cur = VKB.Text, VKB.Cursor
	local fw = VKB.Field.AbsoluteSize.X
	local padX = 8
	if text == "" then
		local ph = VKB.Target.PlaceholderText or ""
		VKB.Preview.Text = ph ~= "" and ('<font color="%s">%s</font>'):format(HexOf(Col("Placeholder", T.TextDim)), RichEscape(ph)) or ""
		VKB.Scroll = 0
	else
		local a, b = Selection()
		if a then
			VKB.Preview.Text = RichEscape(text:sub(1, a))
				.. ('<mark color="%s" transparency="0.55">'):format(HexOf(Col("Selection", accent)))
				.. RichEscape(text:sub(a + 1, b)) .. "</mark>" .. RichEscape(text:sub(b + 1))
		else
			VKB.Preview.Text = RichEscape(text)
		end
	end
	local cx = text == "" and 0 or VKB.TextWidth(text:sub(1, cur))
	local scroll = VKB.Scroll or 0
	local view = fw - padX * 2
	if cx - scroll > view then scroll = cx - view end
	if cx - scroll < 0 then scroll = cx end
	local total = text == "" and 0 or VKB.TextWidth(text)
	scroll = math.clamp(scroll, 0, math.max(0, total - view))
	VKB.Scroll = scroll
	VKB.Preview.Position = UDim2.fromOffset(padX - scroll, 0)
	local ch = VKB.Caret.AbsoluteSize.Y
	VKB.Caret.Position = UDim2.fromOffset(math.floor(padX - scroll + cx), math.floor((VKB.Field.AbsoluteSize.Y - ch) / 2))
	VKB.LastEdit = os.clock()
	VKB.Caret.Visible = true
end

-- Character index nearest to a screen X inside the field.
function VKB.IndexAt(x)
	local text = VKB.Text
	if text == "" then return 0 end
	local rel = x - VKB.Field.AbsolutePosition.X - 8 + (VKB.Scroll or 0)
	local bounds = Boundaries(text)
	local lo, hi = 1, #bounds
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if VKB.TextWidth(text:sub(1, bounds[mid])) <= rel then lo = mid else hi = mid - 1 end
	end
	local i = bounds[lo]
	local nxt = bounds[lo + 1]
	if nxt then
		local w0, w1 = VKB.TextWidth(text:sub(1, i)), VKB.TextWidth(text:sub(1, nxt))
		if rel - w0 > (w1 - w0) / 2 then i = nxt end
	end
	return i
end

-- Writes to the target box; its own handlers may trim (MaxLength etc.), so read back what stuck.
function VKB.SetText(text, cursor, anchor)
	local box = VKB.Target
	if not box then return end
	local before = box.Text
	box.Text = text
	VKB.Text = box.Text
	VKB.Cursor = math.clamp(cursor, 0, #VKB.Text)
	VKB.Anchor = anchor and math.clamp(anchor, 0, #VKB.Text) or nil
	VKB.Render()
	if before ~= VKB.Text then VKB.Fire("Change", VKB.Text, box) end
end

-- Undo history: consecutive typing / deleting within a second merges into one step.
function VKB.Record(kind)
	local now = os.clock()
	local merge = (kind == "type" or kind == "back") and VKB.LastKind == kind and now - (VKB.LastRec or 0) < 1
	if not merge then
		table.insert(VKB.Undo, {VKB.Text, VKB.Cursor, VKB.Anchor})
		local limit = math.max(1, math.floor(tonumber(VKB.Cfg.UndoLimit) or 100))
		while #VKB.Undo > limit do table.remove(VKB.Undo, 1) end
	end
	table.clear(VKB.Redo)
	VKB.LastKind, VKB.LastRec = kind, now
end
local function Restore(from, to)
	local s = table.remove(from)
	if not s then return end
	table.insert(to, {VKB.Text, VKB.Cursor, VKB.Anchor})
	VKB.LastKind = nil
	VKB.SelectMode = false
	VKB.SetText(s[1], s[2], s[3])
	VKB.Labels()
end

function VKB.Insert(str, kind)
	str = tostring(str or "")
	if str == "" or not VKB.Target then return end
	local text = VKB.Text
	local a, b = Selection()
	if not a then a, b = VKB.Cursor, VKB.Cursor end
	VKB.Record(kind or "type")
	if VKB.SelectMode then
		VKB.SelectMode = false
		VKB.Labels()
	end
	VKB.SetText(text:sub(1, a) .. str .. text:sub(b + 1), a + #str)
end

function VKB.DeleteBack(word)
	if not VKB.Target then return end
	local text = VKB.Text
	local a, b = Selection()
	if a then
		VKB.Record("cut")
		VKB.SelectMode = false
		VKB.SetText(text:sub(1, a) .. text:sub(b + 1), a)
		VKB.Labels()
		return
	end
	local cur = VKB.Cursor
	if cur == 0 then return end
	local p = word and WordLeft(text, cur) or PrevChar(text, cur)
	VKB.Record(word and "word" or "back")
	VKB.SetText(text:sub(1, p) .. text:sub(cur + 1), p)
end

-- dir: -1/1 char, "home"/"end". In select mode the selection grows instead of collapsing.
function VKB.Move(dir)
	if not VKB.Target then return end
	local text, cur = VKB.Text, VKB.Cursor
	local a, b = Selection()
	VKB.LastKind = nil
	if not VKB.SelectMode and a and (dir == -1 or dir == 1) then
		VKB.SetText(text, dir < 0 and a or b, nil)
		return
	end
	local nc
	if dir == "home" then nc = 0
	elseif dir == "end" then nc = #text
	elseif dir < 0 then nc = PrevChar(text, cur)
	else nc = NextChar(text, cur) end
	local anchor = nil
	if VKB.SelectMode then anchor = VKB.Anchor or cur end
	VKB.SetText(text, nc, anchor)
end

-- Clipboard actions are only reachable when "cut"/"copy"/"paste" are placed in Tools or a layout.
function VKB.Copy(cut)
	local text = VKB.Text
	local a, b = Selection()
	if not a then a, b = 0, #text end
	local s = text:sub(a + 1, b)
	if s == "" then return end
	VKB.Clip = s
	WriteClipboard(s)
	if cut then
		VKB.Record("cut")
		VKB.SetText(text:sub(1, a) .. text:sub(b + 1), a)
	end
	if VKB.SelectMode then
		VKB.SelectMode = false
		VKB.Labels()
	end
end
function VKB.Paste()
	local s = ReadClipboard() or VKB.Clip
	if s then VKB.Insert(OneLine(s), "paste") end
end

function VKB.Act(k)
	local s = k.spec
	local act = s.act
	if VKB.Fire("Key", s, Library.Keyboard) == false then return end
	if type(s.action) == "function" then
		SafeCall(s.action, Library.Keyboard, s)
		return
	end
	if not act then
		local ch
		if s.text ~= nil then
			ch = tostring(s.text)
		elseif s.letter then
			ch = (VKB.Caps ~= VKB.Shift) and (s[2] or s[1]) or s[1]
		else
			ch = VKB.Shift and (s[2] or s[1]) or s[1]
		end
		VKB.Insert(ch, "type")
		if VKB.Shift and VKB.Cfg.ShiftOnce ~= false then
			VKB.Shift = false
			VKB.Labels()
		end
	elseif act == "custom" then
		local fn = VKB.Actions[s.id or ""]
		if fn then SafeCall(fn, Library.Keyboard, s) end
	elseif act == "layout" then
		VKB.UseLayout(s.to or "Default")
	elseif act == "back" then
		VKB.DeleteBack(false)
	elseif act == "wordback" then
		VKB.DeleteBack(true)
	elseif act == "clear" then
		if VKB.Text ~= "" then
			VKB.Record("clear")
			VKB.SetText("", 0)
		end
	elseif act == "left" then
		VKB.Move(-1)
	elseif act == "right" then
		VKB.Move(1)
	elseif act == "home" or act == "end" then
		VKB.Move(act)
	elseif act == "shift" then
		VKB.Shift = not VKB.Shift
		VKB.Labels()
	elseif act == "caps" then
		VKB.Caps = not VKB.Caps
		VKB.Labels()
	elseif act == "select" then
		VKB.SelectMode = not VKB.SelectMode
		if VKB.SelectMode then
			VKB.Anchor = VKB.Anchor or VKB.Cursor
		else
			VKB.Anchor = nil
		end
		VKB.Render()
		VKB.Labels()
	elseif act == "all" then
		VKB.SelectMode = true
		VKB.SetText(VKB.Text, #VKB.Text, 0)
		VKB.Labels()
	elseif act == "cut" then
		VKB.Copy(true)
	elseif act == "copy" then
		VKB.Copy(false)
	elseif act == "paste" then
		VKB.Paste()
	elseif act == "undo" then
		Restore(VKB.Undo, VKB.Redo)
	elseif act == "redo" then
		Restore(VKB.Redo, VKB.Undo)
	elseif act == "mode" then
		VKB.SetCompact(not VKB.Compact)
	elseif act == "enter" then
		if VKB.Fire("Enter", VKB.Target, VKB.Text) == false then return end
		if VKB.Cfg.CloseOnEnter ~= false then
			VKB.Close(true)
		elseif VKB.Opts and VKB.Opts.onEnter then
			SafeCall(VKB.Opts.onEnter, VKB.Text)
		end
	elseif act == "hide" then
		VKB.Close(false)
	end
end

-- Tap the field to place the caret, drag across it to select, double-tap to select a word.
function VKB.FieldDown(input)
	local pos = PointerPos(input)
	local idx = VKB.IndexAt(pos.X)
	local now = os.clock()
	local last = VKB.LastTap
	VKB.LastTap = {t = now, idx = idx}
	VKB.LastKind = nil
	if VKB.Cfg.DoubleTapSelect ~= false and last and now - last.t < 0.35 and math.abs(last.idx - idx) <= 2 and VKB.Text ~= "" then
		local text = VKB.Text
		local a = WordLeft(text, idx)
		local b = WordRight(text, a)
		VKB.SelectMode = false
		VKB.SetText(text, b, a)
		VKB.Labels()
		VKB.LastTap = nil
		return
	end
	VKB.SelectMode = false
	VKB.SetText(VKB.Text, idx, nil)
	VKB.Labels()
	VKB.FieldDrag = {input = input, start = idx}
	VKB.Track()
end

function VKB.Press(k, input)
	if not VKB.Target or VKB.Held[input] then return end
	VKB.Held[input] = k
	k.down = (k.down or 0) + 1
	k.tok = (k.tok or 0) + 1
	VKB.Track()
	VKB.PaintKey(k)
	if k.spec.act == "space" then
		-- Space types on release; sliding along it moves the caret instead (like phone keyboards).
		k.swipeX, k.moved = PointerPos(input).X, false
		return
	end
	VKB.Act(k)
	if VKB_REPEAT[k.spec.act] then
		local C = VKB.Cfg
		local tok = k.tok
		local delay = math.max(0.05, tonumber(C.RepeatDelay) or 0.4)
		local rate = math.max(0.01, tonumber(C.RepeatRate) or 0.05)
		local fastAfter = tonumber(C.FastRepeatAfter) or 20
		local wordAfter = tonumber(C.WordDeleteAfter) or 15
		task.delay(delay, function()
			local n = 0
			while k.tok == tok and k.down and VKB.Target do
				n = n + 1
				if k.spec.act == "back" and wordAfter > 0 and n > wordAfter then
					-- Long hold on Back speeds up to whole words.
					VKB.DeleteBack(true)
					task.wait(rate * 2.8)
				else
					VKB.Act(k)
					task.wait(n > fastAfter and rate * 0.6 or rate)
				end
			end
		end)
	end
end

function VKB.Release(k)
	k.down = k.down and k.down > 1 and k.down - 1 or nil
	if not k.down then k.tok = (k.tok or 0) + 1 end
	VKB.PaintKey(k)
end

function VKB.SpaceMove(k, x)
	if VKB.Cfg.SwipeCaret == false then return end
	local step = math.max(6, (VKB.Unit or 20) * 0.5)
	local dx = x - k.swipeX
	while math.abs(dx) >= step and VKB.Target do
		local d = dx > 0 and 1 or -1
		VKB.Move(d)
		k.swipeX = k.swipeX + step * d
		dx = dx - step * d
		k.moved = true
	end
end

-- Roblox does not reliably fire InputEnded for a finger that slid around before lifting, which
-- left keys stuck. While anything is held, poll each InputObject's own state instead: a key is
-- released when its touch ends/cancels or the finger slides off it.
function VKB.Step()
	for input, k in pairs(VKB.Held) do
		local live = StillDown(input)
		if k.spec.act == "space" then
			if live then
				VKB.SpaceMove(k, PointerPos(input).X)
			else
				VKB.Held[input] = nil
				if not k.moved and VKB.Target and VKB.Fire("Key", k.spec, Library.Keyboard) ~= false then VKB.Insert(" ", "space") end
				VKB.Release(k)
			end
		elseif not live or not Inside(k.btn, PointerPos(input)) then
			VKB.Held[input] = nil
			VKB.Release(k)
		end
	end
	local f = VKB.FieldDrag
	if f then
		if not StillDown(f.input) or not VKB.Target then
			VKB.FieldDrag = nil
		else
			local idx = VKB.IndexAt(PointerPos(f.input).X)
			if idx ~= VKB.Cursor then VKB.SetText(VKB.Text, idx, idx ~= f.start and f.start or nil) end
		end
	end
	local d = VKB.Drag
	if d then
		if not StillDown(d.input) or not VKB.Compact then
			VKB.Drag = nil
		else
			local delta = PointerPos(d.input) - d.from
			VKB.Place(d.start.X + delta.X, d.start.Y + delta.Y)
		end
	end
	if not VKB.Drag and not VKB.FieldDrag and next(VKB.Held) == nil and VKB.Tracker then
		VKB.Tracker:Disconnect()
		VKB.Tracker = nil
	end
end
function VKB.Track()
	if not VKB.Tracker then VKB.Tracker = RunService.RenderStepped:Connect(VKB.Step) end
end
function VKB.ReleaseAll()
	for input, k in pairs(VKB.Held) do
		VKB.Held[input] = nil
		VKB.Release(k)
	end
	VKB.Drag, VKB.FieldDrag = nil, nil
	for _, k in ipairs(VKB.Keys or {}) do
		k.down, k.tok = nil, (k.tok or 0) + 1
		VKB.PaintKey(k)
	end
end

local function OnScreen(obj)
	local o = obj
	while o do
		if o:IsA("ScreenGui") then return o.Enabled and o.Parent ~= nil end
		if o:IsA("GuiObject") and not o.Visible then return false end
		o = o.Parent
	end
	return false
end

function VKB.Show(show)
	VKB.Shown = show
	VKB.ShowTok = (VKB.ShowTok or 0) + 1
	local tok = VKB.ShowTok
	local root, scaler = VKB.Root, VKB.Scaler
	StopTweens(scaler)
	if VKB.Cfg.Animations == false then
		scaler.Scale = 1
		root.Visible = show
		return
	end
	if show then
		root.Visible = true
		scaler.Scale = VKB_HIDDEN
		Tween(scaler, VKB_IN, {Scale = 1})
	else
		Tween(scaler, VKB_OUT, {Scale = VKB_HIDDEN})
	end
	FadeContent(VKB.Panel, root, UDim2.fromScale(1, 1), show, show and VKB_IN or VKB_OUT, 1, function()
		if VKB.ShowTok == tok and not show then root.Visible = false end
	end)
end

function VKB.Open(box, opts)
	opts = opts or {}
	if typeof(box) ~= "Instance" or not box:IsA("TextBox") then return false end
	if VKB.Target == box then return true end
	local sg = box:FindFirstAncestorWhichIsA("ScreenGui")
	if not sg then return false end
	if VKB.Target then VKB.Close(false, true) end
	VKB.Build()
	if VKB.Gui.Parent ~= sg.Parent then
		VKB.Purge(sg.Parent)
		VKB.Gui.Parent = sg.Parent
	end
	VKB.Gui.DisplayOrder = sg.DisplayOrder + 50
	VKB.Target, VKB.Opts = box, opts
	VKB.Shift, VKB.Caps, VKB.SelectMode, VKB.Anchor, VKB.Scroll = false, VKB.Caps == true, false, nil, 0
	table.clear(VKB.Undo)
	table.clear(VKB.Redo)
	VKB.LastKind, VKB.LastTap = nil, nil
	if opts.onFocus then SafeCall(opts.onFocus) end
	if box.ClearTextOnFocus then box.Text = "" end
	VKB.Text = box.Text
	VKB.Cursor = #VKB.Text
	if VKB.Cfg.CapitalizeFirst == true and VKB.Text == "" then VKB.Shift = true end
	VKB.ReleaseAll()

	VKB.UseLayout(opts.Layout or VKB.Cfg.Layout or "Default", true)
	VKB.Layout()
	VKB.Labels()
	VKB.Paint()
	VKB.Render()
	if not VKB.Shown then VKB.Show(true) end

	if VKB.Watch then VKB.Watch:Disconnect() end
	VKB.Watch = RunService.Heartbeat:Connect(function()
		local b = VKB.Target
		if b and (not b.Parent or not b.TextEditable or not OnScreen(b)) then
			VKB.Close(false)
			return
		end
		if b and b.Text ~= VKB.Text then
			VKB.Text = b.Text
			VKB.Cursor = math.min(VKB.Cursor, #VKB.Text)
			VKB.Anchor = VKB.Anchor and math.min(VKB.Anchor, #VKB.Text) or nil
			VKB.LastKind = nil
			VKB.Render()
		end
		-- Solid while typing, then a calm blink.
		VKB.Caret.Visible = ((os.clock() - (VKB.LastEdit or 0)) % 1.1) < 0.6
	end)
	VKB.Fire("Open", box)
	return true
end

-- Keyboards left over from an earlier execution of the script would otherwise stay on screen.
function VKB.Purge(parent)
	if not parent then return end
	for _, c in ipairs(parent:GetChildren()) do
		if c.Name == "ZeninKeyboard" and c ~= VKB.Gui then pcall(function() c:Destroy() end) end
	end
end

-- Fully removes the keyboard (window unload); it is rebuilt on next use.
function VKB.Destroy()
	if VKB.Target then VKB.Close(false, true) end
	if VKB.Tracker then VKB.Tracker:Disconnect() VKB.Tracker = nil end
	if VKB.Gui then pcall(function() VKB.Gui:Destroy() end) end
	VKB.Gui, VKB.Root, VKB.Scaler, VKB.Panel, VKB.PanelCorner, VKB.Stroke = nil, nil, nil, nil, nil, nil
	VKB.Grip, VKB.GripIcon, VKB.Field, VKB.FieldStroke, VKB.Preview, VKB.Measure, VKB.Caret = nil, nil, nil, nil, nil, nil, nil
	VKB.Keys, VKB.Shown, VKB.Drag, VKB.FieldDrag, VKB.Target = nil, nil, nil, nil, nil
	VKB.HeaderKeys, VKB.ToolKeys, VKB.RowKeys = nil, nil, nil
	VKB.Held = {}
end

-- switching: another box is about to open, so skip the hide animation.
function VKB.Close(enter, switching)
	local box, opts = VKB.Target, VKB.Opts
	if not box then return end
	VKB.Target = nil
	if VKB.Watch then
		VKB.Watch:Disconnect()
		VKB.Watch = nil
	end
	VKB.ReleaseAll()
	if not switching then VKB.Show(false) end
	if opts and opts.onBlur then SafeCall(opts.onBlur, enter and true or false) end
	VKB.Fire("Close", box, enter and true or false)
end

function VKB.RefreshCovers()
	local on = UseVKeyboard()
	for cover in pairs(VKB.Covers) do
		if cover.Parent then cover.Visible = on end
	end
	if not on and VKB.Target then VKB.Close(false) end
end

-- The keyboard is held back (Ready = false) while a key prompt is on screen and until the
-- window has finished building, so nothing can type through it before the menu exists.
function VKB.SetReady(b)
	b = b ~= false
	if VKB.Ready == b then return end
	VKB.Ready = b
	VKB.RefreshCovers()
end

-- Routes a TextBox through the on-screen keyboard when it applies (phones by default).
-- onFocus()/onBlur(enterPressed) fire for both keyboards. Returns focus() for code that
-- wants to open the box programmatically. extra: {Native = true} always uses the device
-- keyboard; {Layout = "Numeric"} picks the layout the on-screen keyboard opens with.
function AttachKeyboard(box, themeSrc, onFocus, onBlur, extra)
	extra = extra or {}
	local native = extra.Native == true
	local opts = {theme = themeSrc, onFocus = onFocus, onBlur = onBlur, onEnter = extra.OnEnter, Layout = extra.Layout}
	if onFocus then box.Focused:Connect(onFocus) end
	if onBlur then box.FocusLost:Connect(function(enter) onBlur(enter) end) end
	local function Focus()
		if not box.TextEditable then return end
		if not native and UseVKeyboard() then
			if box:IsFocused() then box:ReleaseFocus() end
			VKB.Open(box, opts)
		else
			if VKB.Target == box then VKB.Close(false, true) end
			box:CaptureFocus()
		end
	end
	if not native then
		local cover = Create("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			ZIndex = box.ZIndex + 1,
			Visible = UseVKeyboard(),
			Parent = box,
		})
		VKB.Covers[cover] = true
		cover.Activated:Connect(Focus)
	end
	return Focus
end

-- Public keyboard API: Library.Keyboard (every method also works with ':').
local Keyboard = {}
Library.Keyboard = Keyboard

local function CopyCfg(src)
	local out = {}
	for k, v in pairs(src) do
		if type(v) == "table" then
			local t = {}
			for a, b in pairs(v) do t[a] = b end
			out[k] = t
		else
			out[k] = v
		end
	end
	return out
end
local function CfgCopy() return CopyCfg(VKB.Cfg) end
local function Refresh()
	if not VKB.Root then return end
	VKB.BuildKeys()
	VKB.Layout()
	VKB.Labels()
	VKB.Paint()
end

Method(Keyboard, "Configure", function(opts)
	if type(opts) ~= "table" then return CfgCopy() end
	for k, v in pairs(opts) do
		if k == "Colors" then
			if type(v) == "table" then
				for name, c in pairs(v) do VKB.Cfg.Colors[name] = c end
			end
		elseif k == "Mode" or k == "Enabled" then
			VKB.Cfg.Mode = NormMode(k == "Enabled" and v == true and "Auto" or v)
		elseif k == "Compact" then
			VKB.Cfg.Compact = v == true
			VKB.SetCompact(v == true)
		elseif k == "Layout" then
			VKB.Cfg.Layout = VKB_LAYOUTS[v] and v or "Default"
			if VKB.Target then VKB.UseLayout(VKB.Cfg.Layout, true) end
		elseif k == "Scale" then
			Library.KeyboardScale = nil
			VKB.Cfg.Scale = tonumber(v) or 1
		else
			VKB.Cfg[k] = v
		end
	end
	Refresh()
	VKB.RefreshCovers()
	return CfgCopy()
end)
Method(Keyboard, "Get", CfgCopy)
Method(Keyboard, "Reset", function()
	VKB.Cfg = CopyCfg(KB_DEFAULTS)
	VKB.SetCompact(false)
	Refresh()
	VKB.RefreshCovers()
end)
Method(Keyboard, "SetMode", function(mode) return Keyboard.Configure({Mode = mode}) end)
Method(Keyboard, "SetEnabled", function(b) return Keyboard.Configure({Mode = b == false and "Off" or "Auto"}) end)
Method(Keyboard, "IsEnabled", function() return NormMode(VKB.Cfg.Mode) ~= "Off" end)
Method(Keyboard, "IsActive", UseVKeyboard)
Method(Keyboard, "IsSupported", TouchDevice)
Method(Keyboard, "IsReady", function() return VKB.Ready == true end)
Method(Keyboard, "SetCompact", function(b) VKB.SetCompact(b == true) end)
Method(Keyboard, "IsCompact", function() return VKB.Compact == true end)
Method(Keyboard, "SetScale", function(n) return Keyboard.Configure({Scale = tonumber(n) or 1}) end)
Method(Keyboard, "SetDock", function(side) return Keyboard.Configure({Dock = side == "Top" and "Top" or "Bottom"}) end)
Method(Keyboard, "SetTools", function(list) return Keyboard.Configure({Tools = list}) end)
Method(Keyboard, "SetColors", function(colors) return Keyboard.Configure({Colors = colors}) end)
Method(Keyboard, "SetPosition", function(x, y)
	local p = typeof(x) == "Vector2" and x or Vector2.new(tonumber(x) or 0, tonumber(y) or 0)
	VKB.Cfg.CompactPosition = p
	VKB.Pos = p
	if VKB.Root and VKB.Compact then VKB.Place(p.X, p.Y) end
end)
Method(Keyboard, "GetSize", function() return VKB.Size end)

Method(Keyboard, "AddLayout", function(name, spec)
	local lay = NormLayout(spec)
	if type(name) ~= "string" or not lay then return false end
	VKB_LAYOUTS[name] = lay
	if VKB.LayoutName == name then Refresh() end
	return true
end)
Method(Keyboard, "RemoveLayout", function(name)
	if name == "Default" or not VKB_LAYOUTS[name] then return false end
	VKB_LAYOUTS[name] = nil
	if VKB.Cfg.Layout == name then VKB.Cfg.Layout = "Default" end
	if VKB.LayoutName == name then VKB.UseLayout("Default") end
	return true
end)
Method(Keyboard, "GetLayouts", function()
	local names = {}
	for name in pairs(VKB_LAYOUTS) do table.insert(names, name) end
	table.sort(names)
	return names
end)
Method(Keyboard, "SetLayout", function(name)
	if not VKB_LAYOUTS[name] then return false end
	VKB.Cfg.Layout = name
	if VKB.Target then VKB.UseLayout(name) end
	return true
end)
Method(Keyboard, "GetLayout", function() return VKB.LayoutName or VKB.Cfg.Layout or "Default" end)
Method(Keyboard, "Keys", VKeys)

Method(Keyboard, "AddAction", function(name, fn)
	if type(name) ~= "string" or type(fn) ~= "function" then return end
	VKB.Actions[name] = fn
end)
Method(Keyboard, "RemoveAction", function(name) VKB.Actions[name] = nil end)
Method(Keyboard, "OnOpen", function(fn) return VKB.Hook("Open", fn) end)
Method(Keyboard, "OnClose", function(fn) return VKB.Hook("Close", fn) end)
Method(Keyboard, "OnKey", function(fn) return VKB.Hook("Key", fn) end)
Method(Keyboard, "OnChange", function(fn) return VKB.Hook("Change", fn) end)
Method(Keyboard, "OnEnter", function(fn) return VKB.Hook("Enter", fn) end)
Method(Keyboard, "OnLayout", function(fn) return VKB.Hook("Layout", fn) end)

Method(Keyboard, "Open", function(box, opts)
	if not UseVKeyboard() then return false end
	return VKB.Open(box, type(opts) == "table" and opts or {}) == true
end)
Method(Keyboard, "Close", function() VKB.Close(false) end)
Method(Keyboard, "Submit", function() VKB.Close(true) end)
Method(Keyboard, "IsOpen", function() return VKB.Target ~= nil end)
Method(Keyboard, "GetTarget", function() return VKB.Target end)
Method(Keyboard, "GetText", function() return VKB.Target and VKB.Text or nil end)
Method(Keyboard, "SetText", function(text, cursor)
	if not VKB.Target then return end
	VKB.Record("set")
	text = OneLine(text or "")
	VKB.SetText(text, tonumber(cursor) or #text)
end)
Method(Keyboard, "Insert", function(str) VKB.Insert(OneLine(str), "insert") end)
Method(Keyboard, "Backspace", function(word) VKB.DeleteBack(word == true) end)
Method(Keyboard, "Clear", function()
	if VKB.Target and VKB.Text ~= "" then
		VKB.Record("clear")
		VKB.SetText("", 0)
	end
end)
Method(Keyboard, "Move", function(dir) VKB.Move(dir) end)
Method(Keyboard, "SelectAll", function()
	if not VKB.Target then return end
	VKB.SelectMode = true
	VKB.SetText(VKB.Text, #VKB.Text, 0)
	VKB.Labels()
end)
Method(Keyboard, "GetSelection", function()
	if not VKB.Target then return nil end
	local a, b = Selection()
	if not a then return nil end
	return VKB.Text:sub(a + 1, b), a, b
end)
Method(Keyboard, "Undo", function() if VKB.Target then Restore(VKB.Undo, VKB.Redo) end end)
Method(Keyboard, "Redo", function() if VKB.Target then Restore(VKB.Redo, VKB.Undo) end end)
Method(Keyboard, "SetShift", function(b) VKB.Shift = b == true; VKB.Labels() end)
Method(Keyboard, "SetCaps", function(b) VKB.Caps = b == true; VKB.Labels() end)
Method(Keyboard, "Rebuild", function()
	local box, opts = VKB.Target, VKB.Opts
	VKB.Destroy()
	if box and box.Parent then VKB.Open(box, opts) end
end)
Method(Keyboard, "Destroy", VKB.Destroy)

-- Legacy entry points.
Method(Library, "SetCustomKeyboard", function(mode)
	Library.CustomKeyboard = mode
	VKB.Cfg.Mode = NormMode(mode)
	VKB.RefreshCovers()
end)
Method(Library, "SetKeyboardCompact", function(b)
	Library.KeyboardCompact = b == true
	VKB.SetCompact(b == true)
end)
Method(Library, "CloseKeyboard", function() VKB.Close(false) end)
Method(Library, "ConfigureKeyboard", function(opts) return Keyboard.Configure(opts) end)
end -- on-screen keyboard

local function AddInput(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Input", o, 25)
	local numeric = o.Numeric == true
	local maxLen = tonumber(o.MaxLength)
	local live = o.Finished == false
	local value = ""

	local lbl = Label(row, o.Name or o.Title or "Input", {Size = UDim2.new(0.5, -4, 1, 0), Truncate = true})
	local box = Create("TextBox", {
		Size = UDim2.new(0.5, 0, 0, 25),
		Position = UDim2.new(0.5, 0, 0, 0),
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = tostring(o.Placeholder or ""),
		ClearTextOnFocus = o.ClearTextOnFocus == true,
		ClipsDescendants = true,
		TextSize = TEXT,
		Weight = "Medium",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
		Parent = row,
	})
	Corner(box, 5)
	local bs = Stroke(box, WHITE, 1)
	Create("UIPadding", {PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7), Parent = box})

	local function Sanitize(text)
		text = tostring(text or "")
		if maxLen and #text > maxLen then text = text:sub(1, maxLen) end
		if numeric then
			local n = tonumber(text)
			if not n then return text == "" and "" or value end
			if o.Min then n = math.max(n, o.Min) end
			if o.Max then n = math.min(n, o.Max) end
			return FormatNumber(n, o.Decimals or Decimals(n))
		end
		return text
	end
	local function Out()
		if numeric then return tonumber(value) end
		return value
	end

	local updating = false
	local function Commit(text, silent, keepText)
		text = Sanitize(text)
		if not keepText then
			updating = true
			box.Text = text
			updating = false
		end
		local changed = text ~= value
		value = text
		el.Value = Out()
		if changed and not silent then
			el._fire(el.Value)
		else
			el._sync(el.Value)
		end
	end

	local focused, inHover = false, false
	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		Anim(lbl, {TextColor3 = enabled and T.TextGray or T.TextDim}, animate)
		Anim(box, {
			BackgroundColor3 = (inHover and enabled and not focused) and T.TileHover or T.DropdownBg,
			TextColor3 = enabled and T.Text or T.ValueOff,
		}, animate)
		box.PlaceholderColor3 = T.TextDim
		box.TextEditable = enabled
		Anim(bs, {
			Color = (focused and enabled) and W.Accent or (enabled and T.DropdownBorder or T.DropdownBorderOff),
			Transparency = (focused and enabled) and (1 - W.AccentAlpha) or 0,
		}, animate)
		if not enabled and box:IsFocused() then box:ReleaseFocus() end
	end
	W.Bind(function() el._apply() end, row)
	OnMouseEnter(box, function() inHover = true el._apply(true) end)
	box.MouseLeave:Connect(function() inHover = false el._apply(true) end)

	-- Keyboard = false keeps the device keyboard; KeyboardLayout picks the on-screen layout
	-- (numeric inputs default to the number pad).
	local focusBox = AttachKeyboard(box, W, function()
		focused = true
		el._apply(true)
	end, function()
		focused = false
		el._apply(true)
		Commit(box.Text)
	end, {Native = o.Keyboard == false, Layout = o.KeyboardLayout or (numeric and "Numeric" or nil)})
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if updating then return end
		if maxLen and #box.Text > maxLen then
			updating = true
			box.Text = box.Text:sub(1, maxLen)
			updating = false
		end
		if live and el.Enabled then Commit(box.Text, false, true) end
	end)

	Method(el, "Set", function(v, silent) Commit(v, silent) end)
	Method(el, "Get", Out)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	Method(el, "SetPlaceholder", function(t) box.PlaceholderText = tostring(t or "") end)
	Method(el, "Focus", function() if el.Enabled then focusBox() end end)
	Method(el, "Clear", function(silent) Commit("", silent) end)

	Commit(o.Default or o.Value or "", true)
	return Finish(el, o)
end

local ParseKey, KeyMatches, SoftPress, BuildKeybindList, AddKeybind
do -- keybinds
local KEY_SHORT = {
	LeftShift = "LShift", RightShift = "RShift", LeftControl = "LCtrl", RightControl = "RCtrl",
	LeftAlt = "LAlt", RightAlt = "RAlt", MouseButton1 = "MB1", MouseButton2 = "MB2", MouseButton3 = "MB3",
	Return = "Enter", CapsLock = "Caps", PageUp = "PgUp", PageDown = "PgDn", Escape = "Esc",
	Backspace = "Bksp", Delete = "Del", Insert = "Ins", Space = "Space",
	Zero = "0", One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
	KeypadZero = "Num0", KeypadOne = "Num1", KeypadTwo = "Num2", KeypadThree = "Num3", KeypadFour = "Num4",
	KeypadFive = "Num5", KeypadSix = "Num6", KeypadSeven = "Num7", KeypadEight = "Num8", KeypadNine = "Num9",
	Backquote = "`", Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]", BackSlash = "\\",
	Semicolon = ";", Quote = "'", Comma = ",", Period = ".", Slash = "/",
}
local MOD_ORDER = {"Ctrl", "Shift", "Alt"}
local MOD_GROUP = {
	LeftControl = "Ctrl", RightControl = "Ctrl", LeftShift = "Shift", RightShift = "Shift", LeftAlt = "Alt", RightAlt = "Alt",
}
local MOD_KEYS = {
	Ctrl = {Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl},
	Shift = {Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift},
	Alt = {Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt},
}

function ParseKey(k)
	if typeof(k) == "EnumItem" then
		-- Value 0 is the "no key" item (KeyCode.None; older engines called it Unknown).
		if k.EnumType == Enum.KeyCode and k.Value ~= 0 then return k end
		if k == Enum.UserInputType.MouseButton1 or k == Enum.UserInputType.MouseButton2 or k == Enum.UserInputType.MouseButton3 then return k end
		return nil
	end
	if type(k) == "string" and k ~= "" and k ~= "None" then
		local ok, v = pcall(function() return Enum.KeyCode[k] end)
		if ok and v then return ParseKey(v) end
		ok, v = pcall(function() return Enum.UserInputType[k] end)
		if ok and v then return ParseKey(v) end
	end
	return nil
end
function KeyMatches(key, input)
	if not key then return false end
	if key.EnumType == Enum.KeyCode then return input.KeyCode == key end
	return input.UserInputType == key
end

local function ModDown(group)
	for _, kc in ipairs(MOD_KEYS[group]) do
		local ok, v = pcall(function() return UserInputService:IsKeyDown(kc) end)
		if ok and v then return true end
	end
	return false
end
local function HeldMods(except)
	local m = {}
	for _, g in ipairs(MOD_ORDER) do
		if g ~= except and ModDown(g) then m[g] = true end
	end
	return m
end
local function HasMods(m) return m ~= nil and next(m) ~= nil end
-- Exact modifier match, ignoring the group the key itself belongs to (e.g. a bare LShift bind).
local function ModsMatch(key, mods)
	local own = key and MOD_GROUP[key.Name]
	for _, g in ipairs(MOD_ORDER) do
		if g ~= own and (mods[g] == true) ~= ModDown(g) then return false end
	end
	return true
end
local function JoinBind(key, mods, short)
	if not key then return nil end
	local parts = {}
	for _, g in ipairs(MOD_ORDER) do
		if mods and mods[g] then table.insert(parts, g) end
	end
	table.insert(parts, short and (KEY_SHORT[key.Name] or key.Name) or key.Name)
	return table.concat(parts, "+")
end
-- Accepts KeyCode/UserInputType, "F", "Ctrl+Shift+F", or {Key = ..., Mods = {"Ctrl"}}.
local function ParseBind(v)
	if typeof(v) == "table" then
		local key, mods = ParseBind(v.Key or v[1])
		local list = v.Mods or v.Modifiers
		if type(list) == "table" then
			for k, x in pairs(list) do
				local g = type(k) == "number" and x or (x and k)
				if MOD_KEYS[g] then mods[g] = true end
			end
		end
		return key, key and mods or {}
	end
	if type(v) == "string" and #v > 1 and v:find("+", 1, true) then
		local mods, key = {}, nil
		for part in v:gmatch("[^+]+") do
			local p = part:gsub("^%s+", ""):gsub("%s+$", "")
			local g = (p == "Ctrl" or p == "Control") and "Ctrl" or ((p == "Shift" or p == "Alt") and p or nil)
			if g then mods[g] = true else key = ParseKey(p) end
		end
		return key, key and mods or {}
	end
	return ParseKey(v), {}
end

local function TouchOnly()
	return UserInputService.TouchEnabled == true and UserInputService.KeyboardEnabled ~= true
end

-- Press/release on a GUI object for mouse and touch. Release is tracked globally so a
-- finger sliding off the object still ends a hold.
local function BindPress(W, obj, onDown, onUp, maid)
	local held
	obj.InputBegan:Connect(function(input)
		if held or not IsClickOrTouch(input) then return end
		held = input
		SafeCall(onDown)
	end)
	return W.Connect(UserInputService.InputEnded, function(input)
		if not held then return end
		local same
		if held.UserInputType == Enum.UserInputType.Touch then
			same = input == held
		else
			same = input.UserInputType == held.UserInputType
		end
		if same then
			held = nil
			SafeCall(onUp)
		end
	end, maid)
end

-- Click feedback for icon buttons: a short dip in opacity that eases back. No scaling or overshoot.
local SOFT_TI = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
function SoftPress(img)
	StopTweens(img)
	img.ImageTransparency = 0.45
	Tween(img, SOFT_TI, {ImageTransparency = 0})
end
local MODE_TEXT = {Toggle = "toggle", Hold = "hold", Press = "press"}
local ROW_TI = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
-- Same feel as the main window open/close.
local LIST_TI_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local LIST_TI_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.In)

function BuildKeybindList(W, cfg)
	if cfg == false then cfg = {Visible = false} end
	if type(cfg) ~= "table" then cfg = {} end
	local touch = cfg.TouchMode
	if touch == nil then touch = TouchOnly() end
	local ROW_H = touch and 30 or 22
	local LIST_W = touch and 214 or 190

	local L = {Entries = {}, Wanted = cfg.Visible ~= false and cfg.Enabled ~= false, ShowInactive = cfg.ShowInactive ~= false, Collapsed = false}
	W.KBList = L

	local root = Create("Frame", {
		Name = "KeybindList",
		Size = UDim2.fromOffset(LIST_W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = cfg.Position or UDim2.fromOffset(8, 42),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = W.Gui,
	})
	local scaler = Create("UIScale", {Parent = root})
	local panel = Create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Active = true,
		Parent = root,
	})
	Corner(panel, 6)
	local stroke = Stroke(panel, WHITE, 1, 0.15)
	Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = panel})
	Create("UIPadding", {PaddingBottom = UDim.new(0, 4), Parent = panel})

	local header = Create("Frame", {Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, Active = true, LayoutOrder = 0, Parent = panel})
	local hIcon = CreateIcon(header, {"keyboard", "command"}, 12, UDim2.new(0, 10, 0.5, -6))
	local title = Label(header, cfg.Title or "Keybinds", {Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -86, 1, 0), Weight = "SemiBold", Truncate = true})
	local badge = Create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -31, 0.5, 0),
		Size = UDim2.fromOffset(0, 14),
		AutomaticSize = Enum.AutomaticSize.X,
		BorderSizePixel = 0,
		Parent = header,
	})
	Corner(badge, 7)
	Create("UIPadding", {PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5), Parent = badge})
	local count = Label(badge, "", {AutoX = true, Size = UDim2.new(0, 0, 1, 0), TextSize = 10, Weight = "SemiBold"})
	local collapse = Create("TextButton", {
		Size = UDim2.fromOffset(24, 24),
		Position = UDim2.new(1, -27, 0.5, -12),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = header,
	})
	local chev = CreateIcon(collapse, {"chevron-up"}, 12, UDim2.new(0.5, -6, 0.5, -6))
	local line = Create("Frame", {Size = UDim2.new(1, -16, 0, 1), Position = UDim2.new(0, 8, 1, -1), BorderSizePixel = 0, Parent = header})
	MakeDraggable(W, header, root)

	local body = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 1, Parent = panel})
	Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = body})
	Create("UIPadding", {PaddingTop = UDim.new(0, 3), Parent = body})
	local emptyRow = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1, ClipsDescendants = true, Visible = false, LayoutOrder = 1e6, Parent = body})
	local empty = Label(emptyRow, touch and "No keybinds" or "No active keybinds", {Size = UDim2.new(1, 0, 0, ROW_H), TextSize = 10, Align = Enum.TextXAlignment.Center})

	-- Rows grow/shrink in height; the panel auto-sizes, so the whole list resizes smoothly.
	local function ShowRow(r, show, animate, h)
		L.RowTok = L.RowTok or setmetatable({}, {__mode = "k"})
		local tok = (L.RowTok[r] or 0) + 1
		L.RowTok[r] = tok
		local target = UDim2.new(1, 0, 0, show and h or 0)
		if not animate then
			SetProps(r, {Size = target})
			r.Visible = show
			return
		end
		if show then r.Visible = true end
		local t = Tween(r, ROW_TI, {Size = target})
		if not show then
			t.Completed:Connect(function()
				if L.RowTok[r] == tok and r.Parent then r.Visible = false end
			end)
		end
	end

	local function PaintEntry(e, animate)
		local T = W.Theme
		local on = (e.isActive() or e.pulse == true) and true or false
		local alpha = W.AccentAlpha
		Anim(e.bar, {
			Size = UDim2.fromOffset(2, on and (ROW_H - 10) or 0),
			BackgroundColor3 = W.Accent,
			BackgroundTransparency = on and (1 - alpha) or 1,
		}, animate, ROW_TI)
		Anim(e.name, {
			TextColor3 = not e.enabled() and T.TextDim or (on and T.Text or T.TextGray),
			Position = UDim2.fromOffset(on and 14 or 10, 0),
		}, animate, ROW_TI)
		e.mode.TextColor3 = T.TextDim
		Anim(e.pill, {BackgroundColor3 = on and T.DropdownBg:Lerp(W.Accent, 0.18 * alpha) or T.DropdownBg}, animate)
		Anim(e.pillStroke, {Color = on and W.Accent or T.DropdownBorder, Transparency = on and (1 - alpha) or 0}, animate)
		Anim(e.key, {TextColor3 = on and W.Accent or T.TextGray}, animate)
		e.btn.BackgroundColor3 = e.pressed and T.TileHover or T.PopupHover
	end

	local shown = false
	local fadeTok = 0
	local function SetShown(v, animate)
		if v == shown then return end
		shown = v
		fadeTok = fadeTok + 1
		local tok = fadeTok
		if not animate then
			StopTweens(scaler)
			scaler.Scale = 1
			root.Visible = v
			return
		end
		root.Visible = true
		if v then scaler.Scale = 0.94 end
		Tween(scaler, v and LIST_TI_IN or LIST_TI_OUT, {Scale = v and 1 or 0.94})
		local sz = panel.AbsoluteSize
		FadeContent(panel, root, UDim2.fromOffset(sz.X, sz.Y), v, v and LIST_TI_IN or LIST_TI_OUT, 1, function()
			if fadeTok == tok and not v then root.Visible = false end
		end)
	end

	function L.Refresh(instant)
		if not W.Alive then return end
		local animate = not instant and shown
		local visibleCount = 0
		for i, e in ipairs(L.Entries) do
			local visible = e.listed() and (L.ShowInactive or e.isActive() or e.pulse == true) and true or false
			e.btn.LayoutOrder = i
			ShowRow(e.btn, visible and not L.Collapsed, animate and e.drawn, ROW_H)
			e.drawn = true
			if visible then
				visibleCount = visibleCount + 1
				e.name.Text = e.getName()
				e.mode.Text = e.getMode()
				e.key.Text = e.getKey()
			end
			PaintEntry(e, animate)
		end
		ShowRow(emptyRow, visibleCount == 0 and not L.Collapsed, animate, ROW_H)
		count.Text = tostring(visibleCount)
		badge.Visible = visibleCount > 0
		Anim(chev, {Rotation = L.Collapsed and 180 or 0}, animate, ROW_TI)
		local any = false
		for _, e in ipairs(L.Entries) do
			if e.listed() then any = true break end
		end
		SetShown(L.Wanted and any and not W.KeyLocked, not instant)
	end

	W.Bind(function(T, accent, alpha)
		panel.BackgroundColor3 = T.WmBg
		stroke.Color = T.WmStroke
		hIcon.ImageColor3 = accent
		title.TextColor3 = T.Text
		badge.BackgroundColor3 = T.DropdownBg:Lerp(accent, 0.25 * alpha)
		count.TextColor3 = T.Text
		chev.ImageColor3 = T.NavGray
		line.BackgroundColor3 = T.WmDivider
		empty.TextColor3 = T.TextDim
		for _, e in ipairs(L.Entries) do PaintEntry(e, false) end
	end, root)

	OnMouseEnter(collapse, function() Anim(chev, {ImageColor3 = W.Theme.Text}, true) end)
	collapse.MouseLeave:Connect(function() Anim(chev, {ImageColor3 = W.Theme.NavGray}, true) end)
	collapse.MouseButton1Click:Connect(function()
		L.Collapsed = not L.Collapsed
		L.Refresh()
	end)

	-- e: getName, getKey, getMode, isActive, enabled, listed, trigger(down)
	function L.Add(e)
		local btn = Create("TextButton", {
			Size = UDim2.new(1, 0, 0, 0),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Text = "",
			AutoButtonColor = false,
			Visible = false,
			Parent = body,
		})
		e.btn = btn
		e.bar = Create("Frame", {AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(2, 0), Position = UDim2.new(0, 6, 0.5, 0), BorderSizePixel = 0, Parent = btn})
		Corner(e.bar, 1)
		e.name = Label(btn, "", {Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -100, 0, ROW_H), Truncate = true})
		local right = Create("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, (ROW_H - 18) / 2),
			Size = UDim2.new(0, 0, 0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Parent = btn,
		})
		Create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 5),
			Parent = right,
		})
		e.mode = Label(right, "", {AutoX = true, Size = UDim2.new(0, 0, 1, 0), TextSize = 10})
		e.mode.LayoutOrder = 1
		e.pill = Create("Frame", {Size = UDim2.new(0, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.X, BorderSizePixel = 0, LayoutOrder = 2, Parent = right})
		Corner(e.pill, 3)
		e.pillStroke = Stroke(e.pill, WHITE, 1)
		Create("UIPadding", {PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = e.pill})
		e.key = Label(e.pill, "", {AutoX = true, Size = UDim2.new(0, 0, 1, 0), TextSize = 10, Weight = "SemiBold"})
		e.conn = BindPress(W, btn, function()
			e.pressed = true
			Anim(btn, {BackgroundTransparency = 0.25}, true)
			e.trigger(true)
		end, function()
			e.pressed = false
			Anim(btn, {BackgroundTransparency = e.hover and 0.5 or 1}, true)
			e.trigger(false)
		end)
		OnMouseEnter(btn, function()
			e.hover = true
			btn.BackgroundColor3 = W.Theme.PopupHover
			Anim(btn, {BackgroundTransparency = 0.5}, true)
		end)
		btn.MouseLeave:Connect(function()
			e.hover = false
			Anim(btn, {BackgroundTransparency = 1}, true)
		end)
		table.insert(L.Entries, e)
		L.Refresh()
		return e
	end
	function L.Remove(e)
		local i = IndexOf(L.Entries, e)
		if i then table.remove(L.Entries, i) end
		if e.conn then W.Maid:Remove(e.conn) end
		if e.btn then
			local b = e.btn
			if shown and b.Visible then
				local t = Tween(b, ROW_TI, {Size = UDim2.new(1, 0, 0, 0)})
				t.Completed:Connect(function() b:Destroy() end)
			else
				b:Destroy()
			end
		end
		L.Refresh()
	end
	function L.Pulse(e)
		e.pulse = true
		L.Refresh()
		task.delay(0.3, function()
			e.pulse = nil
			if W.Alive then L.Refresh() end
		end)
	end

	local api = {}
	-- The settings page mirrors these two; keep its toggles in step without re-firing them.
	Method(api, "SetVisible", function(b)
		L.Wanted = b ~= false
		L.Refresh()
		if W.KbListToggle and W.KbListToggle.Get() ~= L.Wanted then W.KbListToggle.Set(L.Wanted, true) end
	end)
	Method(api, "IsVisible", function() return L.Wanted end)
	Method(api, "Toggle", function() api.SetVisible(not L.Wanted) end)
	Method(api, "SetShowInactive", function(b)
		L.ShowInactive = b ~= false
		L.Refresh()
		if W.KbInactiveToggle and W.KbInactiveToggle.Get() ~= L.ShowInactive then W.KbInactiveToggle.Set(L.ShowInactive, true) end
	end)
	Method(api, "SetCollapsed", function(b) L.Collapsed = b == true L.Refresh() end)
	Method(api, "IsCollapsed", function() return L.Collapsed end)
	Method(api, "SetTitle", function(t) title.Text = tostring(t) end)
	Method(api, "SetPosition", function(p) root.Position = p end)
	Method(api, "Refresh", function() L.Refresh() end)
	L.Frame = root
	return api
end

function AddKeybind(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Keybind", o, 25)
	W.Keybinds = W.Keybinds or {}
	table.insert(W.Keybinds, el)

	local key, mods = ParseBind(o.Default or o.Value or o.Key)
	if o.Modifiers or o.Mods then
		local _, m = ParseBind({Key = "A", Mods = o.Modifiers or o.Mods})
		mods = key and m or {}
	end
	local mode = tostring(o.Mode or "Toggle")
	if mode ~= "Hold" and mode ~= "Press" then mode = "Toggle" end
	-- Toggle and Hold both report on/off, so users may switch between them; Press stays Press.
	local modes = type(o.Modes) == "table" and CopyList(o.Modes) or (mode == "Press" and {"Press"} or {"Toggle", "Hold"})
	local function ModeAllowed(m) return IndexOf(modes, m) ~= nil end
	if not ModeAllowed(mode) then table.insert(modes, 1, mode) end
	local showModeChip = o.ShowMode ~= false and #modes > 1
	local active = o.DefaultState == true
	local picking, pendingMod, hover, pressedBtn = false, nil, false, false
	local cancelClock = -1
	local blacklist = {}
	for _, b in ipairs(type(o.Blacklist) == "table" and o.Blacklist or {}) do
		local k = ParseKey(b)
		if k then blacklist[k.Name] = true end
	end
	el.Value = key

	local touchTrigger = o.TouchTrigger
	if touchTrigger == nil then touchTrigger = TouchOnly() end

	local dot = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(0, 0),
		BorderSizePixel = 0,
		Parent = row,
	})
	Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = dot})
	local lbl = Label(row, o.Name or o.Title or "Keybind", {Size = UDim2.new(1, -96, 1, 0), Truncate = true})

	local btnBase = UDim2.new(1, 0, 0.5, 0)
	local btn = Create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = btnBase,
		Size = UDim2.fromOffset(44, 21),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Text = "",
		TextSize = TEXT,
		Weight = "SemiBold",
		AutoButtonColor = false,
		ZIndex = 2,
		Parent = row,
	})
	Corner(btn, 4)
	local bs = Stroke(btn, WHITE, 1)
	local timer = Create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(0, 0, 0, 2),
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = btn,
	})

	local chip, chipLbl, chipStroke
	if showModeChip then
		chip = Create("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -50, 0.5, 0),
			Size = UDim2.fromOffset(40, 17),
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 2,
			Parent = row,
		})
		Corner(chip, 9)
		chipStroke = Stroke(chip, WHITE, 1)
		chipLbl = Label(chip, "", {Size = UDim2.fromScale(1, 1), TextSize = 10, Align = Enum.TextXAlignment.Center})
		chipLbl.ZIndex = 3
	end

	local dotsStep = 0
	local function BindDisplay()
		if picking then
			local held = HeldMods()
			local prefix = JoinBind(Enum.KeyCode.A, held, true):sub(1, -2)
			return prefix .. string.rep(".", dotsStep % 3 + 1)
		end
		if key then return JoinBind(key, mods, true) end
		return touchTrigger and "Tap" or "None"
	end

	local function Layout(animate)
		local text = BindDisplay()
		btn.Text = text
		local bw = math.clamp(math.floor(TextWidth(text, TEXT) + 20), 38, 110)
		Anim(btn, {Size = UDim2.fromOffset(bw, 21)}, animate, MOVE_TI)
		local right = bw + 6
		if chip then
			chipLbl.Text = MODE_TEXT[mode]
			local cw = math.floor(TextWidth(chipLbl.Text, 10) + 14)
			Anim(chip, {Size = UDim2.fromOffset(cw, 17), Position = UDim2.new(1, -right, 0.5, 0)}, animate, MOVE_TI)
			right = right + cw + 6
		end
		Anim(lbl, {Size = UDim2.new(1, -(right + (active and 11 or 0)), 1, 0)}, animate, MOVE_TI)
	end

	local function Paint(animate)
		local T, enabled = W.Theme, el.Enabled
		local alpha = W.AccentAlpha * (enabled and 1 or 0.45)
		local hot = active and enabled
		Anim(dot, {
			Size = hot and UDim2.fromOffset(6, 6) or UDim2.fromOffset(0, 0),
			BackgroundColor3 = W.Accent,
			BackgroundTransparency = 1 - alpha,
		}, animate, MOVE_TI)
		Anim(lbl, {
			Position = UDim2.fromOffset(hot and 11 or 0, 0),
			TextColor3 = not enabled and T.TextDim or ((hot or hover) and T.Text or T.TextGray),
		}, animate, MOVE_TI)
		local bg = T.DropdownBg
		if pressedBtn and enabled then
			bg = T.TileHover:Lerp(T.Text, 0.06)
		elseif hot then
			bg = T.DropdownBg:Lerp(W.Accent, 0.16 * alpha)
		elseif hover and enabled then
			bg = T.TileHover
		end
		Anim(btn, {
			BackgroundColor3 = bg,
			TextColor3 = not enabled and T.TextDim or ((picking or hot) and W.Accent or (hover and T.Text or T.TextGray)),
		}, animate)
		if not picking then
			Anim(bs, {
				Color = hot and W.Accent or (enabled and T.DropdownBorder or T.DropdownBorderOff),
				Transparency = hot and (1 - alpha * 0.6) or 0,
			}, animate)
		end
		timer.BackgroundColor3 = W.Accent
		timer.BackgroundTransparency = 1 - alpha
		if chip then
			chip.BackgroundColor3 = T.DropdownBg
			Anim(chipStroke, {Color = enabled and T.DropdownBorder or T.DropdownBorderOff}, animate)
			Anim(chipLbl, {TextColor3 = enabled and T.TextGray or T.TextDim}, animate)
		end
	end
	el._apply = Paint
	W.Bind(function() Paint(false) Layout(false) end, row)

	local entry
	local function ListRefresh() if entry and W.KBList then W.KBList.Refresh() end end

	local pickTok = 0
	local function StopPicking()
		if not picking then return end
		picking = false
		pendingMod = nil
		pickTok = pickTok + 1
		if W.Capturing == el then W.Capturing = nil end
		StopTweens(bs, timer)
		timer.Size = UDim2.new(0, 0, 0, 2)
		Layout(true)
		Paint(true)
	end
	local function Reject(msg)
		SetProps(bs, {Color = rgb(235, 87, 87), Transparency = 0})
		task.delay(0.35, function()
			if picking then
				bs.Color = W.Accent
			else
				Paint(true)
			end
		end)
		SafeCall(o.OnReject, msg)
		if msg and W.Window then W.Window.Notify({Title = "Keybind", Content = msg, Icon = {"keyboard", "command"}, Duration = 2.5}) end
	end
	local function SetActive(b)
		b = b and true or false
		if b == active then return end
		active = b
		Paint(true)
		Layout(true)
		ListRefresh()
		SafeCall(o.Callback, active)
		SafeCall(o.ToggleCallback, active)
	end
	local function FindDuplicate(k, m)
		local text = JoinBind(k, m)
		if not text then return nil end
		for _, other in ipairs(W.Keybinds) do
			if other ~= el and other._bindText and other._bindText() == text then return other end
		end
		return nil
	end
	local function SetBind(k, m, silent)
		m = k and (m or {}) or {}
		local before = JoinBind(key, mods)
		if before ~= JoinBind(k, m) and mode == "Hold" then SetActive(false) end
		key, mods = k, m
		el.Value = k
		StopPicking()
		Layout(true)
		Paint(true)
		el._sync(k)
		ListRefresh()
		if JoinBind(key, mods) ~= before then
			if not silent then SafeCall(o.ChangedCallback, k, mods) end
		end
	end
	local function Commit(k, m)
		if k and blacklist[k.Name] then
			Reject((KEY_SHORT[k.Name] or k.Name) .. " can't be used")
			return
		end
		if k and o.NoDuplicates then
			local dup = FindDuplicate(k, m)
			if dup then
				Reject(JoinBind(k, m, true) .. " is already used by " .. tostring(dup._name and dup._name() or "another keybind"))
				return
			end
		end
		SetBind(k, m)
	end

	-- Same behaviour as pressing the bound key; used by touch taps and the keybind list.
	local function Trigger(down)
		if W.KeyLocked or not el.Enabled or not row.Parent then
			if not down and mode == "Hold" then SetActive(false) end
			return
		end
		if mode == "Toggle" then
			if down then SetActive(not active) end
		elseif mode == "Hold" then
			SetActive(down)
		elseif down then
			if entry and W.KBList then W.KBList.Pulse(entry) end
			SafeCall(o.Callback, true)
		end
	end
	el._trigger = Trigger

	local function StartPicking()
		if picking or not el.Enabled or W.Capturing or W.KeyLocked then return end
		picking = true
		pendingMod = nil
		W.Capturing = el
		pickTok = pickTok + 1
		local tok = pickTok
		dotsStep = 0
		Layout(true)
		Paint(true)
		SetProps(bs, {Color = W.Accent, Transparency = 0})
		local timeout = math.max(tonumber(o.PickTimeout) or 6, 1)
		timer.Size = UDim2.new(1, 0, 0, 2)
		Tween(timer, TweenInfo.new(timeout, Enum.EasingStyle.Linear), {Size = UDim2.new(0, 0, 0, 2)})
		el.Maid:Spawn(function()
			local started = os.clock()
			while picking and pickTok == tok and row.Parent do
				task.wait(0.3)
				if not (picking and pickTok == tok) then return end
				dotsStep = dotsStep + 1
				Layout(false)
				if os.clock() - started >= timeout then
					StopPicking()
					return
				end
			end
		end)
	end

	local function SetMode(m, animate)
		if m ~= "Hold" and m ~= "Press" and m ~= "Toggle" then return end
		if m == mode then return end
		if active then SetActive(false) end
		mode = m
		Layout(animate ~= false)
		Paint(animate ~= false)
		ListRefresh()
		SafeCall(o.ModeCallback, m)
	end

	-- Context menu (right-click): modes, change, clear, reset.
	local defaultKey, defaultMods, defaultMode, defaultActive = key, mods, mode, active
	local function OpenMenu()
		if not el.Enabled or picking or not W.PreparePopup(el, btn) then return end
		local T = W.Theme
		local items = {}
		if #modes > 1 then
			for _, m in ipairs(modes) do
				table.insert(items, {text = m, icon = (m == mode) and {"check"} or nil, accent = m == mode, fn = function() SetMode(m) end})
			end
			table.insert(items, {sep = true})
		end
		if not touchTrigger then table.insert(items, {text = "Change key", icon = {"keyboard", "command"}, fn = StartPicking}) end
		table.insert(items, {text = "Clear key", icon = {"x"}, fn = function() SetBind(nil, nil) end})
		table.insert(items, {text = "Reset", icon = {"rotate-ccw", "refresh-cw"}, fn = function()
			SetMode(defaultMode)
			SetBind(defaultKey, defaultMods)
		end})
		local IH, MW = 22, 124
		local h = 8
		for _, it in ipairs(items) do h = h + (it.sep and 7 or IH) end
		local sc = W.Scale.Scale
		local rel = (btn.AbsolutePosition - W.Main.AbsolutePosition) / sc
		local bw = btn.AbsoluteSize.X / sc
		local x = math.clamp(rel.X + bw - MW, 6, WIN_W - MW - 6)
		local y = rel.Y + btn.AbsoluteSize.Y / sc + 4
		if y + h > WIN_H - 6 then y = rel.Y - h - 4 end
		local menu = Create("Frame", {
			Size = UDim2.fromOffset(MW, 0),
			Position = UDim2.fromOffset(x, math.max(6, y)),
			BackgroundColor3 = T.PopupBg,
			ClipsDescendants = true,
			Active = true,
		})
		Corner(menu, 5)
		local ms = Stroke(menu, T.DropdownBorder, 1)
		Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = menu})
		Create("UIPadding", {PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4), Parent = menu})
		for i, it in ipairs(items) do
			if it.sep then
				local s = Create("Frame", {Size = UDim2.new(1, 0, 0, 7), BackgroundTransparency = 1, LayoutOrder = i, Parent = menu})
				local ln = Create("Frame", {Size = UDim2.new(1, -8, 0, 1), Position = UDim2.new(0, 4, 0.5, 0), BorderSizePixel = 0, Parent = s})
				W.Paint(ln, "BackgroundColor3", "Divider")
			else
				local b = Create("TextButton", {
					Size = UDim2.new(1, 0, 0, IH),
					BackgroundTransparency = 1,
					BackgroundColor3 = T.PopupHover,
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = i,
					Parent = menu,
				})
				Corner(b, 3)
				if it.icon then CreateIcon(b, it.icon, 11, UDim2.new(0, 6, 0.5, -5.5), it.accent and W.Accent or T.TextGray) end
				local tl = Label(b, it.text, {Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -26, 1, 0), Color = it.accent and T.Text or T.TextGray})
				OnMouseEnter(b, function()
					Anim(b, {BackgroundTransparency = 0}, true)
					Anim(tl, {TextColor3 = W.Theme.Text}, true)
				end)
				b.MouseLeave:Connect(function()
					Anim(b, {BackgroundTransparency = 1}, true)
					Anim(tl, {TextColor3 = it.accent and W.Theme.Text or W.Theme.TextGray}, true)
				end)
				b.MouseButton1Click:Connect(function()
					W.ClosePopupOf(el)
					SafeCall(it.fn)
				end)
			end
		end
		W.Bind(function(th)
			menu.BackgroundColor3 = th.PopupBg
			ms.Color = th.DropdownBorder
		end, menu)
		W.PushPopup(menu, el)
		Tween(menu, TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Size = UDim2.fromOffset(MW, h)})
	end

	OnMouseEnter(btn, function() hover = true Paint(true) end)
	btn.MouseLeave:Connect(function() hover = false pressedBtn = false Paint(true) end)
	if touchTrigger then
		-- Phones have no keys to bind, so tapping the key button runs the bind instead.
		BindPress(W, btn, function()
			pressedBtn = true
			Paint(true)
			Trigger(true)
		end, function()
			pressedBtn = false
			Paint(true)
			Trigger(false)
		end, el.Maid)
	else
		btn.InputBegan:Connect(function(input)
			if IsClickOrTouch(input) and el.Enabled and not picking then
				pressedBtn = true
				Paint(true)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 and not picking then
				OpenMenu()
			end
		end)
		btn.InputEnded:Connect(function(input)
			if IsClickOrTouch(input) and pressedBtn then
				pressedBtn = false
				Paint(true)
			end
		end)
		btn.MouseButton1Click:Connect(function()
			-- The click that cancelled picking must not immediately restart it.
			if os.clock() - cancelClock < 0.3 then return end
			StartPicking()
		end)
	end
	if chip then
		OnMouseEnter(chip, function() Anim(chipLbl, {TextColor3 = W.Theme.Text}, true) end)
		chip.MouseLeave:Connect(function() Anim(chipLbl, {TextColor3 = el.Enabled and W.Theme.TextGray or W.Theme.TextDim}, true) end)
		chip.MouseButton1Click:Connect(function()
			if not el.Enabled then return end
			local i = IndexOf(modes, mode) or 0
			SetMode(modes[i % #modes + 1])
		end)
	end

	W.Connect(UserInputService.InputBegan, function(input, gp)
		if not row.Parent then return end
		if picking then
			local t = input.UserInputType
			if t == Enum.UserInputType.Keyboard then
				W.LastCaptured = input
				local kc = input.KeyCode
				if kc == Enum.KeyCode.Escape then
					cancelClock = os.clock()
					StopPicking()
				elseif kc == Enum.KeyCode.Backspace or kc == Enum.KeyCode.Delete then
					SetBind(nil, nil)
				elseif kc.Value == 0 then
					return
				elseif MOD_GROUP[kc.Name] then
					pendingMod = kc
					Layout(false)
				else
					Commit(kc, HeldMods())
				end
			elseif t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseButton3 then
				W.LastCaptured = input
				Commit(t, HeldMods())
			elseif t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
				cancelClock = os.clock()
				StopPicking()
			end
			return
		end
		if W.KeyLocked or gp or not el.Enabled or not KeyMatches(key, input) then return end
		if W.Capturing or W.LastCaptured == input then return end
		if HasMods(mods) then
			if not ModsMatch(key, mods) then return end
		else
			-- A Ctrl/Shift/Alt bind on the same key takes priority over the plain one.
			for _, other in ipairs(W.Keybinds) do
				if other ~= el and other._specific and other._specific(input) then return end
			end
		end
		Trigger(true)
	end, el.Maid)
	W.Connect(UserInputService.InputEnded, function(input)
		if not row.Parent then return end
		if picking then
			-- Releasing a lone modifier binds the modifier itself.
			if pendingMod and input.KeyCode == pendingMod then
				local m = pendingMod
				Commit(m, HeldMods(MOD_GROUP[m.Name]))
			end
			return
		end
		if mode ~= "Hold" or not active then return end
		if W.KeyLocked or KeyMatches(key, input) then
			SetActive(false)
		elseif HasMods(mods) and input.UserInputType == Enum.UserInputType.Keyboard and mods[MOD_GROUP[input.KeyCode.Name] or ""] then
			SetActive(false)
		end
	end, el.Maid)
	W.Connect(UserInputService.WindowFocusReleased, function()
		if mode == "Hold" and active then SetActive(false) end
		StopPicking()
	end, el.Maid)

	function el._specific(input)
		return el.Enabled and HasMods(mods) and KeyMatches(key, input) and ModsMatch(key, mods)
	end
	function el._bindText() return JoinBind(key, mods) end
	function el._name() return lbl.Text end

	Method(el, "Set", function(k, silent)
		local nk, nm = ParseBind(k)
		SetBind(nk, nm, silent)
	end)
	Method(el, "Get", function() return key end)
	Method(el, "GetBind", function()
		local list = {}
		for _, g in ipairs(MOD_ORDER) do
			if mods[g] then table.insert(list, g) end
		end
		return {Key = key, Modifiers = list, Text = JoinBind(key, mods, true) or "None"}
	end)
	Method(el, "GetText", function() return JoinBind(key, mods, true) or "None" end)
	Method(el, "GetState", function() return active end)
	Method(el, "SetState", function(b) SetActive(b) end)
	Method(el, "IsPicking", function() return picking end)
	Method(el, "StartPicking", StartPicking)
	Method(el, "StopPicking", StopPicking)
	Method(el, "SetMode", function(m) SetMode(m) end)
	Method(el, "GetMode", function() return mode end)
	Method(el, "Trigger", function(down) Trigger(down ~= false) end)
	Method(el, "Clear", function() SetBind(nil, nil) end)
	Method(el, "Reset", function()
		SetMode(defaultMode)
		SetBind(defaultKey, defaultMods)
	end)
	Method(el, "OpenMenu", OpenMenu)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) ListRefresh() end)
	Method(el, "SetChangedCallback", function(fn) o.ChangedCallback = fn end)
	Method(el, "SetShowInList", function(b) o.ShowInList = b ~= false ListRefresh() end)
	function el._serialize()
		local text = JoinBind(key, mods) or "None"
		if mode == defaultMode then return text end
		return {Key = text, Mode = mode}
	end
	function el._deserialize(v)
		local m
		if type(v) == "table" then
			m = v.Mode
			v = v.Key
		end
		if m and ModeAllowed(m) then SetMode(m, false) elseif not m then SetMode(defaultMode, false) end
		local nk, nm = ParseBind(v)
		SetBind(nk, nm, true)
	end

	if W.KBList then
		entry = W.KBList.Add({
			getName = function() return tostring(o.ListName or lbl.Text) end,
			getKey = function() return JoinBind(key, mods, true) or (touchTrigger and "Tap" or "None") end,
			getMode = function() return MODE_TEXT[mode] or "" end,
			isActive = function() return active end,
			enabled = function() return el.Enabled end,
			listed = function() return o.ShowInList ~= false and el.Visible and row.Parent ~= nil end,
			trigger = Trigger,
		})
	end

	-- On unload a held Hold-bind would never see its key-up, so release it here.
	el.Maid:Give(function()
		StopPicking()
		if active and mode == "Hold" then SetActive(false) end
	end)
	local baseDestroy = el.Destroy
	Method(el, "Destroy", function()
		StopPicking()
		if active then SetActive(false) end
		local i = IndexOf(W.Keybinds, el)
		if i then table.remove(W.Keybinds, i) end
		if entry and W.KBList then W.KBList.Remove(entry) end
		entry = nil
		baseDestroy()
	end)
	local baseEnabled = el.SetEnabled
	Method(el, "SetEnabled", function(b)
		if b == false then
			StopPicking()
			if mode == "Hold" then SetActive(false) end
		end
		baseEnabled(b)
		ListRefresh()
	end)
	local baseVisible = el.SetVisible
	Method(el, "SetVisible", function(b)
		baseVisible(b)
		ListRefresh()
	end)
	function el._reset()
		StopPicking()
		SetMode(defaultMode, false)
		SetBind(defaultKey, defaultMods, true)
		SetActive(defaultActive and mode == "Toggle")
	end
	Layout(false)
	return Finish(el, o)
end
end -- keybinds

local function AddLabel(W, S, o)
	if type(o) ~= "table" then o = {Text = o} end
	local el, row = NewElement(W, S, "Label", {Enabled = o.Enabled, Disabled = o.Disabled, Visible = o.Visible}, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local text = tostring(o.Text or o.Name or o.Title or "Label")
	local lbl = Label(row, text, {
		Size = UDim2.new(1, 0, 0, 15),
		Align = o.Center and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left,
		TextSize = o.TextSize,
	})
	lbl.AutomaticSize = Enum.AutomaticSize.Y
	lbl.TextWrapped = true
	lbl.RichText = o.RichText == true
	local color = ToColor(o.Color)
	function el._apply()
		local T = W.Theme
		lbl.TextColor3 = not el.Enabled and T.TextDim or (color or T.TextGray)
	end
	W.Bind(function() el._apply() end, row)
	Method(el, "Set", function(t) text = tostring(t) lbl.Text = text end)
	Method(el, "Get", function() return text end)
	el.SetText, el.SetName = el.Set, el.Set
	Method(el, "SetColor", function(c) color = ToColor(c) el._apply() end)
	if o.DependsOn then el.DependsOn(o.DependsOn, o.InvertDependency) end
	el._apply()
	return el
end

local function AddParagraph(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Paragraph", {Enabled = o.Enabled, Disabled = o.Disabled, Visible = o.Visible}, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local box = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = row})
	Corner(box, 3)
	local st = Stroke(box, WHITE, 1)
	Create("UIPadding", {
		PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9),
		PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 8),
		Parent = box,
	})
	Create("UIListLayout", {Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder, Parent = box})
	local title = Label(box, o.Title or o.Name or "Paragraph", {Size = UDim2.new(1, 0, 0, 14), Weight = "SemiBold", Truncate = true})
	title.LayoutOrder = 1
	local body = Label(box, o.Content or o.Text or o.Description or "", {Size = UDim2.new(1, 0, 0, 0), TextSize = 10})
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.TextWrapped = true
	body.RichText = o.RichText == true
	body.LayoutOrder = 2
	function el._apply()
		local T, enabled = W.Theme, el.Enabled
		box.BackgroundColor3 = T.DropdownBg
		st.Color = enabled and T.DropdownBorder or T.DropdownBorderOff
		title.TextColor3 = enabled and T.Text or T.TextDim
		body.TextColor3 = enabled and T.TextGray or T.TextDim
	end
	W.Bind(function() el._apply() end, row)
	Method(el, "SetTitle", function(t) title.Text = tostring(t) end)
	Method(el, "SetContent", function(t) body.Text = tostring(t or "") body.Visible = body.Text ~= "" end)
	el.SetName, el.SetText, el.Set = el.SetTitle, el.SetContent, el.SetContent
	Method(el, "Get", function() return body.Text end)
	body.Visible = body.Text ~= ""
	if o.DependsOn then el.DependsOn(o.DependsOn, o.InvertDependency) end
	el._apply()
	return el
end

local function AddDivider(W, S, o)
	if type(o) ~= "table" then o = {Text = o} end
	local el, row = NewElement(W, S, "Divider", {Visible = o.Visible}, 11)
	local text = o.Text or o.Name or o.Title
	local left = Create("Frame", {Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 0.5, 0), BorderSizePixel = 0, Parent = row})
	local right = Create("Frame", {Size = UDim2.new(0, 0, 0, 1), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0.5, 0), BorderSizePixel = 0, Parent = row})
	local lbl = Label(row, "", {AutoX = true, Size = UDim2.new(0, 0, 1, 0), TextSize = 10, Align = Enum.TextXAlignment.Center})
	lbl.AnchorPoint = Vector2.new(0.5, 0)
	lbl.Position = UDim2.fromScale(0.5, 0)
	local function Layout()
		local has = text ~= nil and tostring(text) ~= ""
		lbl.Visible = has
		lbl.Text = has and tostring(text) or ""
		right.Visible = has
		if has then
			local half = math.floor(TextWidth(lbl.Text, 10) / 2 + 8)
			left.Size = UDim2.new(0.5, -half, 0, 1)
			right.Size = UDim2.new(0.5, -half, 0, 1)
		else
			left.Size = UDim2.new(1, 0, 0, 1)
		end
	end
	Layout()
	W.Bind(function(T)
		left.BackgroundColor3 = T.Divider
		right.BackgroundColor3 = T.Divider
		lbl.TextColor3 = T.TextDim
	end, row)
	Method(el, "SetText", function(t) text = t Layout() end)
	el.SetName = el.SetText
	Method(el, "Get", function() return text end)
	return el
end

-- Readable foreground for text/icons drawn on top of the accent color.
local function AddSegmented(W, S, o)
	o = Opts(o)
	local options = CopyList(o.Options or o.Values or o.List)
	local name = o.Name or o.Title
	local top = name and 19 or 0
	local el, row = NewElement(W, S, "Segmented", o, top + 25)
	local value = o.Default or o.Value
	if not IndexOf(options, value) then value = options[1] end
	el.Value = value

	local lbl = name and Label(row, name, {Size = UDim2.new(1, 0, 0, 15), Truncate = true}) or nil
	local bar = Create("Frame", {Size = UDim2.new(1, 0, 0, 25), Position = UDim2.fromOffset(0, top), BorderSizePixel = 0, Parent = row})
	Corner(bar, 5)
	local bs = Stroke(bar, WHITE, 1)
	local ind = Create("Frame", {BorderSizePixel = 0, ZIndex = 2, Parent = bar})
	Corner(ind, 4)
	local buttons = {}

	local function Layout(animate)
		local n = math.max(#options, 1)
		local i = IndexOf(options, value)
		ind.Visible = i ~= nil
		if not i then return end
		local props = {Position = UDim2.new((i - 1) / n, 2, 0, 2), Size = UDim2.new(1 / n, -4, 1, -4)}
		if animate then
			Tween(ind, MOVE_TI, props)
		else
			StopTweens(ind)
			ind.Position, ind.Size = props.Position, props.Size
		end
	end
	local segHover
	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		bar.BackgroundColor3 = T.DropdownBg
		Anim(bs, {Color = enabled and T.DropdownBorder or T.DropdownBorderOff}, animate)
		Anim(ind, {BackgroundColor3 = W.Accent, BackgroundTransparency = 1 - W.AccentAlpha * (enabled and 1 or 0.45)}, animate)
		if lbl then Anim(lbl, {TextColor3 = enabled and T.TextGray or T.TextDim}, animate) end
		for i, b in ipairs(buttons) do
			local sel = options[i] == value
			local c = not enabled and T.TextDim or (sel and OnAccent(W) or (segHover == b and T.Text or T.TextGray))
			Anim(b, {TextColor3 = c}, animate, MOVE_TI)
			ApplyFont(b, sel and "SemiBold" or "Medium")
		end
	end

	local function Build()
		for _, b in ipairs(buttons) do b:Destroy() end
		table.clear(buttons)
		segHover = nil
		local n = math.max(#options, 1)
		for i, opt in ipairs(options) do
			local b = Create("TextButton", {
				Size = UDim2.new(1 / n, 0, 1, 0),
				Position = UDim2.new((i - 1) / n, 0, 0, 0),
				BackgroundTransparency = 1,
				Text = tostring(opt),
				TextSize = TEXT,
				Weight = "Medium",
				TextTruncate = Enum.TextTruncate.AtEnd,
				AutoButtonColor = false,
				ZIndex = 3,
				Parent = bar,
			})
			b.MouseButton1Click:Connect(function() if el.Enabled then el.Set(opt) end end)
			OnMouseEnter(b, function() segHover = b el._apply(true) end)
			b.MouseLeave:Connect(function() if segHover == b then segHover = nil end el._apply(true) end)
			buttons[i] = b
		end
		Layout(false)
	end
	W.Bind(function() el._apply() end, row)
	Build()

	local function Commit(changed, silent)
		el.Value = value
		el._apply(true)
		if changed and not silent then el._fire(value) else el._sync(value) end
	end
	Method(el, "Set", function(v, silent)
		if not IndexOf(options, v) then return end
		local changed = v ~= value
		value = v
		Layout(true)
		Commit(changed, silent)
	end)
	Method(el, "Get", function() return value end)
	Method(el, "GetOptions", function() return CopyList(options) end)
	Method(el, "SetOptions", function(list, silent)
		local before = value
		options = CopyList(list)
		if not IndexOf(options, value) then value = options[1] end
		Build()
		Commit(value ~= before, silent)
	end)
	Method(el, "SetName", function(t) if lbl then lbl.Text = tostring(t) end end)
	return Finish(el, o)
end

local function AddProgressBar(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "ProgressBar", o, 23)
	local maxV = tonumber(o.Max) or 100
	if maxV <= 0 then maxV = 100 end
	local value = math.clamp(tonumber(o.Default or o.Value) or 0, 0, maxV)
	el.Value = value

	local lbl = Label(row, o.Name or o.Title or "Progress", {Size = UDim2.new(0.65, 0, 0, 15), Truncate = true})
	local valLbl = Label(row, "", {Position = UDim2.new(0.65, 0, 0, 0), Size = UDim2.new(0.35, 0, 0, 15), Align = Enum.TextXAlignment.Right})
	local track = Create("Frame", {Size = UDim2.new(1, 0, 0, 4), Position = UDim2.fromOffset(0, 17), BorderSizePixel = 0, Parent = row})
	Corner(track, 2)
	local fill = Create("Frame", {Size = UDim2.fromScale(0, 1), BorderSizePixel = 0, Parent = track})
	Corner(fill, 2)

	local function Text()
		if type(o.Format) == "function" then return tostring(SafeCall(o.Format, value, maxV) or "") end
		if o.ShowValue then
			return FormatNumber(value, Decimals(o.Step or 1)) .. " / " .. FormatNumber(maxV, Decimals(o.Step or 1))
		end
		return math.floor(value / maxV * 100 + 0.5) .. "%"
	end
	local function Layout(animate)
		local props = {Size = UDim2.fromScale(value / maxV, 1)}
		if animate then
			Tween(fill, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
		else
			StopTweens(fill)
			fill.Size = props.Size
		end
		valLbl.Text = Text()
	end
	Layout(false)
	function el._apply()
		local T, enabled = W.Theme, el.Enabled
		lbl.TextColor3 = enabled and T.TextGray or T.TextDim
		valLbl.TextColor3 = enabled and T.TextGray or T.TextDim
		track.BackgroundColor3 = T.SliderTrack
		fill.BackgroundColor3 = W.Accent
		fill.BackgroundTransparency = 1 - W.AccentAlpha * (enabled and 1 or 0.45)
	end
	W.Bind(function() el._apply() end, row)

	Method(el, "Set", function(v, silent)
		v = math.clamp(tonumber(v) or 0, 0, maxV)
		local changed = v ~= value
		value = v
		el.Value = v
		if changed then Layout(true) end
		if changed and not silent then el._fire(v) else el._sync(v) end
	end)
	Method(el, "Get", function() return value end)
	Method(el, "Increment", function(d) el.Set(value + (tonumber(d) or 1)) end)
	Method(el, "SetMax", function(m)
		m = tonumber(m)
		if not m or m <= 0 then return end
		maxV = m
		local before = value
		value = math.min(value, maxV)
		el.Value = value
		Layout(true)
		if value ~= before then el._fire(value) end
	end)
	Method(el, "GetMax", function() return maxV end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	return Finish(el, o)
end

local function AddRangeSlider(W, S, o)
	o = Opts(o)
	local EXTRA = 2
	local el, row = NewElement(W, S, "RangeSlider", o, 28 + EXTRA)
	local minV, maxV = tonumber(o.Min) or 0, tonumber(o.Max) or 100
	if maxV <= minV then maxV = minV + 1 end
	local step = tonumber(o.Step or o.Increment) or 1
	local decimals = o.Decimals or Decimals(step)

	local function Round(v)
		v = tonumber(v) or minV
		if step > 0 then v = math.floor((v - minV) / step + 0.5) * step + minV end
		v = math.clamp(v, minV, maxV)
		return tonumber(FormatNumber(v, decimals)) or v
	end
	local def = o.Default or o.Value
	if type(def) ~= "table" then def = {minV, maxV} end
	local lo, hi = Round(def[1] or def.Min or minV), Round(def[2] or def.Max or maxV)
	if lo > hi then lo, hi = hi, lo end
	local function Value() return {lo, hi} end
	el.Value = Value()

	local function Fmt(v)
		if type(o.Format) == "function" then return tostring(o.Format(v)) end
		return FormatNumber(v, decimals) .. (o.Suffix or "")
	end

	local lbl = Label(row, o.Name or o.Title or "Range", {Position = UDim2.fromOffset(0, EXTRA), Size = UDim2.new(0.5, 0, 0, 15), Truncate = true})
	local valLbl = Label(row, "", {Position = UDim2.new(0.5, 0, 0, EXTRA), Size = UDim2.new(0.5, 0, 0, 15), Align = Enum.TextXAlignment.Right})
	local hit = Create("Frame", {Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, EXTRA + 12.5), BackgroundTransparency = 1, Active = true, Parent = row})
	local track = Create("Frame", {Size = UDim2.new(1, 0, 0, 4), Position = UDim2.new(0, 0, 0.5, -2), BorderSizePixel = 0, Parent = hit})
	Corner(track, 2)
	local R = 5.5
	local fill = Create("Frame", {BorderSizePixel = 0, Parent = track})
	local knobs, strokes = {}, {}
	for i = 1, 2 do
		knobs[i] = Create("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(7, 7), BorderSizePixel = 0, ZIndex = 3, Parent = track})
		Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = knobs[i]})
		strokes[i] = Stroke(knobs[i], WHITE, 2)
	end

	local function P(v) return (v - minV) / (maxV - minV) end
	local function Layout(animate)
		local a, b = P(lo), P(hi)
		local fp = UDim2.new(a, R * (1 - 2 * a), 0, 0)
		local fs = UDim2.new(b - a, 2 * R * (a - b), 1, 0)
		local k1 = UDim2.new(a, R * (1 - 2 * a), 0.5, 0)
		local k2 = UDim2.new(b, R * (1 - 2 * b), 0.5, 0)
		if animate then
			local ti = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
			Tween(fill, ti, {Position = fp, Size = fs})
			Tween(knobs[1], ti, {Position = k1})
			Tween(knobs[2], ti, {Position = k2})
		else
			StopTweens(fill, knobs[1], knobs[2])
			fill.Position, fill.Size = fp, fs
			knobs[1].Position, knobs[2].Position = k1, k2
		end
		valLbl.Text = Fmt(lo) .. " - " .. Fmt(hi)
	end
	Layout(false)

	function el._apply()
		local T, enabled = W.Theme, el.Enabled
		lbl.TextColor3 = enabled and T.TextGray or T.TextDim
		valLbl.TextColor3 = enabled and T.TextGray or T.TextDim
		track.BackgroundColor3 = T.SliderTrack
		fill.BackgroundColor3 = W.Accent
		fill.BackgroundTransparency = 1 - W.AccentAlpha * (enabled and 1 or 0.45)
		for i = 1, 2 do
			knobs[i].BackgroundColor3 = T.KnobFill
			strokes[i].Color = enabled and T.KnobStroke or T.KnobStrokeOff
		end
	end
	W.Bind(function() el._apply() end, row)

	local function SetValues(a, b, silent, animate)
		a, b = Round(a), Round(b)
		if a > b then a, b = b, a end
		local changed = a ~= lo or b ~= hi
		lo, hi = a, b
		el.Value = Value()
		Layout(animate ~= false)
		if changed and not silent then el._fire(el.Value) else el._sync(el.Value) end
	end

	local active
	local function ValueAt(input)
		local sc = W.Scale.Scale
		local left = track.AbsolutePosition.X + R * sc
		local width = track.AbsoluteSize.X - 2 * R * sc
		if width <= 0 then return nil end
		return minV + (maxV - minV) * math.clamp((input.Position.X - left) / width, 0, 1)
	end
	local function Update(input)
		local v = ValueAt(input)
		if not v then return end
		if active == 1 then
			SetValues(math.min(v, hi), hi)
		else
			SetValues(lo, math.max(v, lo))
		end
	end
	hit.InputBegan:Connect(function(input)
		if not (el.Enabled and IsClickOrTouch(input)) then return end
		local v = ValueAt(input)
		if not v then return end
		if v <= lo then
			active = 1
		elseif v >= hi then
			active = 2
		else
			active = (v - lo <= hi - v) and 1 or 2
		end
		if W.BeginDrag(input, Update) then Update(input) end
	end)

	Method(el, "Set", function(v, silent)
		if type(v) ~= "table" then return end
		SetValues(v[1] or v.Min or lo, v[2] or v.Max or hi, silent)
	end)
	Method(el, "SetValues", function(a, b, silent) SetValues(a or lo, b or hi, silent) end)
	Method(el, "Get", Value)
	Method(el, "GetMin", function() return lo end)
	Method(el, "GetMax", function() return hi end)
	Method(el, "SetRange", function(mn, mx)
		minV, maxV = tonumber(mn) or minV, tonumber(mx) or maxV
		if maxV <= minV then maxV = minV + 1 end
		SetValues(lo, hi)
	end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	Method(el, "SetSuffix", function(s) o.Suffix = s Layout(false) end)
	return Finish(el, o)
end

local function AddStepper(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Stepper", o, 25)
	local minV, maxV = tonumber(o.Min) or 0, tonumber(o.Max) or 100
	if maxV < minV then minV, maxV = maxV, minV end
	local step = tonumber(o.Step or o.Increment) or 1
	if step <= 0 then step = 1 end
	local decimals = o.Decimals or Decimals(step)
	local function Round(v)
		v = tonumber(v)
		if not v or v ~= v then return nil end
		v = math.floor((v - minV) / step + 0.5) * step + minV
		v = math.clamp(v, minV, maxV)
		return tonumber(FormatNumber(v, decimals)) or v
	end
	local value = Round(o.Default or o.Value) or minV
	el.Value = value

	local W_BTN, W_VAL = 23, 48
	local total = W_BTN * 2 + W_VAL
	local lbl = Label(row, o.Name or o.Title or "Stepper", {Size = UDim2.new(1, -(total + 8), 1, 0), Truncate = true})
	local frame = Create("Frame", {
		Size = UDim2.fromOffset(total, 25),
		Position = UDim2.new(1, -total, 0, 0),
		BorderSizePixel = 0,
		Parent = row,
	})
	Corner(frame, 5)
	local fs = Stroke(frame, WHITE, 1)
	local function SideButton(x, icon)
		local b = Create("TextButton", {Size = UDim2.fromOffset(W_BTN, 25), Position = UDim2.fromOffset(x, 0), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 2, Parent = frame})
		local ic = CreateIcon(b, icon, 10, UDim2.new(0.5, -5, 0.5, -5))
		return b, ic
	end
	local minus, minusIc = SideButton(0, {"minus"})
	local plus, plusIc = SideButton(W_BTN + W_VAL, {"plus"})
	local seps = {}
	for i, x in ipairs({W_BTN, W_BTN + W_VAL - 1}) do
		seps[i] = Create("Frame", {Size = UDim2.fromOffset(1, 13), Position = UDim2.fromOffset(x, 6), BorderSizePixel = 0, Parent = frame})
	end
	local box = Create("TextBox", {
		Size = UDim2.fromOffset(W_VAL, 25),
		Position = UDim2.fromOffset(W_BTN, 0),
		BackgroundTransparency = 1,
		Text = "",
		ClearTextOnFocus = false,
		TextSize = TEXT,
		Weight = "Medium",
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
		Parent = frame,
	})

	local hoverMinus, hoverPlus = false, false
	function el._apply(animate)
		local T, enabled = W.Theme, el.Enabled
		Anim(lbl, {TextColor3 = enabled and T.TextGray or T.TextDim}, animate)
		frame.BackgroundColor3 = T.DropdownBg
		Anim(fs, {Color = enabled and T.DropdownBorder or T.DropdownBorderOff}, animate)
		Anim(box, {TextColor3 = enabled and T.Text or T.ValueOff}, animate, TweenInfo.new(0.3, Enum.EasingStyle.Quad))
		box.TextEditable = enabled
		local canDown, canUp = enabled and value > minV, enabled and value < maxV
		Anim(minusIc, {ImageColor3 = not canDown and T.TextDim or (hoverMinus and T.Text or T.TextGray)}, animate)
		Anim(plusIc, {ImageColor3 = not canUp and T.TextDim or (hoverPlus and T.Text or T.TextGray)}, animate)
		for _, s in ipairs(seps) do s.BackgroundColor3 = T.DropdownBorder end
	end
	W.Bind(function() el._apply() end, row)

	local function Show() box.Text = FormatNumber(value, decimals) .. (o.Suffix or "") end
	local function SetValue(v, silent)
		v = Round(v)
		if not v then Show() return end
		local changed = v ~= value
		value = v
		el.Value = v
		Show()
		if changed and row.Parent then
			-- brief accent tint on the number, eased back by el._apply
			SetProps(box, {TextColor3 = W.Accent})
		end
		el._apply(true)
		if changed and not silent then el._fire(v) else el._sync(v) end
	end
	Show()

	local holdToken = 0
	local function StopHold() holdToken = holdToken + 1 end
	local function StartHold(dir)
		StopHold()
		local token = holdToken
		SetValue(value + dir * step)
		task.delay(0.4, function()
			while token == holdToken and row.Parent and el.Enabled do
				local before = value
				SetValue(value + dir * step)
				if value == before then break end
				task.wait(0.06)
			end
		end)
	end
	for _, pair in ipairs({{minus, -1}, {plus, 1}}) do
		local b, dir = pair[1], pair[2]
		b.InputBegan:Connect(function(input)
			if el.Enabled and IsClickOrTouch(input) then StartHold(dir) end
		end)
		b.InputEnded:Connect(function(input)
			if IsClickOrTouch(input) then StopHold() end
		end)
		OnMouseEnter(b, function()
			if dir < 0 then hoverMinus = true else hoverPlus = true end
			el._apply(true)
		end)
		b.MouseLeave:Connect(function()
			StopHold()
			if dir < 0 then hoverMinus = false else hoverPlus = false end
			el._apply(true)
		end)
	end
	AttachKeyboard(box, W, function() box.Text = FormatNumber(value, decimals) end, function()
		local text = box.Text:gsub("[^%d%.%-]", "")
		SetValue(tonumber(text) or value)
	end, {Native = o.Keyboard == false, Layout = o.KeyboardLayout or "Numeric"})

	Method(el, "Set", function(v, silent) SetValue(v, silent) end)
	Method(el, "Get", function() return value end)
	Method(el, "Increment", function(n) SetValue(value + (tonumber(n) or 1) * step) end)
	Method(el, "Decrement", function(n) SetValue(value - (tonumber(n) or 1) * step) end)
	Method(el, "SetRange", function(mn, mx)
		minV, maxV = tonumber(mn) or minV, tonumber(mx) or maxV
		if maxV < minV then minV, maxV = maxV, minV end
		SetValue(value)
	end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	local baseDestroy = el.Destroy
	Method(el, "Destroy", function() StopHold() baseDestroy() end)
	return Finish(el, o)
end

local ELEMENT_KINDS = {
	"Toggle", "Slider", "Dropdown", "MultiDropdown", "Button", "CardButton", "ColorPicker", "Input", "Keybind",
	"Label", "Paragraph", "Divider", "Segmented", "ProgressBar", "RangeSlider", "Stepper",
}

function ElementApi(W, S)
	Method(S, "AddToggle", function(x) return AddToggle(W, S, x) end)
	Method(S, "AddSlider", function(x) return AddSlider(W, S, x) end)
	Method(S, "AddDropdown", function(x) return AddDropdown(W, S, x, false) end)
	Method(S, "AddMultiDropdown", function(x) return AddDropdown(W, S, x, true) end)
	Method(S, "AddColorPicker", function(x) return AddColorPicker(W, S, x) end)
	Method(S, "AddCardButton", function(x) return AddCardButton(W, S, x) end)
	Method(S, "AddInput", function(x) return AddInput(W, S, x) end)
	Method(S, "AddKeybind", function(x) return AddKeybind(W, S, x) end)
	Method(S, "AddLabel", function(x) return AddLabel(W, S, x) end)
	Method(S, "AddParagraph", function(x) return AddParagraph(W, S, x) end)
	Method(S, "AddDivider", function(x) return AddDivider(W, S, x) end)
	S.AddTextbox, S.AddTextBox = S.AddInput, S.AddInput
	Method(S, "AddSegmented", function(x) return AddSegmented(W, S, x) end)
	Method(S, "AddProgressBar", function(x) return AddProgressBar(W, S, x) end)
	Method(S, "AddRangeSlider", function(x) return AddRangeSlider(W, S, x) end)
	Method(S, "AddStepper", function(x) return AddStepper(W, S, x) end)
	S.AddProgress, S.AddNumber = S.AddProgressBar, S.AddStepper
	Method(S, "AddButton", function(x)
		x = Opts(x)
		if x.Icon or x.Description or x.Desc or x.ButtonText then return AddCardButton(W, S, x) end
		return AddPlainButton(W, S, x)
	end)
	for _, k in ipairs(ELEMENT_KINDS) do
		S[k] = S["Add" .. k]
		S["Create" .. k] = S["Add" .. k]
	end
	function S._raw(h)
		S.Order = S.Order + 1
		return Create("Frame", {Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1, LayoutOrder = S.Order, Parent = S.Content})
	end
	return S
end

local function NewSection(W, page, o)
	o = Opts(o)
	local side = o.Side
	if type(side) == "string" then side = side:lower() end
	local col
	if side == "right" or side == 2 then
		col = page.Right
	elseif side == "left" or side == 1 then
		col = page.Left
	else
		col = (page.Right.count < page.Left.count) and page.Right or page.Left
	end
	col.count, col.order = col.count + 1, col.order + 1

	local titleText = o.Name or o.Title
	local top = titleText and 30 or 7
	local bottom = titleText and 9 or 7
	local card = Create("Frame", {
		Size = UDim2.new(1, 0, 0, top + bottom),
		BorderSizePixel = 0,
		LayoutOrder = col.order,
		Parent = col.frame,
	})
	W.Paint(card, "BackgroundColor3", "CardBg")
	Corner(card, 4)
	local titleLbl
	if titleText then
		titleLbl = Label(card, titleText, {
			Position = UDim2.fromOffset(9, 8),
			Size = UDim2.new(1, -18, 0, 14),
			Weight = "SemiBold",
			Truncate = true,
		})
		W.Paint(titleLbl, "TextColor3", "Text")
	end
	local content = Create("Frame", {
		Size = UDim2.new(1, -18, 0, 0),
		Position = UDim2.fromOffset(9, top),
		BackgroundTransparency = 1,
		Parent = card,
	})
	local layout = Create("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = content})
	local function Resize()
		local sc = W.Scale.Scale
		if sc <= 0 then return end
		local h = layout.AbsoluteContentSize.Y / sc
		content.Size = UDim2.new(1, -18, 0, h)
		card.Size = UDim2.new(1, 0, 0, top + h + bottom)
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(Resize)

	local S = {Order = 0, Content = content, Card = card}
	ElementApi(W, S)
	Method(S, "SetTitle", function(t) if titleLbl then titleLbl.Text = tostring(t) end end)
	S.SetName = S.SetTitle
	Method(S, "SetVisible", function(b) card.Visible = b ~= false end)
	Method(S, "Destroy", function()
		for i = #W.Elements, 1, -1 do
			local el = W.Elements[i]
			if el and el.Row:IsDescendantOf(card) then el.Destroy() end
		end
		if card.Parent then col.count = col.count - 1 end
		card:Destroy()
		W.Prune()
	end)
	return S
end

local function NewPage(W, full)
	local scroll = Create("ScrollingFrame", {
		Size = UDim2.fromOffset(WIN_W, BODY_H),
		Position = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 2,
		ScrollBarThickness = 0,
		ScrollBarImageTransparency = 1,
		TopImage = "",
		MidImage = "",
		BottomImage = "",
		VerticalScrollBarInset = Enum.ScrollBarInset.None,
		ScrollingEnabled = W.WheelScroll,
		ElasticBehavior = Enum.ElasticBehavior.Never,
		CanvasSize = UDim2.fromOffset(0, 0),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
		Parent = W.PageClip,
	})
	local hit = Create("Frame", {BackgroundTransparency = 1, Active = true, Visible = false, ZIndex = 7, Parent = W.Main})
	local track = Create("Frame", {BorderSizePixel = 0, ZIndex = 7, Parent = hit})
	local thumb = Create("Frame", {BorderSizePixel = 0, ZIndex = 8, Parent = track})
	W.Paint(track, "BackgroundColor3", "ScrollTrack")

	local page = {scroll = scroll, canvas = 0}
	local dragging, hovering, grabOff = false, false, 0
	local goal, step = 0, nil

	local function ThumbColor(instant)
		local T = W.Theme
		local c = dragging and T.ScrollDrag or (hovering and T.ScrollHover or T.ScrollThumb)
		if instant then
			SetProps(thumb, {BackgroundColor3 = c})
		else
			Tween(thumb, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {BackgroundColor3 = c})
		end
	end
	W.Bind(function() ThumbColor(true) end, thumb)

	local function MaxScroll()
		return math.max(0, page.canvas - BODY_H)
	end

	function page.Update()
		local maxS = page.canvas - BODY_H
		local vis = scroll.Visible and not page.Leaving
		if vis and W.SetFade then
			W.SetFade(maxS > 1 and scroll.CanvasPosition.Y < maxS - 1)
		end
		local show = vis and maxS > 1
		hit.Visible = show
		if not show then return end
		local bw = W.BarW + 1
		hit.Size = UDim2.fromOffset(bw + 8, TRK_LEN)
		hit.Position = UDim2.fromOffset(BAR_RIGHT - bw - 4, HEADER_H + TRK_TOP)
		track.Size = UDim2.new(0, bw, 1, 0)
		track.Position = UDim2.fromOffset(4, 0)
		local th = math.clamp(TRK_LEN * BODY_H / page.canvas, 20, TRK_LEN)
		local frac = math.clamp(scroll.CanvasPosition.Y / maxS, 0, 1)
		thumb.Size = UDim2.new(1, 0, 0, th)
		thumb.Position = UDim2.fromOffset(0, frac * (TRK_LEN - th))
	end

	function page.StopScroll()
		if step then
			step:Disconnect()
			step = nil
		end
	end
	function page.ScrollTo(y, instant)
		goal = math.clamp(tonumber(y) or 0, 0, MaxScroll())
		if instant then
			page.StopScroll()
			scroll.CanvasPosition = Vector2.new(0, goal)
			return
		end
		if step then return end
		step = RunService.RenderStepped:Connect(function(dt)
			local cur = scroll.CanvasPosition.Y
			local nxt = cur + (goal - cur) * (1 - math.exp(-dt * 18))
			if math.abs(goal - nxt) < 0.5 then nxt = goal end
			scroll.CanvasPosition = Vector2.new(0, nxt)
			if nxt == goal then page.StopScroll() end
		end)
	end

	function page.SetCanvas(h)
		page.canvas = h
		scroll.CanvasSize = UDim2.fromOffset(0, h)
		goal = math.clamp(goal, 0, MaxScroll())
		local need = h - BODY_H > 1
		if need ~= page.needBar then
			page.needBar = need
			if page.LayoutColumns then page.LayoutColumns() end
		end
		page.Update()
	end
	function page.Show(b)
		scroll.Visible = b
		if not b then page.StopScroll() end
		page.Update()
	end

	local function SetFromMouse(mouseY)
		local maxS = MaxScroll()
		if maxS <= 1 then return end
		local sc = W.Scale.Scale
		local th = thumb.AbsoluteSize.Y / sc
		local travel = TRK_LEN - th
		if travel <= 0 then return end
		local top = (mouseY - hit.AbsolutePosition.Y) / sc - grabOff
		page.ScrollTo(math.clamp(top / travel, 0, 1) * maxS)
	end

	hit.InputBegan:Connect(function(input)
		if not IsClickOrTouch(input) then return end
		local sc = W.Scale.Scale
		local ty, th = thumb.AbsolutePosition.Y, thumb.AbsoluteSize.Y
		if input.Position.Y >= ty and input.Position.Y <= ty + th then
			local began = W.BeginDrag(input, function(i) SetFromMouse(i.Position.Y) end, function()
				dragging = false
				ThumbColor()
			end)
			if began then
				dragging = true
				grabOff = (input.Position.Y - ty) / sc
				ThumbColor()
			end
		elseif MaxScroll() > 1 and not W.Drag then
			local dir = (input.Position.Y < ty) and -1 or 1
			local from = step and goal or scroll.CanvasPosition.Y
			page.ScrollTo(from + dir * BODY_H * 0.9)
		end
	end)
	scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(page.Update)
	OnMouseEnter(hit, function() hovering = true ThumbColor() end)
	hit.MouseLeave:Connect(function() hovering = false ThumbColor() end)

	function page.Recalc()
		local sc = W.Scale.Scale * (page.zoom and page.zoom.Scale or 1)
		if sc <= 0 or not (page.Left and page.Right) then return end
		local h = math.max(page.Left.layout.AbsoluteContentSize.Y, page.Right.layout.AbsoluteContentSize.Y) / sc
		page.SetCanvas(h > 0 and (h + 18) or 0)
	end
	local function Column()
		local frame = Create("Frame", {Position = UDim2.fromOffset(9, 9), BackgroundTransparency = 1, Parent = scroll})
		local layout = Create("UIListLayout", {Padding = UDim.new(0, 9), SortOrder = Enum.SortOrder.LayoutOrder, Parent = frame})
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() page.Recalc() end)
		return {frame = frame, layout = layout, count = 0, order = 0}
	end
	page.Left = Column()
	page.Right = full and page.Left or Column()
	function page.LayoutColumns()
		local right = 456
		if page.needBar then right = math.min(456, BAR_RIGHT - (W.BarW + 1) - 9) end
		local total = right - 9
		if full then
			page.Left.frame.Size = UDim2.fromOffset(total, 0)
		else
			local w = math.floor((total - 9) / 2)
			page.Left.frame.Size = UDim2.fromOffset(w, 0)
			page.Right.frame.Size = UDim2.fromOffset(w, 0)
			page.Right.frame.Position = UDim2.fromOffset(right - w, 9)
		end
	end
	page.LayoutColumns()

	table.insert(W.Pages, page)
	return page
end

local function AttachSections(W, api, page)
	Method(api, "AddSection", function(o) return NewSection(W, page, o) end)
	api.Section = api.AddSection
	api.CreateSection = api.AddSection
	Method(api, "ScrollTo", function(y, instant) page.ScrollTo(y, instant) end)
	return api
end

local function BuildWatermark(W, cfg)
	if cfg == false then cfg = {Enabled = false} end
	cfg = cfg or {}
	local WM = {
		Fade = {},
		LogoFade = {},
		IconGroups = {},
		Detail = cfg.Detail or cfg.Text or "roblox",
		Provider = cfg.Provider,
		ToggleOnClick = cfg.ToggleOnClick ~= false,
		Opacity = 1,
		ShowIcons = true,
	}
	W.WM = WM

	local frame = Create("Frame", {
		Name = "Watermark",
		Size = UDim2.new(0, 0, 0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = cfg.Position or UDim2.fromOffset(8, 8),
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Active = true,
		Visible = cfg.Enabled ~= false,
		Parent = W.Gui,
	})
	WM.Frame = frame
	W.Paint(frame, "BackgroundColor3", "WmBg")
	table.insert(WM.Fade, {frame, "BackgroundTransparency", 0.1})
	Corner(frame, 13)
	local stroke = Stroke(frame, WHITE, 1, 0.15)
	W.Paint(stroke, "Color", "WmStroke")
	table.insert(WM.Fade, {stroke, "Transparency", 0.15})
	MakeDraggable(W, frame, frame, {
		OnClick = function()
			if WM.ToggleOnClick and W.Window then W.Window.Toggle() end
		end,
	})
	Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = frame,
	})
	Create("UIPadding", {PaddingLeft = UDim.new(0, 11.5), PaddingRight = UDim.new(0, 15.5), Parent = frame})

	local order = 0
	local function nx() order = order + 1 return order end
	local function Spacer(w)
		return Create("Frame", {Size = UDim2.fromOffset(w, 1), BackgroundTransparency = 1, LayoutOrder = nx(), Parent = frame})
	end
	local function Divider()
		local d = Create("Frame", {Size = UDim2.fromOffset(1, 14), BorderSizePixel = 0, LayoutOrder = nx(), Parent = frame})
		W.Paint(d, "BackgroundColor3", "WmDivider")
		table.insert(WM.Fade, {d, "BackgroundTransparency", 0})
		return d
	end
	local function Item(iconSpec, colorKey, text)
		local grp = Create("Frame", {Size = UDim2.fromOffset(16, 12), BackgroundTransparency = 1, LayoutOrder = nx(), Parent = frame})
		local ic = CreateIcon(grp, iconSpec, 12, UDim2.fromOffset(0, 0))
		W.Bind(function(T, accent)
			ic.ImageColor3 = colorKey == "Accent" and accent or T[colorKey]
		end, ic)
		table.insert(WM.Fade, {ic, "ImageTransparency", 0})
		table.insert(WM.IconGroups, grp)
		local lbl = Label(frame, text, {AutoX = true, Size = UDim2.new(0, 0, 1, 0)})
		lbl.LayoutOrder = nx()
		W.Paint(lbl, "TextColor3", "WmText")
		table.insert(WM.Fade, {lbl, "TextTransparency", 0})
		return {grp = grp, icon = ic, label = lbl}
	end

	WM.LogoOrder = nx()
	function WM.BuildLogo()
		if WM.LogoFrame then WM.LogoFrame:Destroy() end
		local box, fades = CreateLogo(W, frame, W.LogoSpec, 10, 12)
		box.LayoutOrder = WM.LogoOrder
		WM.LogoFrame, WM.LogoFade = box, fades
		WM.ApplyOpacity()
	end

	Spacer(10.5)
	Divider()
	Spacer(3.7)
	WM.TitleItem = Item(cfg.TitleIcon or "tag", "Accent", cfg.Title or W.Title)
	WM.SiteSpacer = Spacer(13)
	WM.SiteItem = Item(cfg.SiteIcon or "globe", "WmSiteIcon", cfg.Site or "")
	local detailSep = {Spacer(8.5), Divider(), Spacer(3.5)}
	WM.Details = {}
	for _, mode in ipairs(DETAIL_MODES) do
		local box = Create("Frame", {
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			LayoutOrder = nx(),
			Parent = frame,
		})
		Create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = box,
		})
		local gap = Create("Frame", {Size = UDim2.fromOffset(13, 1), BackgroundTransparency = 1, LayoutOrder = 1, Parent = box})
		local grp = Create("Frame", {Size = UDim2.fromOffset(16, 12), BackgroundTransparency = 1, LayoutOrder = 2, Parent = box})
		local spec = (mode == "Product Type" and cfg.DetailIcon) or (cfg.DetailIcons and cfg.DetailIcons[mode]) or DETAIL_ICONS[mode]
		local ic = CreateIcon(grp, spec, 12, UDim2.fromOffset(0, 0))
		W.Paint(ic, "ImageColor3", "WmDetailIcon")
		table.insert(WM.Fade, {ic, "ImageTransparency", 0})
		table.insert(WM.IconGroups, grp)
		local lbl = Label(box, "", {AutoX = true, Size = UDim2.new(0, 0, 1, 0)})
		lbl.LayoutOrder = 3
		W.Paint(lbl, "TextColor3", "WmText")
		table.insert(WM.Fade, {lbl, "TextTransparency", 0})
		WM.Details[mode] = {box = box, gap = gap, grp = grp, icon = ic, label = lbl}
	end

	local function ParseModes(m)
		local set = {}
		if type(m) == "string" then
			set[m] = true
		elseif type(m) == "table" then
			for k, v in pairs(m) do
				if type(k) == "number" then
					set[v] = true
				elseif v then
					set[k] = true
				end
			end
		end
		return set
	end
	WM.Modes = ParseModes(cfg.Modes or cfg.Mode or {"Product Type"})

	function WM.LayoutDetails()
		local first = true
		for _, mode in ipairs(DETAIL_MODES) do
			local d = WM.Details[mode]
			local on = WM.Modes[mode] == true
			d.box.Visible = on
			if on then
				d.gap.Visible = not first
				first = false
			end
		end
		for _, x in ipairs(detailSep) do x.Visible = not first end
	end
	function WM.SetModes(m)
		WM.Modes = ParseModes(m)
		WM.LayoutDetails()
		WM.UpdateDetails()
	end
	function WM.GetModes()
		local out = {}
		for _, mode in ipairs(DETAIL_MODES) do
			if WM.Modes[mode] then table.insert(out, mode) end
		end
		return out
	end

	function WM.ApplyOpacity()
		local a = WM.Opacity
		for _, list in ipairs({WM.Fade, WM.LogoFade}) do
			for _, e in ipairs(list) do
				e[1][e[2]] = 1 - (1 - e[3]) * a
			end
		end
	end
	function WM.SetSite(text)
		local has = text ~= nil and text ~= ""
		WM.SiteItem.label.Text = has and tostring(text) or ""
		WM.SiteItem.label.Visible = has
		WM.SiteItem.grp.Visible = has and WM.ShowIcons
		WM.SiteSpacer.Visible = has
		WM.HasSite = has
	end
	function WM.SetIconsVisible(b)
		WM.ShowIcons = b
		for _, g in ipairs(WM.IconGroups) do g.Visible = b end
		if not WM.HasSite then WM.SiteItem.grp.Visible = false end
	end
	WM.BuildLogo()
	WM.SetSite(cfg.Site)
	WM.LayoutDetails()

	local fps = 60
	W.Connect(RunService.RenderStepped, function(dt)
		if dt > 0 then fps = fps + (1 / dt - fps) * 0.1 end
	end)
	function WM.Text(mode)
		if WM.Provider then
			local res = SafeCall(WM.Provider, mode)
			if res ~= nil then return tostring(res) end
		end
		if mode == "Time" then
			return os.date("%H:%M:%S")
		elseif mode == "FPS" then
			return string.format("%d fps", math.floor(fps + 0.5))
		elseif mode == "Ping" then
			local ok, ping = pcall(function()
				return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
			end)
			return ok and string.format("%d ms", math.floor(ping + 0.5)) or "-- ms"
		end
		return tostring(WM.Detail)
	end
	function WM.UpdateDetails()
		for mode in pairs(WM.Modes) do
			local d = WM.Details[mode]
			if d then
				local txt = WM.Text(mode)
				if d.label.Text ~= txt then d.label.Text = txt end
			end
		end
	end
	WM.UpdateDetails()
	W.Maid:Spawn(function()
		while W.Alive do
			if frame.Visible then WM.UpdateDetails() end
			task.wait(0.25)
		end
	end)

	local api = {}
	local wanted = frame.Visible
	Method(api, "SetVisible", function(b)
		wanted = b ~= false
		frame.Visible = wanted and not W.KeyLocked
	end)
	Method(api, "IsVisible", function() return wanted end)
	function WM.ApplyLock() frame.Visible = wanted and not W.KeyLocked end
	Method(api, "Toggle", function() api.SetVisible(not wanted) end)
	Method(api, "SetTitle", function(t) WM.TitleItem.label.Text = tostring(t) end)
	Method(api, "SetSite", function(t) WM.SetSite(t) end)
	Method(api, "SetDetail", function(t)
		WM.Detail = t
		WM.UpdateDetails()
	end)
	Method(api, "SetProvider", function(fn)
		WM.Provider = fn
		WM.UpdateDetails()
	end)
	Method(api, "SetModes", function(m)
		if type(m) == "string" then m = {m} end
		if W.WmDetails then W.WmDetails.Set(m) else WM.SetModes(m) end
	end)
	api.SetMode = api.SetModes
	Method(api, "GetModes", function() return WM.GetModes() end)
	api.GetMode = api.GetModes
	Method(api, "SetOpacity", function(a)
		a = math.clamp(tonumber(a) or 1, 0, 1)
		if W.WmOpacity then W.WmOpacity.Set(math.floor(a * 100 + 0.5)) else WM.Opacity = a WM.ApplyOpacity() end
	end)
	Method(api, "SetIconsVisible", function(b)
		if W.WmIcons then W.WmIcons.Set(b) else WM.SetIconsVisible(b ~= false) end
	end)
	Method(api, "SetIcons", function(t)
		t = t or {}
		if t.Title then ApplyIcon(WM.TitleItem.icon, t.Title) end
		if t.Site then ApplyIcon(WM.SiteItem.icon, t.Site) end
		if t.Detail then ApplyIcon(WM.Details["Product Type"].icon, t.Detail) end
		for mode, d in pairs(WM.Details) do
			if t[mode] then ApplyIcon(d.icon, t[mode]) end
		end
	end)
	Method(api, "SetPosition", function(p) frame.Position = p end)
	Method(api, "SetToggleOnClick", function(b) WM.ToggleOnClick = b ~= false end)
	return api
end

local function Notify(W, o)
	if not W.Alive then return nil end
	if type(o) == "string" then o = {Content = o} end
	o = o or {}
	local T = W.Theme
	W.NotifyOrder = W.NotifyOrder + 1
	local holder = Create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = W.NotifyOrder,
		Parent = W.NotifyHolder,
	})
	local card = Create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(260, 0),
		BackgroundColor3 = T.CardBg,
		BorderSizePixel = 0,
		Parent = holder,
	})
	Corner(card, 4)
	local cardStroke = Stroke(card, T.DropdownBorder, 1)
	Create("UIPadding", {
		PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 9), PaddingBottom = UDim.new(0, 12),
		Parent = card,
	})
	Create("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = card})
	local top = Create("Frame", {Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1, LayoutOrder = 1, Parent = card})
	local x = 0
	local nIcon, nContent
	if o.Icon ~= false then
		nIcon = CreateIcon(top, o.Icon or "bell", 12, UDim2.new(0, 0, 0.5, -6), W.Accent)
		x = 18
	end
	local nTitle = Label(top, o.Title or W.Title, {Position = UDim2.fromOffset(x, 0), Size = UDim2.new(1, -x, 1, 0), Color = T.Text, Weight = "SemiBold", Truncate = true})
	if o.Content or o.Text then
		nContent = Label(card, o.Content or o.Text, {Size = UDim2.new(1, 0, 0, 0), Color = T.TextGray})
		nContent.AutomaticSize = Enum.AutomaticSize.Y
		nContent.TextWrapped = true
		nContent.LayoutOrder = 2
	end
	local barHost = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1, LayoutOrder = 3, Parent = card})
	local bar = Create("Frame", {
		Size = UDim2.new(1, 0, 0, 2),
		Position = UDim2.fromOffset(0, 4),
		BackgroundColor3 = W.Accent,
		BackgroundTransparency = 1 - W.AccentAlpha,
		BorderSizePixel = 0,
		Parent = barHost,
	})
	Corner(bar, 1)
	W.Bind(function(th, accent, alpha)
		card.BackgroundColor3 = th.CardBg
		cardStroke.Color = th.DropdownBorder
		nTitle.TextColor3 = th.Text
		if nContent then nContent.TextColor3 = th.TextGray end
		if nIcon then nIcon.ImageColor3 = accent end
		bar.BackgroundColor3 = accent
		bar.BackgroundTransparency = 1 - alpha
	end, holder)

	local duration = math.max(tonumber(o.Duration or o.Time) or 4, 0.1)
	Tween(card, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = UDim2.fromOffset(0, 0)})
	Tween(bar, TweenInfo.new(duration, Enum.EasingStyle.Linear), {Size = UDim2.new(0, 0, 0, 2)})
	local closed = false
	local function Close()
		if closed or not W.Alive then return end
		closed = true
		local t = Tween(card, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {Position = UDim2.fromOffset(260, 0)})
		t.Completed:Connect(function() holder:Destroy() end)
	end
	W.Maid:Delay(duration, Close)
	SafeCall(o.Callback)
	return {Close = Close}
end

local function BuildShell(W)
	local Holder = Create("Frame", {
		Name = "Window",
		Size = UDim2.fromOffset(WIN_W, WIN_H),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = W.Gui,
	})
	W.Holder = Holder
	W.Scale = Create("UIScale", {Scale = 1, Parent = Holder})

	local Main = Create("Frame", {Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Active = true, Parent = Holder})
	W.Paint(Main, "BackgroundColor3", "WindowBg")
	Corner(Main, 6)
	W.Main = Main

	local Header = Create("Frame", {
		Size = UDim2.new(1, 0, 0, HEADER_H),
		BorderSizePixel = 0,
		Active = true,
		ZIndex = 8,
		Parent = Main,
	})
	Corner(Header, 6)
	W.Paint(Header, "BackgroundColor3", "BarBg")
	local HeaderFill = Create("Frame", {
		Size = UDim2.new(1, 0, 0, HEADER_H / 2),
		Position = UDim2.new(0, 0, 0, HEADER_H / 2),
		BorderSizePixel = 0,
		Parent = Header,
	})
	W.Paint(HeaderFill, "BackgroundColor3", "BarBg")
	local wash = AccentWash(Header, 6, 0.07)
	W.Bind(function(_, accent, alpha) wash(accent, alpha) end, Header)
	local hl = Create("Frame", {Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BorderSizePixel = 0, Parent = Header})
	W.Paint(hl, "BackgroundColor3", "BarLine")
	MakeDraggable(W, Header, Holder)
	W.Header = Header

	local brand = Create("Frame", {
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.fromOffset(9, 0),
		BackgroundTransparency = 1,
		Parent = Header,
	})
	Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 5),
		Parent = brand,
	})
	W.Brand = brand
	W.TitleLabel = Label(brand, W.Title, {AutoX = true, Size = UDim2.new(0, 0, 1, 0), Weight = "SemiBold"})
	W.TitleLabel.LayoutOrder = 2
	W.Paint(W.TitleLabel, "TextColor3", "Text")
	function W.BuildHeaderLogo()
		if W.HeaderLogo then W.HeaderLogo:Destroy() end
		W.HeaderLogo = CreateLogo(W, brand, W.LogoSpec, 12, 15)
		W.HeaderLogo.LayoutOrder = 1
	end
	W.BuildHeaderLogo()

	W.HeaderDivider = Create("Frame", {Size = UDim2.fromOffset(1, 15), BorderSizePixel = 0, Parent = Header})
	W.Paint(W.HeaderDivider, "BackgroundColor3", "Divider")

	local SetBtn = Create("TextButton", {
		Size = UDim2.fromOffset(26, 27),
		Position = UDim2.fromOffset(444.5, 4.5),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = Header,
	})
	W.Paint(SetBtn, "BackgroundColor3", "TileBg")
	Corner(SetBtn, 2)
	W.SetBtn = SetBtn
	W.GearIcon = CreateIcon(SetBtn, {"settings", "cog"}, 12, UDim2.new(0.5, -6, 0.5, -6))
	W.NavIcon(W.GearIcon)

	W.SubHolder = Create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(0, 26),
		BackgroundTransparency = 1,
		Parent = Header,
	})
	W.SubIndicator = Create("Frame", {
		Size = UDim2.fromOffset(26, 26),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = W.SubHolder,
	})
	Corner(W.SubIndicator, 2)
	W.Paint(W.SubIndicator, "BackgroundColor3", "TileBg")

	local BottomBar = Create("Frame", {
		Size = UDim2.new(1, 0, 0, BOTTOM_H),
		Position = UDim2.new(0, 0, 1, -BOTTOM_H),
		BorderSizePixel = 0,
		ZIndex = 10,
		Parent = Main,
	})
	W.Paint(BottomBar, "BackgroundColor3", "BarBg")
	Corner(BottomBar, 6)
	local bf = Create("Frame", {Size = UDim2.new(1, 0, 0, BOTTOM_H / 2), BorderSizePixel = 0, Parent = BottomBar})
	W.Paint(bf, "BackgroundColor3", "BarBg")
	local bl = Create("Frame", {Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0, Parent = BottomBar})
	W.Paint(bl, "BackgroundColor3", "BarLine")

	local BottomFade = Create("Frame", {
		Size = UDim2.new(1, 0, 0, 41),
		Position = UDim2.fromOffset(0, HEADER_H + BODY_H - 41),
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = Main,
	})
	W.Paint(BottomFade, "BackgroundColor3", "WindowBg")
	Create("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.55),
			NumberSequenceKeypoint.new(0.85, 0.08),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = BottomFade,
	})
	BottomFade.BackgroundTransparency = 1
	local fadeOn = false
	function W.SetFade(on)
		if on == fadeOn then return end
		fadeOn = on
		Tween(BottomFade, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = on and 0 or 1})
	end

	-- Pages slide inside this, so transitions never draw outside the window body.
	W.PageClip = Create("Frame", {
		Size = UDim2.new(1, 0, 0, BODY_H),
		Position = UDim2.fromOffset(0, HEADER_H),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = Main,
	})
	W.Fader = Create("Frame", {
		Size = UDim2.new(1, 0, 0, BODY_H),
		Position = UDim2.fromOffset(0, HEADER_H),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = Main,
	})
	W.Paint(W.Fader, "BackgroundColor3", "WindowBg")

	W.PopupLayer = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 30, Parent = Main})

	W.NavHolder = Create("Frame", {
		Size = UDim2.new(0, 0, 1, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		BackgroundTransparency = 1,
		Parent = BottomBar,
	})
	Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Parent = W.NavHolder})

	W.NotifyHolder = Create("Frame", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -12),
		Size = UDim2.new(0, 240, 1, -24),
		BackgroundTransparency = 1,
		Parent = W.Gui,
	})
	Create("UIListLayout", {
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
		Parent = W.NotifyHolder,
	})
end

local function BuildNavigation(W)
	function W.LayoutHeader()
		local x = W.SetBtn.Position.X.Offset
		if W.CfgBtn then
			x = x - 30.5
			W.CfgBtn.Position = UDim2.fromOffset(x, 4.5)
		end
		for _, b in ipairs(W.HeaderButtons) do
			x = x - 30.5
			b.Position = UDim2.fromOffset(x, 6)
		end
		local divX = x - 5
		W.HeaderDivider.Position = UDim2.fromOffset(divX, 10.5)
		W.SubHolder.Position = UDim2.new(0, divX - 14, 0.5, 0)
	end
	W.LayoutHeader()

	function W.RelayoutNav()
		local n = #W.Tabs
		if n == 0 then return end
		local bw = math.min(102, math.floor((WIN_W - 16) / n))
		W.NavHolder.Size = UDim2.new(0, bw * n, 1, 0)
		W.NavHolder.Position = UDim2.new(0.5, -bw * n / 2, 0, 0)
		for _, t in ipairs(W.Tabs) do
			t.Button.Size = UDim2.new(0, bw, 1, 0)
			t.TileOn = UDim2.fromOffset(bw - 8, 27)
			t.TileOff = UDim2.fromOffset(bw - 22, 23)
		end
	end

	function W.PageFor()
		local m = W.Nav.main
		if m == "settings" then return W.SettingsPage end
		if m == "configs" then return W.ConfigPage end
		if #m.Subs > 0 and m.CurSub then return m.CurSub.Page end
		return m.Page
	end

	local function OrderOf(page)
		if page == nil then return 0 end
		if page == W.SettingsPage then return 1e6 end
		if page == W.ConfigPage then return 1e6 - 1 end
		for ti, t in ipairs(W.Tabs) do
			if t.Page == page then return ti * 100 end
			for si, sub in ipairs(t.Subs) do
				if sub.Page == page then return ti * 100 + si end
			end
		end
		return 0
	end

	local PageTweens = {}
	local SwitchToken = 0
	local HOME = UDim2.fromOffset(0, 0)
	local function Info(p, delayIndex)
		return TweenInfo.new(p[1], p[2], p[3], 0, false, delayIndex and p[delayIndex] or 0)
	end
	-- Position for a page drifted by d px along the axis and scaled to z about its centre.
	local function Place(tr, d, z)
		z = z or 1
		local cx, cy = (1 - z) * WIN_W / 2, (1 - z) * BODY_H / 2
		if tr.Axis == "Y" then return UDim2.fromOffset(cx, cy + d) end
		return UDim2.fromOffset(cx + d, cy)
	end
	local function Zoom(page)
		page.zoom = page.zoom or Create("UIScale", {Scale = 1, Parent = page.scroll})
		return page.zoom
	end
	local function Rest(p)
		p.scroll.Position = HOME
		if p.zoom then p.zoom.Scale = 1 end
	end

	function W.GetTransition()
		return PAGE_TRANSITIONS[W.TransitionName] and W.TransitionName or PAGE_TRANSITIONS[1].Name
	end
	function W.SetTransition(name)
		if not PAGE_TRANSITIONS[name] then return false end
		W.TransitionName = name
		if W.TransitionDropdown and W.TransitionDropdown.Get() ~= name then W.TransitionDropdown.Set(name, true) end
		return true
	end

	-- Cross Dissolve renders two pages at once, each inside its own temporary CanvasGroup, so the
	-- outgoing page can fade out while the incoming one fades in. Wrappers exist only mid-fade,
	-- so text stays crisp at rest.
	local function Unwrap(p)
		local g = p.wrap
		if not g then return end
		p.wrap = nil
		pcall(function() p.scroll.Parent = W.PageClip end)
		pcall(function() g:Destroy() end)
	end
	local function Wrap(p, from)
		if p.wrap then return p.wrap end
		local ok, g = pcall(Create, "CanvasGroup", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			GroupTransparency = from,
			ZIndex = 2,
			Parent = W.PageClip,
		})
		if not ok or not g then return nil end
		p.wrap = g
		p.scroll.Parent = g
		return g
	end

	function W.ShowPage(page, animate)
		SwitchToken = SwitchToken + 1
		local token = SwitchToken
		for _, t in ipairs(PageTweens) do t:Cancel() end
		table.clear(PageTweens)
		local tr = PAGE_TRANSITIONS[W.GetTransition()]
		-- W.CurrentPage can still be hidden when a switch interrupts the veil phase of the previous
		-- one; animate from the page that is actually on screen so nothing is left frozen mid-drift.
		local old = W.CurrentPage
		if old and old ~= page and not old.scroll.Visible then
			for _, p in ipairs(W.Pages) do
				if p ~= page and p.scroll.Visible then old = p break end
			end
		end
		local dir = OrderOf(page) >= OrderOf(old) and 1 or -1
		local sign = tr.Fixed and 1 or dir

		local function Swap(reveal)
			for _, p in ipairs(W.Pages) do
				if p ~= page then
					p.Leaving = nil
					p.Show(false)
					Unwrap(p)
					Rest(p)
				end
			end
			page.Leaving = nil
			Unwrap(page)
			page.ScrollTo(0, true)
			page.Show(true)
			Rest(page)
			if not reveal then
				StopTweens(W.Fader)
				W.Fader.BackgroundTransparency = 1
				return
			end
			local into = tr.In
			W.Fader.BackgroundTransparency = 0
			page.scroll.Position = Place(tr, sign * (into[4] or 0), into[5])
			if into[5] then Zoom(page).Scale = into[5] end
			local ti = Info(into)
			table.insert(PageTweens, Tween(page.scroll, ti, {Position = HOME}))
			if into[5] then table.insert(PageTweens, Tween(page.zoom, ti, {Scale = 1})) end
			table.insert(PageTweens, Tween(W.Fader, Info(tr.Reveal, 4), {BackgroundTransparency = 1}))
		end

		if not animate or not old or old == page or tr.None then
			Swap(false)
			return
		end

		if tr.Cross then
			local ti = Info(tr.In)
			if W.Fader.BackgroundTransparency < 1 then
				table.insert(PageTweens, Tween(W.Fader, ti, {BackgroundTransparency = 1}))
			end
			-- Coming back to a page that is still fading out: continue from its current opacity.
			local back = page.wrap ~= nil and page.scroll.Visible
			if not back then
				Unwrap(page)
				page.ScrollTo(0, true)
			end
			page.Leaving = nil
			Rest(page)
			local inGroup = Wrap(page, 1)
			if not inGroup then
				Swap(false)
				return
			end
			if not back then inGroup.GroupTransparency = 1 end
			inGroup.ZIndex = 3
			local leaving = {}
			for _, p in ipairs(W.Pages) do
				if p ~= page then
					if p.scroll.Visible then
						Rest(p)
						local g = Wrap(p, 0)
						if g then
							g.ZIndex = 2
							p.Leaving = true
							p.Update()
							table.insert(leaving, p)
							table.insert(PageTweens, Tween(g, ti, {GroupTransparency = 1}))
						else
							p.Leaving = nil
							p.Show(false)
						end
					else
						p.Leaving = nil
						Unwrap(p)
						Rest(p)
					end
				end
			end
			page.Show(true)
			local t = Tween(inGroup, ti, {GroupTransparency = 0})
			table.insert(PageTweens, t)
			t.Completed:Connect(function(state)
				if state ~= Enum.PlaybackState.Completed or token ~= SwitchToken or not W.Alive then return end
				for _, p in ipairs(leaving) do
					p.Leaving = nil
					p.Show(false)
					Unwrap(p)
					Rest(p)
				end
				Unwrap(page)
			end)
			return
		end

		-- Other presets don't use the wrappers: settle anything left over from an interrupted fade.
		for _, p in ipairs(W.Pages) do
			Unwrap(p)
			if p.Leaving then
				p.Leaving = nil
				p.Update()
			end
		end

		if tr.Push then
			for _, p in ipairs(W.Pages) do
				if p ~= page and p ~= old then p.Show(false) Rest(p) end
			end
			StopTweens(W.Fader)
			W.Fader.BackgroundTransparency = 1
			if old.zoom then old.zoom.Scale = 1 end
			-- The outgoing page keeps rendering while it slides, but its scrollbar hides at once.
			old.Leaving = true
			old.Update()
			page.ScrollTo(0, true)
			page.Show(true)
			Rest(page)
			page.scroll.Position = UDim2.fromOffset(dir * WIN_W, 0)
			local ti = Info(tr.In)
			table.insert(PageTweens, Tween(old.scroll, ti, {Position = UDim2.fromOffset(-dir * WIN_W, 0)}))
			local t = Tween(page.scroll, ti, {Position = HOME})
			table.insert(PageTweens, t)
			t.Completed:Connect(function(state)
				if state ~= Enum.PlaybackState.Completed or token ~= SwitchToken or not W.Alive then return end
				old.Leaving = nil
				old.Show(false)
				Rest(old)
			end)
			return
		end

		local out = tr.Out
		local ti = Info(out)
		table.insert(PageTweens, Tween(old.scroll, ti, {Position = Place(tr, -sign * (out[4] or 0), out[5])}))
		if out[5] then table.insert(PageTweens, Tween(Zoom(old), ti, {Scale = out[5]})) end
		local veil = TweenService:Create(W.Fader, ti, {BackgroundTransparency = 0})
		table.insert(PageTweens, veil)
		veil.Completed:Connect(function(state)
			if state ~= Enum.PlaybackState.Completed or token ~= SwitchToken or not W.Alive then return end
			Swap(true)
		end)
		veil:Play()
	end

	function W.RefreshAccentIcons()
		for _, ic in ipairs(W.AccentIcons) do
			ic.ImageColor3 = W.Accent
			ic.ImageTransparency = 1 - W.AccentAlpha
		end
	end

	local Sub = {tab = nil, count = 0, items = {}}
	local SUB_TI = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local SUB_GAP = 5

	local function SubWidth(it)
		local w = it.label.TextBounds.X
		if w <= 0 then w = TextWidth(it.sub.Name, TEXT) end
		return math.floor(it.textX + w + 8 + 0.5)
	end

	local function LayoutSubs(animate)
		local tab, T = Sub.tab, W.Theme
		local right, activeX, activeW = 0, nil, nil
		for i = #Sub.items, 1, -1 do
			local it = Sub.items[i]
			local active = tab ~= nil and it.sub == tab.CurSub
			local w = active and SubWidth(it) or 26
			local x = -(right + w)
			right = right + w + SUB_GAP
			if active then activeX, activeW = x, w end
			local props = {Position = UDim2.fromOffset(x, 0), Size = UDim2.fromOffset(w, 26)}
			local iconProps = it.icon and {
				ImageColor3 = active and W.Accent or T.NavGray,
				ImageTransparency = active and (1 - W.AccentAlpha) or 0,
			}
			if animate then
				Tween(it.btn, SUB_TI, props)
				Tween(it.label, SUB_TI, {TextTransparency = active and 0 or 1})
				if it.letter then Tween(it.letter, SUB_TI, {TextTransparency = active and 1 or 0}) end
				if iconProps then Tween(it.icon, SUB_TI, iconProps) end
			else
				StopTweens(it.btn, it.label, it.letter, it.icon)
				it.btn.Position, it.btn.Size = props.Position, props.Size
				it.label.TextTransparency = active and 0 or 1
				if it.letter then it.letter.TextTransparency = active and 1 or 0 end
				if iconProps then it.icon.ImageColor3, it.icon.ImageTransparency = iconProps.ImageColor3, iconProps.ImageTransparency end
			end
			it.label.TextColor3 = T.Text
			if it.letter then it.letter.TextColor3 = T.NavGray end
		end
		local ind = W.SubIndicator
		if not activeX then
			ind.BackgroundTransparency = 1
			return
		end
		local props = {Position = UDim2.fromOffset(activeX, 0), Size = UDim2.fromOffset(activeW, 26), BackgroundTransparency = 0}
		if animate and ind.BackgroundTransparency < 1 then
			Tween(ind, SUB_TI, props)
		else
			StopTweens(ind)
			ind.Position, ind.Size, ind.BackgroundTransparency = props.Position, props.Size, 0
		end
	end

	local function ClearSubs()
		for _, it in ipairs(Sub.items) do it.btn:Destroy() end
		table.clear(Sub.items)
		Sub.tab, Sub.count = nil, 0
		W.SubIndicator.BackgroundTransparency = 1
		W.Prune()
	end

	function W.BuildSubTabs(instant)
		local tab = W.Nav.main
		if type(tab) ~= "table" or #tab.Subs == 0 then
			if Sub.tab then ClearSubs() end
			return
		end
		local fresh = Sub.tab ~= tab or Sub.count ~= #tab.Subs
		if fresh then
			ClearSubs()
			Sub.tab, Sub.count = tab, #tab.Subs
			for i, sub in ipairs(tab.Subs) do
				local b = Create("TextButton", {
					Size = UDim2.fromOffset(26, 26),
					BackgroundTransparency = 1,
					ClipsDescendants = true,
					Text = "",
					AutoButtonColor = false,
					ZIndex = 2,
					LayoutOrder = i,
					Parent = W.SubHolder,
				})
				local it = {sub = sub, btn = b, textX = 7}
				if sub.Icon then
					it.icon = CreateIcon(b, sub.Icon, 12, UDim2.fromOffset(7, 7), W.Theme.NavGray)
					it.textX = 25
				else
					it.letter = Label(b, tostring(sub.Name):sub(1, 1), {Size = UDim2.fromOffset(26, 26), Align = Enum.TextXAlignment.Center, Weight = "SemiBold"})
				end
				it.label = Label(b, sub.Name, {Position = UDim2.fromOffset(it.textX, 0), AutoX = true, Size = UDim2.new(0, 0, 1, 0)})
				it.label:GetPropertyChangedSignal("TextBounds"):Connect(function()
					if Sub.tab == tab and tab.CurSub == sub then LayoutSubs(false) end
				end)
				b.MouseButton1Click:Connect(function()
					if tab.CurSub ~= sub then W.Navigate(tab, sub) end
				end)
				table.insert(Sub.items, it)
			end
		end
		LayoutSubs((not instant) and not fresh)
	end

	W.Bind(function() LayoutSubs(false) end)

	function W.RefreshNav(instant)
		if not W.Alive then return end
		W.ClosePopup()
		table.clear(W.AccentIcons)
		local T = W.Theme

		local page = W.PageFor()
		if page ~= W.CurrentPage then
			W.ShowPage(page, W.CurrentPage ~= nil and not instant)
			W.CurrentPage = page
		end

		for _, t in ipairs(W.Tabs) do
			local active = W.Nav.main == t
			local tileProps = {BackgroundTransparency = active and 0 or 1, Size = active and t.TileOn or t.TileOff}
			local lblProps = {TextColor3 = active and T.Text or T.NavGray}
			if instant then
				StopTweens(t.Tile, t.Label)
				t.Tile.BackgroundTransparency, t.Tile.Size = tileProps.BackgroundTransparency, tileProps.Size
				t.Label.TextColor3 = lblProps.TextColor3
			else
				Tween(t.Tile, TI_FAST, tileProps)
				Tween(t.Label, TI_FAST, lblProps)
			end
			t.Icon.ImageColor3 = T.NavGray
			t.Icon.ImageTransparency = 0
			if active then table.insert(W.AccentIcons, t.Icon) end
		end

		local gearActive = W.Nav.main == "settings"
		if instant then
			StopTweens(W.SetBtn)
			W.SetBtn.BackgroundTransparency = gearActive and 0 or 1
		else
			Tween(W.SetBtn, TI_FAST, {BackgroundTransparency = gearActive and 0 or 1})
		end
		W.GearIcon.ImageColor3 = T.NavGray
		W.GearIcon.ImageTransparency = 0
		if gearActive then table.insert(W.AccentIcons, W.GearIcon) end

		if W.CfgBtn then
			local cfgActive = W.Nav.main == "configs"
			if instant then
				StopTweens(W.CfgBtn)
				W.CfgBtn.BackgroundTransparency = cfgActive and 0 or 1
			else
				Tween(W.CfgBtn, TI_FAST, {BackgroundTransparency = cfgActive and 0 or 1})
			end
			W.CfgIcon.ImageColor3 = T.NavGray
			W.CfgIcon.ImageTransparency = 0
			if cfgActive then table.insert(W.AccentIcons, W.CfgIcon) end
		end

		W.BuildSubTabs(instant)
		W.RefreshAccentIcons()
	end

	function W.Navigate(main, sub)
		W.Nav.main = main
		if sub then main.CurSub = sub end
		W.Navigated = true
		W.RefreshNav()
	end

	W.Bind(function(T)
		for _, t in ipairs(W.Tabs) do
			StopTweens(t.Label)
			t.Label.TextColor3 = (W.Nav.main == t) and T.Text or T.NavGray
		end
		W.RefreshAccentIcons()
	end)

	W.SetBtn.MouseButton1Click:Connect(function() W.Navigate("settings") end)
end

local function AddTab(W, o)
	o = Opts(o)
	local tab = {Name = o.Name or o.Title or ("Tab " .. (#W.Tabs + 1)), Subs = {}}
	tab.Page = NewPage(W)

	local btn = Create("TextButton", {
		Size = UDim2.new(0, 102, 1, 0),
		BackgroundTransparency = 1,
		Text = "",
		LayoutOrder = #W.Tabs + 1,
		Parent = W.NavHolder,
	})
	local tile = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(80, 23),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = btn,
	})
	W.Paint(tile, "BackgroundColor3", "TileBg")
	Corner(tile, 2)
	local content = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 0, 0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Parent = btn,
	})
	Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 5),
		Parent = content,
	})
	local ic = Create("ImageLabel", {Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 1, LayoutOrder = 1, Parent = content})
	ic.Visible = ApplyIcon(ic, o.Icon)
	local lbl = Label(content, tab.Name, {AutoX = true, Size = UDim2.new(0, 0, 1, 0), Color = W.Theme.NavGray})
	lbl.LayoutOrder = 2
	tab.Button, tab.Tile, tab.Icon, tab.Label = btn, tile, ic, lbl
	W.NavIcon(ic)

	table.insert(W.Tabs, tab)
	W.RelayoutNav()

	btn.MouseButton1Click:Connect(function() W.Navigate(tab) end)

	local api = {Name = tab.Name}
	AttachSections(W, api, tab.Page)
	Method(api, "Select", function() W.Navigate(tab) end)
	Method(api, "SetName", function(t)
		tab.Name = tostring(t)
		api.Name = tab.Name
		lbl.Text = tab.Name
	end)
	Method(api, "SetIcon", function(spec) ic.Visible = ApplyIcon(ic, spec) end)
	Method(api, "AddSubTab", function(so)
		so = Opts(so)
		local sub = {Name = so.Name or so.Title or ("Page " .. (#tab.Subs + 1)), Icon = so.Icon}
		sub.Page = NewPage(W)
		table.insert(tab.Subs, sub)
		if not tab.CurSub or so.Default then tab.CurSub = sub end
		if W.Nav.main == tab then W.RefreshNav(true) end
		local sapi = {Name = sub.Name}
		AttachSections(W, sapi, sub.Page)
		Method(sapi, "Select", function() W.Navigate(tab, sub) end)
		return sapi
	end)
	api.SubTab = api.AddSubTab
	api.AddPage = api.AddSubTab
	api.CreateSubTab = api.AddSubTab

	if o.Default or (not W.Navigated and #W.Tabs == 1) then
		W.Nav.main = tab
	end
	W.RefreshNav(true)
	return api
end

local function BuildSettings(W, o)
	local page = NewPage(W)
	W.SettingsPage = page
	local api = AttachSections(W, {}, page)
	W.SettingsApi = api

	local appearance = NewSection(W, page, {Name = "Appearance", Side = "Left"})
	W.ThemeDropdown = appearance.AddDropdown({
		Name = "Theme", Icon = "moon",
		Options = CopyList(Library.ThemeOrder), Default = W.ThemeName,
		Flag = "__ZeninTheme",
		Callback = function(v) W.SetTheme(v) end,
	})
	AccentPicker(W, appearance, "Accent Color")

	local interface = NewSection(W, page, {Name = "Interface", Side = "Left"})
	W.ScaleDropdown = interface.AddDropdown({
		Name = "UI Scale", Icon = {"expand", "maximize-2"},
		Options = SCALE_OPTIONS, Default = ScaleLabelFor(o.Scale),
		Flag = "__ZeninScale",
		Callback = function(v) W.SetScale(SCALE_MAP[v] or 1, true) end,
	})
	W.TransitionDropdown = interface.AddDropdown({
		Name = "Tab Animation", Icon = {"layers", "square-stack"},
		Options = (function()
			local names = {}
			for i, t in ipairs(PAGE_TRANSITIONS) do names[i] = t.Name end
			return names
		end)(),
		Default = W.GetTransition(),
		Flag = "__ZeninTransition",
		Callback = function(v) W.SetTransition(v) end,
	})
	W.ScrollSlider = interface.AddSlider({
		Name = "Scrollbar Size", Min = 3, Max = 24, Default = W.BarW, Suffix = "px",
		Flag = "__ZeninScrollbar",
		Callback = function(v) W.SetBarWidth(v) end,
	})

	local wm = NewSection(W, page, {Name = "Watermark", Side = "Right"})
	W.WmOpacity = wm.AddSlider({
		Name = "Opacity", Min = 0, Max = 100, Default = 100, Suffix = "%",
		Flag = "__ZeninWmOpacity",
		Callback = function(v)
			W.WM.Opacity = v / 100
			W.WM.ApplyOpacity()
		end,
	})
	W.WmIcons = wm.AddToggle({
		Name = "Show Icons", Default = true,
		Flag = "__ZeninWmIcons",
		Callback = function(v) W.WM.SetIconsVisible(v) end,
	})
	W.WmDetails = wm.AddMultiDropdown({
		Name = "Details", Options = DETAIL_MODES, Default = W.WM.GetModes(),
		Flag = "__ZeninWmDetails",
		Callback = function(v) W.WM.SetModes(v) end,
	})

	if W.KBList then
		local kl = NewSection(W, page, {Name = "Keybind List", Side = "Right"})
		W.KbListToggle = kl.AddToggle({
			Name = "Show List", Default = W.KBList.Wanted,
			Flag = "__ZeninKbList",
			Callback = function(v) W.KeybindListApi.SetVisible(v) end,
		})
		W.KbInactiveToggle = kl.AddToggle({
			Name = "Show Inactive", Default = W.KBList.ShowInactive,
			Flag = "__ZeninKbInactive",
			Callback = function(v) W.KeybindListApi.SetShowInactive(v) end,
		})
	end
	return api
end

local function Trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function EnsureFolderPath(folder)
	if not (isfolder and makefolder) then return end
	local cur = ""
	for part in string.gmatch(tostring(folder), "[^/\\]+") do
		cur = cur == "" and part or (cur .. "/" .. part)
		local ok, exists = pcall(isfolder, cur)
		if not (ok and exists) then pcall(makefolder, cur) end
	end
end

local function BuildConfigManager(W, Window, o)
	local CFG = {
		Folder = o.ConfigFolder or Library.ConfigFolder,
		Interface = true,
		Ignore = {},
		Extra = {},
		SaveHooks = {},
		LoadHooks = {},
		Active = nil,
	}
	local api = {}

	local function Clean(name)
		name = Trim(name or "default"):gsub("%.cfg$", "")
		name = name:gsub("[^%w%-_ %.]", "_")
		if name == "" then name = "default" end
		return name
	end

	local function EnsureFolder()
		local f = CFG.Folder
		if f == nil or f == "" then return nil end
		EnsureFolderPath(f)
		return f
	end

	local function Path(name)
		local f = EnsureFolder()
		local file = Clean(name) .. ".cfg"
		return f and (f .. "/" .. file) or file
	end

	local function AutoLoadPath()
		local f = EnsureFolder()
		return f and (f .. "/autoload.txt") or "zenin_autoload.txt"
	end

	local function Exists(path)
		if not isfile then return false end
		local ok, res = pcall(isfile, path)
		return ok and res == true
	end

	local function ReadFile(path)
		if not (readfile and Exists(path)) then return nil end
		local ok, res = pcall(readfile, path)
		if ok and type(res) == "string" then return res end
		return nil
	end

	local function WriteFile(path, text)
		if not writefile then return false, "writefile unsupported" end
		local ok, err = pcall(writefile, path, text)
		if ok then return true end
		return false, tostring(err)
	end

	local function Included(flag)
		if CFG.Ignore[flag] then return false end
		if not CFG.Interface and flag:sub(1, 7) == "__Zenin" then return false end
		return true
	end

	local function Refresh()
		if W.RefreshConfigs then W.RefreshConfigs() end
	end

	local function Snapshot()
		local data = {Format = "Zenin", Flags = {}, Data = {}}
		if CFG.Interface then
			data.Accent = ToHex(W.Accent)
			data.AccentAlpha = W.AccentAlpha
		end
		for _, el in ipairs(W.Elements) do
			if el.Flag and el.Get and Included(el.Flag) then
				local ok, v = pcall(SerializeFlag, el)
				if ok then data.Flags[el.Flag] = v end
			end
		end
		for key, x in pairs(CFG.Extra) do
			local ok, v = pcall(x.get)
			if ok and v ~= nil then data.Data[key] = v end
		end
		for _, fn in ipairs(CFG.SaveHooks) do SafeCall(fn, data) end
		return data
	end

	local function Apply(data)
		if type(data) ~= "table" then return false, "invalid config" end
		if CFG.Interface then
			local c = FromHex(data.Accent)
			if c then W.SetAccentExternal(c, data.AccentAlpha) end
		end
		local pending = {}
		local flags = type(data.Flags) == "table" and data.Flags or {}
		for flag, v in pairs(flags) do
			if type(flag) == "string" and Included(flag) then
				local el = Library.Options[flag]
				if el and el._win == W then
					ApplyFlag(el, v)
				else
					pending[flag] = v
				end
			end
		end
		W.PendingFlags = pending
		local extra = type(data.Data) == "table" and data.Data or {}
		for key, x in pairs(CFG.Extra) do
			if extra[key] ~= nil then SafeCall(x.set, extra[key]) end
		end
		for _, fn in ipairs(CFG.LoadHooks) do SafeCall(fn, data) end
		return true
	end

	local function Encode(data)
		local ok, json = pcall(HttpService.JSONEncode, HttpService, data)
		if not ok then return nil, "encode failed" end
		return json
	end

	local function Decode(text)
		if type(text) ~= "string" then return nil, "empty" end
		text = Trim(text)
		if text == "" then return nil, "empty" end
		local ok, data = pcall(HttpService.JSONDecode, HttpService, text)
		if not ok or type(data) ~= "table" then return nil, "invalid config" end
		return data
	end

	Method(api, "Configure", function(co)
		co = co or {}
		if co.Folder ~= nil then CFG.Folder = co.Folder ~= "" and co.Folder or nil end
		if co.Interface ~= nil then CFG.Interface = co.Interface ~= false end
		if type(co.Ignore) == "table" then
			for _, f in ipairs(co.Ignore) do CFG.Ignore[f] = true end
		end
		Refresh()
	end)

	Method(api, "Save", function(name)
		name = Clean(name)
		local text, err = Encode(Snapshot())
		if not text then return false, err end
		local ok, werr = WriteFile(Path(name), text)
		if not ok then return false, werr end
		CFG.Active = name
		Refresh()
		return true
	end)

	Method(api, "Load", function(name)
		name = Clean(name)
		if not readfile then return false, "readfile unsupported" end
		local text = ReadFile(Path(name))
		if not text then return false, "not found" end
		local data, err = Decode(text)
		if not data then return false, err end
		local ok, aerr = Apply(data)
		if not ok then return false, aerr end
		CFG.Active = name
		Refresh()
		return true
	end)

	Method(api, "Delete", function(name)
		name = Clean(name)
		local path = Path(name)
		if not (delfile and Exists(path)) then return false, "not found" end
		if not pcall(delfile, path) then return false, "delete failed" end
		if CFG.Active == name then CFG.Active = nil end
		if api.GetAutoLoad() == name then api.SetAutoLoad(nil) end
		Refresh()
		return true
	end)

	Method(api, "Exists", function(name) return Exists(Path(name)) end)

	Method(api, "Rename", function(old, new)
		old, new = Clean(old), Clean(new)
		if old == new then return true end
		if not delfile then return false, "delfile unsupported" end
		if Exists(Path(new)) then return false, "already exists" end
		local text = ReadFile(Path(old))
		if not text then return false, "not found" end
		local ok, err = WriteFile(Path(new), text)
		if not ok then return false, err end
		pcall(delfile, Path(old))
		if CFG.Active == old then CFG.Active = new end
		if api.GetAutoLoad() == old then api.SetAutoLoad(new) end
		Refresh()
		return true
	end)

	Method(api, "Duplicate", function(name, new)
		name = Clean(name)
		new = Clean(new or api.UniqueName(name))
		local text = ReadFile(Path(name))
		if not text then return false, "not found" end
		if Exists(Path(new)) then return false, "already exists" end
		local ok, err = WriteFile(Path(new), text)
		Refresh()
		return ok, err
	end)

	Method(api, "List", function()
		local out = {}
		if not listfiles then return out end
		local files
		local f = EnsureFolder()
		for _, dir in ipairs(f and {f} or {"", ".", "./"}) do
			local ok, res = pcall(listfiles, dir)
			if ok and type(res) == "table" then
				files = res
				break
			end
		end
		if not files then return out end
		local seen = {}
		for _, file in ipairs(files) do
			local n = tostring(file):match("([^/\\]+)%.cfg$")
			if n and Clean(n) == n and not seen[n] then
				seen[n] = true
				table.insert(out, n)
			end
		end
		table.sort(out)
		return out
	end)

	Method(api, "UniqueName", function(base)
		base = Clean(base or "config")
		if not Exists(Path(base)) then return base end
		local k = 1
		while Exists(Path(base .. "-" .. k)) do k = k + 1 end
		return base .. "-" .. k
	end)

	Method(api, "Get", Snapshot)
	Method(api, "Apply", function(data)
		local ok, err = Apply(data)
		Refresh()
		return ok, err
	end)

	Method(api, "Reset", function()
		for _, el in ipairs(W.Elements) do
			if el.Flag and el._default ~= nil and el.Flag:sub(1, 7) ~= "__Zenin" and not CFG.Ignore[el.Flag] then
				if el._reset then SafeCall(el._reset) else ApplyFlag(el, el._default) end
			end
		end
		W.PendingFlags = nil
		CFG.Active = nil
		Refresh()
	end)

	Method(api, "SetAutoLoad", function(name)
		local path = AutoLoadPath()
		if name == nil or name == false then
			if delfile and Exists(path) then pcall(delfile, path) end
		else
			WriteFile(path, Clean(name))
		end
		Refresh()
	end)
	Method(api, "GetAutoLoad", function()
		local text = ReadFile(AutoLoadPath())
		if not text or text == "" then return nil end
		return Clean(text)
	end)
	Method(api, "LoadAutoLoad", function()
		local name = api.GetAutoLoad()
		if not name then return false, "no autoload" end
		return api.Load(name)
	end)

	Method(api, "SetFolder", function(folder) api.Configure({Folder = folder or ""}) end)
	Method(api, "GetFolder", function() return CFG.Folder end)
	Method(api, "Ignore", function(...)
		for _, f in ipairs({...}) do CFG.Ignore[f] = true end
	end)
	Method(api, "Unignore", function(...)
		for _, f in ipairs({...}) do CFG.Ignore[f] = nil end
	end)
	Method(api, "Register", function(key, get, set)
		CFG.Extra[key] = {get = get, set = set}
	end)
	Method(api, "OnSave", function(fn) table.insert(CFG.SaveHooks, fn) end)
	Method(api, "OnLoad", function(fn) table.insert(CFG.LoadHooks, fn) end)
	Method(api, "GetActive", function() return CFG.Active end)
	Method(api, "Path", function(name) return Path(name) end)
	Method(api, "Open", function() Window.SelectConfigs() end)
	Method(api, "Refresh", Refresh)

	if type(o.Configs) == "table" then api.Configure(o.Configs) end
	return api
end

local function BuildConfigs(W, Window)
	local Configs = Window.Configs
	local page = NewPage(W, true)
	W.ConfigPage = page
	local api = AttachSections(W, {}, page)

	local btn = Create("TextButton", {
		Size = UDim2.fromOffset(26, 27),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = W.Header,
	})
	W.Paint(btn, "BackgroundColor3", "TileBg")
	Corner(btn, 2)
	W.CfgBtn = btn
	W.CfgIcon = CreateIcon(btn, {"file-text", "file"}, 12, UDim2.new(0.5, -6, 0.5, -6))
	W.NavIcon(W.CfgIcon)
	btn.MouseButton1Click:Connect(function() Window.SelectConfigs() end)
	W.LayoutHeader()

	local function Note(text)
		Window.Notify({Title = "Configs", Content = text, Icon = {"file-text", "file"}, Duration = 2.5})
	end
	local function Result(ok, err, success, fail)
		Note(ok and success or (fail .. ": " .. tostring(err)))
	end

	local actions = NewSection(W, page, {Name = "Actions"})
	local box = Create("TextBox", {
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = "Name (optional)",
		ClearTextOnFocus = false,
		TextSize = TEXT,
		Weight = "Medium",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = actions._raw(25),
	})
	Corner(box, 3)
	AttachKeyboard(box, W)
	local boxStroke = Stroke(box, WHITE, 1)
	Create("UIPadding", {PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9), Parent = box})
	W.Bind(function(T)
		box.BackgroundColor3 = T.DropdownBg
		boxStroke.Color = T.DropdownBorder
		box.TextColor3 = T.Text
		box.PlaceholderColor3 = T.TextDim
	end, box)

	local function WideButton(parent, text, icon, fn)
		local b = Create("TextButton", {Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Text = "", AutoButtonColor = false, Parent = parent})
		Corner(b, 3)
		local st = Stroke(b, WHITE, 1)
		local content = Create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, 0, 0, 16),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Parent = b,
		})
		Create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 5),
			Parent = content,
		})
		local ic = Create("ImageLabel", {Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 1, LayoutOrder = 1, Parent = content})
		ApplyIcon(ic, icon)
		local lb = Label(content, text, {AutoX = true, Size = UDim2.new(0, 0, 1, 0)})
		lb.LayoutOrder = 2
		local hover, pressed = false, false
		local function Paint(animate)
			local T = W.Theme
			local bg = pressed and T.TileHover:Lerp(T.Text, 0.06) or (hover and T.TileHover or T.DropdownBg)
			local fg = hover and T.Text or T.TextGray
			Anim(b, {BackgroundColor3 = bg}, animate)
			Anim(st, {Color = hover and T.DropdownBorder:Lerp(T.Text, 0.12) or T.DropdownBorder}, animate)
			Anim(lb, {TextColor3 = fg}, animate)
			Anim(ic, {ImageColor3 = fg}, animate)
		end
		W.Bind(function() Paint(false) end, b)
		OnMouseEnter(b, function() hover = true Paint(true) end)
		b.MouseLeave:Connect(function() hover = false pressed = false Paint(true) end)
		b.InputBegan:Connect(function(i) if IsClickOrTouch(i) then pressed = true Paint(true) end end)
		b.InputEnded:Connect(function(i) if IsClickOrTouch(i) then pressed = false Paint(true) end end)
		b.MouseButton1Click:Connect(fn)
		return b
	end

	local list = NewSection(W, page, {Name = "Config List"})
	local activeLbl = Label(list._raw(16), "Active: None", {Truncate = true})
	W.Paint(activeLbl, "TextColor3", "TextGray")
	local holder = list._raw(0)
	Create("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = holder})

	local function IconButton(parent, x, icon, onClick, isOn)
		local b = Create("TextButton", {
			Size = UDim2.fromOffset(24, 24),
			Position = UDim2.new(1, x, 0.5, -12),
			BackgroundTransparency = 1,
			Text = "",
			Parent = parent,
		})
		local ic = CreateIcon(b, icon, 12, UDim2.new(0.5, -6, 0.5, -6))
		local hover = false
		local icScale = Create("UIScale", {Parent = ic})
		local function Paint(animate)
			local T = W.Theme
			local c = (isOn and isOn()) and W.Accent or (hover and T.Text or T.NavGray)
			Anim(ic, {ImageColor3 = c}, animate)
			Anim(icScale, {Scale = hover and 1.12 or 1}, animate, MOVE_TI)
		end
		W.Bind(function() Paint(false) end, b)
		OnMouseEnter(b, function() hover = true Paint(true) end)
		b.MouseLeave:Connect(function() hover = false Paint(true) end)
		b.MouseButton1Click:Connect(function()
			SoftPress(ic)
			onClick()
		end)
		return b
	end

	local autoName
	local function Item(i, name)
		local row = Create("Frame", {Size = UDim2.new(1, 0, 0, 45), BorderSizePixel = 0, LayoutOrder = i, Parent = holder})
		Corner(row, 3)
		W.Paint(row, "BackgroundColor3", "DropdownBg")
		local title = Label(row, name .. ".cfg", {Position = UDim2.fromOffset(14, 7), Size = UDim2.new(1, -120, 0, 16), Weight = "SemiBold", Truncate = true})
		local info = tostring(i)
		if autoName == name then info = info .. "  ·  autoload" end
		local idx = Label(row, info, {Position = UDim2.fromOffset(14, 24), Size = UDim2.new(1, -120, 0, 14), TextSize = 10})
		W.Bind(function(T, accent)
			title.TextColor3 = (Configs.GetActive() == name) and accent or T.Text
			idx.TextColor3 = T.TextDim
		end, row)

		IconButton(row, -92, {"download", "import"}, function()
			local ok, err = Configs.Load(name)
			Result(ok, err, "Loaded " .. name .. ".cfg", "Load failed")
		end)
		IconButton(row, -64, {"save"}, function()
			local ok, err = Configs.Save(name)
			Result(ok, err, "Saved " .. name .. ".cfg", "Save failed")
		end)
		IconButton(row, -36, {"trash-2", "trash"}, function()
			local ok, err = Configs.Delete(name)
			Result(ok, err, "Deleted " .. name .. ".cfg", "Delete failed")
		end)
	end

	local function Refresh()
		for _, ch in ipairs(holder:GetChildren()) do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		W.Prune()
		autoName = Configs.GetAutoLoad()
		local names = Configs.List()
		if #names == 0 then
			local empty = Label(holder, "No configs yet", {Size = UDim2.new(1, 0, 0, 20)})
			W.Paint(empty, "TextColor3", "TextDim")
			holder.Size = UDim2.new(1, 0, 0, 20)
		else
			for i, name in ipairs(names) do Item(i, name) end
			holder.Size = UDim2.new(1, 0, 0, #names * 45 + (#names - 1) * 5)
		end
		local active = Configs.GetActive()
		local text = "Active: " .. (active and (active .. ".cfg") or "None")
		if autoName then text = text .. "   Autoload: " .. autoName .. ".cfg" end
		activeLbl.Text = text
	end

	WideButton(actions._raw(27), "Create New", {"file-plus", "file"}, function()
		local name = Trim(box.Text)
		if name == "" or #name > 64 then name = "config_" .. (#Configs.List() + 1) end
		name = Configs.UniqueName(name)
		local ok, err = Configs.Save(name)
		if ok then box.Text = "" end
		Result(ok, err, "Created " .. name .. ".cfg", "Create failed")
	end)
	WideButton(actions._raw(27), "Refresh List", {"refresh-cw"}, function()
		Refresh()
	end)

	Refresh()
	W.RefreshConfigs = Refresh
	return api
end

local GetHwid, Now, FormatDuration, Sha256, KeyBackend, RunKeySystem
do -- key system
function GetHwid()
	if type(gethwid) == "function" then
		local ok, r = pcall(gethwid)
		if ok and r then return tostring(r) end
	end
	local ok, r = pcall(function() return game:GetService("RbxAnalyticsService"):GetClientId() end)
	if ok and r then return tostring(r) end
	return tostring(LocalPlayer and LocalPlayer.UserId or "")
end

local function HttpGetBody(url)
	local req = (syn and syn.request) or (http and http.request) or http_request or request
	if req then
		local ok, r = pcall(req, {Url = url, Method = "GET"})
		if ok and type(r) == "table" and type(r.Body) == "string" then return r.Body, r.StatusCode end
	end
	local ok, r = pcall(function() return game:HttpGet(url) end)
	if ok and type(r) == "string" then return r, 200 end
	return nil, nil
end

local function BodyIsValid(body)
	local trimmed = Trim(body)
	local low = trimmed:lower()
	if low == "true" or low == "valid" or low == "ok" or low == "1" or low == "success" then return true end
	local ok, data = pcall(function() return HttpService:JSONDecode(trimmed) end)
	if ok and type(data) == "table" then
		local exp = data.expires or data.expiresAt or data.expires_at or data.expiry or data.expire or data.Expires
		if data.valid == true or data.success == true or data.Valid == true or data.Success == true then return true, nil, exp end
		return false, data.message or data.Message or data.error
	end
	return false
end

function Now() return os.time() end

-- Unix seconds; millisecond timestamps are converted.
local function ParseExpiry(v)
	v = tonumber(v)
	if not v or v ~= v or v <= 0 then return nil end
	if v > 1e12 then v = v / 1000 end
	return math.floor(v)
end

function FormatDuration(sec)
	sec = math.max(0, math.floor(tonumber(sec) or 0))
	local d = math.floor(sec / 86400)
	local h = math.floor(sec % 86400 / 3600)
	local m = math.floor(sec % 3600 / 60)
	local s = sec % 60
	if d > 0 then return ("%dd %dh"):format(d, h) end
	if h > 0 then return ("%dh %02dm"):format(h, m) end
	if m > 0 then return ("%dm %02ds"):format(m, s) end
	return ("%ds"):format(s)
end

-- SHA-256, so key lists can ship as hashes instead of plain text and the saved-key file can be signed.
do
	local band, bxor, bnot, rrot, rshift = bit32.band, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift
	local K = {
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	}
	local MOD = 4294967296
	function Sha256(msg)
		msg = tostring(msg)
		local len = #msg
		msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. string.pack(">I8", len * 8)
		local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
		local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
		local w = table.create(64, 0)
		for chunk = 1, #msg, 64 do
			for i = 0, 15 do
				w[i] = string.unpack(">I4", msg, chunk + i * 4)
			end
			for i = 16, 63 do
				local v15, v2 = w[i - 15], w[i - 2]
				local s0 = bxor(rrot(v15, 7), rrot(v15, 18), rshift(v15, 3))
				local s1 = bxor(rrot(v2, 17), rrot(v2, 19), rshift(v2, 10))
				w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
			end
			local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
			for i = 0, 63 do
				local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
				local ch = bxor(band(e, f), band(bnot(e), g))
				local t1 = (h + S1 + ch + K[i + 1] + w[i]) % MOD
				local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
				local maj = bxor(band(a, b), band(a, c), band(b, c))
				local t2 = (S0 + maj) % MOD
				h, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
			end
			h0, h1, h2, h3 = (h0 + a) % MOD, (h1 + b) % MOD, (h2 + c) % MOD, (h3 + d) % MOD
			h4, h5, h6, h7 = (h4 + e) % MOD, (h5 + f) % MOD, (h6 + g) % MOD, (h7 + h) % MOD
		end
		return ("%08x%08x%08x%08x%08x%08x%08x%08x"):format(h0, h1, h2, h3, h4, h5, h6, h7)
	end
end

-- Key list values: true (never expires), a unix expiry, or a table
-- {Expires = unix, Duration = seconds from first use, Hwid = "..." | Hwids = {...}, Users = {userId | name},
--  Note = "...", Disabled = bool}. Array entries may also be {Key = "...", ...}.
local function NormKeySpec(v)
	if v == true then return {} end
	if type(v) == "number" then return {Expires = v} end
	if type(v) == "table" then
		local hw = v.Hwids or v.Hwid or v.hwid
		if type(hw) == "string" then hw = {hw} end
		local users = v.Users or v.UserIds or v.User or v.UserId
		if users ~= nil and type(users) ~= "table" then users = {users} end
		return {
			Expires = v.Expires or v.expires,
			Duration = tonumber(v.Duration or v.duration),
			Note = v.Note or v.note,
			Disabled = v.Disabled == true or v.disabled == true,
			Hwids = type(hw) == "table" and hw or nil,
			Users = type(users) == "table" and users or nil,
		}
	end
	return nil
end

-- Verification + saved-key storage, shared by the first prompt and later re-checks.
function KeyBackend(ks, ctx)
	local B = {}
	local caseSensitive = ks.CaseSensitive ~= false

	local function Norm(key)
		key = Trim(key)
		if ks.StripSpaces == true then key = key:gsub("%s+", "") end
		if not caseSensitive then key = key:lower() end
		if type(ks.Normalize) == "function" then
			local ok, r = pcall(ks.Normalize, key)
			if ok and type(r) == "string" then key = r end
		end
		return key
	end
	B.Normalize = Norm

	local staticKeys, hashes = {}, {}
	local keyList = ks.Keys or ks.Key
	if type(keyList) == "string" then keyList = {keyList} end
	for k, v in pairs(type(keyList) == "table" and keyList or {}) do
		if type(k) == "number" then
			if type(v) == "table" then
				if v.Key ~= nil then staticKeys[Norm(v.Key)] = NormKeySpec(v) end
			else
				staticKeys[Norm(v)] = {}
			end
		else
			local spec = NormKeySpec(v)
			if spec then staticKeys[Norm(k)] = spec end
		end
	end
	local hashList = ks.Hashes or ks.Hash
	if type(hashList) == "string" then hashList = {hashList} end
	for k, v in pairs(type(hashList) == "table" and hashList or {}) do
		if type(k) == "number" then
			if type(v) == "table" then
				if v.Hash ~= nil then hashes[Trim(v.Hash):lower()] = NormKeySpec(v) end
			else
				hashes[Trim(v):lower()] = {}
			end
		else
			local spec = NormKeySpec(v)
			if spec then hashes[Trim(k):lower()] = spec end
		end
	end

	local hwid = GetHwid()
	B.Hwid = hwid
	local userId = LocalPlayer and LocalPlayer.UserId or 0
	local userName = LocalPlayer and LocalPlayer.Name or ""
	local hasRemote = (type(ks.Url) == "string" and ks.Url ~= "") or type(ks.Verify) == "function"

	-- Lists may mix user ids, usernames and HWIDs.
	local function InList(list)
		if type(list) ~= "table" then return false end
		for _, v in ipairs(list) do
			local s = tostring(v)
			if s == tostring(userId) or s == userName or s == hwid then return true end
		end
		return false
	end
	function B.Whitelisted() return InList(ks.Whitelist) end
	function B.Blacklisted() return InList(ks.Blacklist) end

	local function CheckSpec(spec, source)
		if spec.Disabled then return false, ks.DisabledMessage or "This key has been disabled", nil, true end
		if spec.Hwids and #spec.Hwids > 0 then
			local okHw = false
			for _, h in ipairs(spec.Hwids) do
				if tostring(h) == hwid then okHw = true break end
			end
			if not okHw then return false, ks.HwidMessage or "This key is locked to another device", nil, true end
		end
		if spec.Users and #spec.Users > 0 and not InList(spec.Users) then
			return false, ks.UserMessage or "This key belongs to another account", nil, true
		end
		return true, nil, ParseExpiry(spec.Expires), true, {Source = source, Note = spec.Note, Duration = spec.Duration}
	end

	-- Returns valid, message, expires, definitive (false when the server simply couldn't be reached), meta.
	local function Check(key)
		if B.Whitelisted() then return true, nil, nil, true, {Source = "whitelist"} end
		if B.Blacklisted() then return false, ks.BlacklistMessage or "You are not allowed to use this", nil, true end
		if key == "" then return false, "Enter a key", nil, true end
		local minLen, maxLen = tonumber(ks.MinLength), tonumber(ks.MaxLength)
		if (minLen and #key < minLen) or (maxLen and #key > maxLen)
			or (type(ks.Pattern) == "string" and not key:match(ks.Pattern)) then
			return false, ks.FormatMessage or "Invalid key format", nil, true
		end
		local st = staticKeys[key]
		if st then return CheckSpec(st, "static") end
		if next(hashes) then
			local hs = hashes[Sha256(key)]
			if hs then return CheckSpec(hs, "hash") end
		end
		local lastMsg, reached = nil, not hasRemote
		if type(ks.Url) == "string" and ks.Url ~= "" then
			local url = ks.Url:gsub("{key}", function() return HttpService:UrlEncode(key) end)
				:gsub("{hwid}", function() return HttpService:UrlEncode(hwid) end)
				:gsub("{userid}", function() return tostring(userId) end)
			local body, code = HttpGetBody(url)
			if body then
				reached = true
				local ok, msg, exp
				if type(ks.Validate) == "function" then
					ok, msg, exp = ks.Validate(body, key, code)
				else
					ok, msg, exp = BodyIsValid(body)
				end
				if ok == true then
					if type(msg) == "number" then exp = msg end
					return true, nil, ParseExpiry(exp), true, {Source = "remote"}
				end
				lastMsg = type(msg) == "string" and msg or nil
			else
				lastMsg = ks.OfflineMessage or "Could not reach key server"
			end
		end
		if type(ks.Verify) == "function" then
			reached = true
			local ok, a, b = ks.Verify(key, hwid, LocalPlayer)
			if ok == true then
				local exp = b
				if type(a) == "number" then exp = a end
				if type(a) == "table" then exp = a.Expires or a.expires end
				return true, nil, ParseExpiry(exp), true, {Source = "verify", Note = type(a) == "table" and (a.Note or a.note) or nil}
			end
			if type(a) == "string" then lastMsg = a end
		end
		return false, lastMsg or ks.InvalidMessage or "Invalid key", nil, reached
	end

	function B.Check(key, activated)
		local ok, valid, msg, exp, definitive, meta = pcall(Check, Norm(key))
		if not ok then return false, "Verification error", nil, false end
		if not valid then return false, msg, nil, definitive end
		meta = meta or {}
		local dur = tonumber(meta.Duration) or tonumber(ks.Duration)
		if dur and dur > 0 then
			local localExp = math.floor((tonumber(activated) or Now()) + dur)
			exp = exp and math.min(exp, localExp) or localExp
		end
		if exp and exp <= Now() then return false, "Key expired", nil, true, meta end
		return true, nil, exp, true, meta
	end

	-- Saved key file: key, activation time and a signature over both (plus the HWID unless
	-- BindHwid = false), so the activation time can't be edited and the file can't be copied
	-- to another device.
	local folder = ks.Folder or ctx.Folder
	local fileName = ks.FileName or ((ctx.GuiName or Library.GuiName) .. "_key.txt")
	local savePath = (folder and folder ~= "") and (folder .. "/" .. fileName) or fileName
	local function Sig(key, activated)
		return Sha256(table.concat({tostring(key), tostring(activated), ks.BindHwid ~= false and hwid or "", tostring(ks.Salt or "zenin-key")}, "\n"))
	end
	function B.Save(key, activated)
		if ks.SaveKey == false or not writefile then return end
		if folder and folder ~= "" then EnsureFolderPath(folder) end
		activated = math.floor(tonumber(activated) or Now())
		key = Norm(key)
		pcall(writefile, savePath, key .. "\n" .. tostring(activated) .. "\n" .. Sig(key, activated))
	end
	function B.Load()
		if ks.SaveKey == false or not (isfile and readfile) then return nil end
		local ok, exists = pcall(isfile, savePath)
		if not (ok and exists) then return nil end
		local ok2, data = pcall(readfile, savePath)
		if not (ok2 and type(data) == "string") then return nil end
		local key, stamp, sig = data:match("^([^\n]*)\n(%d+)\n(%x+)")
		local activated = tonumber(stamp)
		if not key or key == "" or not activated then
			B.Forget()
			return nil
		end
		activated = math.floor(activated)
		if sig:lower() ~= Sig(key, activated) then
			B.Forget()
			return nil
		end
		return key, activated
	end
	function B.Forget()
		if delfile then pcall(delfile, savePath) end
	end
	return B
end

local KEY_TEXTS = {
	Title = "Zenin", Subtitle = "Key System", Note = "Enter your key to continue.", Placeholder = "Paste your key here",
	Verify = "Verify", GetKey = "Get Key", Checking = "Checking...", Verifying = "Verifying...",
	CheckingSaved = "Checking saved key...", Accepted = "Key accepted", AcceptedExpires = "Key accepted · expires in %s",
	TooMany = "Too many attempts. Wait %ds", SavedExpired = "Saved key expired. Enter a new key",
	SavedInvalid = "Saved key is no longer valid", SavedUnverified = "Could not verify saved key",
	LinkCopied = "Key link copied to clipboard",
}

-- Blocks the calling thread until a key passes verification.
-- Returns true, {Key, Expires, Activated, Source, Note, Hwid}, or false if the user closes it.
function RunKeySystem(ks, ctx)
	if type(ks) ~= "table" then ks = {} end
	if ks.Enabled == false then return true, {} end
	ctx = ctx or {}
	local texts = type(ks.Texts) == "table" and ks.Texts or {}
	local function Txt(name, legacy)
		local v = texts[name]
		if v == nil then v = legacy end
		if v == nil then v = KEY_TEXTS[name] end
		return tostring(v)
	end

	local B = ctx.Backend or KeyBackend(ks, ctx)
	if B.Whitelisted() then
		local info = {Key = "whitelist", Activated = Now(), Source = "whitelist", Hwid = B.Hwid}
		SafeCall(ks.OnSuccess or ks.Callback, info.Key, info)
		return true, info
	end

	local theme = Library.Themes[ctx.Theme or ""] or Library.Themes.Dark
	local K = {
		Theme = theme,
		Accent = ToColor(ctx.Accent) or rgb(255, 89, 89),
		AccentAlpha = ToAlpha(ctx.AccentAlpha) or 1,
	}
	function K.Bind(fn) fn(K.Theme, K.Accent, K.AccentAlpha) end

	-- The on-screen keyboard stays off until the window exists; the prompt uses the device keyboard.
	local keyboardWasReady = VKB.Ready
	VKB.SetReady(false)

	local parent = ctx.Parent
	if not parent then
		local ok, hui = pcall(function() return gethui and gethui() end)
		parent = (ok and hui) or LocalPlayer:WaitForChild("PlayerGui")
	end
	local guiName = (ctx.GuiName or Library.GuiName) .. "_Key"
	local old = parent:FindFirstChild(guiName)
	if old then old:Destroy() end
	local gui = Create("ScreenGui", {
		Name = guiName,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = (ctx.DisplayOrder or 100) + 1,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = parent,
	})
	if ctx.OnGui then SafeCall(ctx.OnGui, gui) end

	local T = theme
	local KW, KH = math.max(220, tonumber(ks.Width) or 300), math.max(150, tonumber(ks.Height) or 186)
	local holder = Create("Frame", {
		Size = UDim2.fromOffset(KW, KH),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	Create("UIScale", {Scale = math.clamp(tonumber(ks.Scale or ctx.Scale) or 1, 0.3, 3), Parent = holder})
	local main = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = T.WindowBg, BorderSizePixel = 0, Active = true, Parent = holder})
	Corner(main, 6)
	Stroke(main, T.BoxBorder, 1)

	local header = Create("Frame", {Size = UDim2.new(1, 0, 0, HEADER_H), BackgroundColor3 = T.BarBg, BorderSizePixel = 0, Parent = main})
	Corner(header, 6)
	Create("Frame", {Size = UDim2.new(1, 0, 0, HEADER_H / 2), Position = UDim2.fromOffset(0, HEADER_H / 2), BackgroundColor3 = T.BarBg, BorderSizePixel = 0, Parent = header})
	AccentWash(header, 6, 0.07)(K.Accent, K.AccentAlpha)
	Create("Frame", {Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BackgroundColor3 = T.BarLine, BorderSizePixel = 0, Parent = header})

	local brand = Create("Frame", {Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.fromOffset(9, 0), BackgroundTransparency = 1, Parent = header})
	Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 5),
		Parent = brand,
	})
	local title = Txt("Title", ks.Title or ctx.Title)
	local logo = CreateLogo(K, brand, NormalizeLogo(ks.Logo or ctx.Logo, title), 12, 15)
	logo.LayoutOrder = 1
	local titleLbl = Label(brand, title, {AutoX = true, Size = UDim2.new(0, 0, 1, 0), Weight = "SemiBold", Color = T.Text})
	titleLbl.LayoutOrder = 2
	local sub = Label(header, Txt("Subtitle", ks.Subtitle), {
		Position = UDim2.new(0, 0, 0, 0), Size = UDim2.new(1, -40, 1, 0),
		Align = Enum.TextXAlignment.Right, TextSize = 10, Color = T.TextDim,
	})
	sub.ZIndex = 1

	local closeBtn = Create("TextButton", {
		Size = UDim2.fromOffset(24, 24),
		Position = UDim2.new(1, -30, 0.5, -12),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Visible = ks.CanClose ~= false,
		Parent = header,
	})
	local closeIc = CreateIcon(closeBtn, {"x"}, 12, UDim2.new(0.5, -6, 0.5, -6), T.NavGray)
	OnMouseEnter(closeBtn, function() Anim(closeIc, {ImageColor3 = T.Text, Rotation = 90}, true, MOVE_TI) end)
	closeBtn.MouseLeave:Connect(function() Anim(closeIc, {ImageColor3 = T.NavGray, Rotation = 0}, true, MOVE_TI) end)
	if ks.CanClose == false then sub.Size = UDim2.new(1, -12, 1, 0) end

	local body = Create("Frame", {Size = UDim2.new(1, -24, 1, -HEADER_H - 12), Position = UDim2.fromOffset(12, HEADER_H + 10), BackgroundTransparency = 1, Parent = main})
	Label(body, Txt("Note", ks.Note or ks.Description), {Size = UDim2.new(1, 0, 0, 14), Color = T.TextGray, Truncate = true})

	local boxFrame = Create("Frame", {Size = UDim2.new(1, 0, 0, 27), Position = UDim2.fromOffset(0, 22), BackgroundColor3 = T.DropdownBg, BorderSizePixel = 0, Parent = body})
	Corner(boxFrame, 3)
	local boxStroke = Stroke(boxFrame, T.DropdownBorder, 1)
	CreateIcon(boxFrame, {"key-round", "key"}, 12, UDim2.new(0, 9, 0.5, -6), T.TextDim)
	local box = Create("TextBox", {
		Size = UDim2.new(1, -36, 1, 0),
		Position = UDim2.fromOffset(28, 0),
		BackgroundTransparency = 1,
		Text = "",
		PlaceholderText = Txt("Placeholder", ks.Placeholder),
		PlaceholderColor3 = T.TextDim,
		TextColor3 = T.Text,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		TextSize = TEXT,
		Weight = "Medium",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = boxFrame,
	})
	local onKeyEnter
	local boxFocused = false
	AttachKeyboard(box, K, function()
		boxFocused = true
		Anim(boxStroke, {Color = K.Accent, Transparency = 1 - K.AccentAlpha}, true)
	end, function(enter)
		boxFocused = false
		Anim(boxStroke, {Color = T.DropdownBorder, Transparency = 0}, true)
		if enter and onKeyEnter then onKeyEnter() end
	end, {Native = true})

	local link = ks.GetKeyLink or ks.Link or ks.KeyLink
	local btnRow = Create("Frame", {Size = UDim2.new(1, 0, 0, 27), Position = UDim2.fromOffset(0, 57), BackgroundTransparency = 1, Parent = body})
	local function KeyButton(text, icon, primary, x, w)
		local b = Create("TextButton", {
			Size = UDim2.new(w, -3, 1, 0),
			Position = UDim2.new(x, x == 0 and 0 or 3, 0, 0),
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			Parent = btnRow,
		})
		Corner(b, 3)
		local st = Stroke(b, T.DropdownBorder, 1)
		local content = Create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1, Parent = b,
		})
		Create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5), Parent = content,
		})
		local ic = CreateIcon(content, icon, 12, nil)
		ic.LayoutOrder = 1
		local lb = Label(content, text, {AutoX = true, Size = UDim2.new(0, 0, 1, 0)})
		lb.LayoutOrder = 2
		local hover, disabled = false, false
		local pressed = false
		local function Paint(animate)
			local bg = T.DropdownBg
			if pressed and not disabled then
				bg = T.TileHover:Lerp(T.Text, 0.06)
			elseif hover and not disabled then
				bg = T.TileHover
			end
			Anim(b, {BackgroundColor3 = bg}, animate)
			if primary and not disabled then
				Anim(st, {Color = K.Accent, Transparency = 1 - K.AccentAlpha}, animate)
			else
				Anim(st, {Color = T.DropdownBorder, Transparency = 0}, animate)
			end
			local fg = disabled and T.TextDim or ((hover or primary) and T.Text or T.TextGray)
			Anim(lb, {TextColor3 = fg}, animate)
			Anim(ic, {ImageColor3 = (primary and not disabled) and K.Accent or fg}, animate)
		end
		Paint(false)
		OnMouseEnter(b, function() hover = true; Paint(true) end)
		b.MouseLeave:Connect(function() hover = false; pressed = false; Paint(true) end)
		b.InputBegan:Connect(function(i) if IsClickOrTouch(i) then pressed = true; Paint(true) end end)
		b.InputEnded:Connect(function(i) if IsClickOrTouch(i) then pressed = false; Paint(true) end end)
		return b, lb, function(d) disabled = d; Paint(true) end
	end
	local verifyText = Txt("Verify", ks.VerifyText)
	local verifyBtn, verifyLbl, setVerifyDisabled
	local getBtn
	if link then
		getBtn = KeyButton(Txt("GetKey", ks.GetKeyText), {"link", "external-link"}, false, 0, 0.5)
		verifyBtn, verifyLbl, setVerifyDisabled = KeyButton(verifyText, {"shield-check", "check"}, true, 0.5, 0.5)
	else
		verifyBtn, verifyLbl, setVerifyDisabled = KeyButton(verifyText, {"shield-check", "check"}, true, 0, 1)
		verifyBtn.Size = UDim2.fromScale(1, 1)
	end

	local status = Label(body, "", {Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 92), TextSize = 10, Color = T.TextDim, Truncate = true})
	local ERR, OK = ToColor(ks.ErrorColor) or rgb(235, 87, 87), ToColor(ks.SuccessColor) or rgb(88, 200, 120)
	local function Status(text, kind)
		status.Text = tostring(text or "")
		status.TextColor3 = kind == "error" and ERR or (kind == "ok" and OK or T.TextDim)
	end
	-- Wrong key: the field border flashes red and settles back; no movement.
	local function FlashError()
		if ks.ErrorFlash == false then return end
		StopTweens(boxStroke)
		boxStroke.Color, boxStroke.Transparency = ERR, 0
		local target = boxFocused and K.Accent or T.DropdownBorder
		Tween(boxStroke, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Color = target, Transparency = boxFocused and (1 - K.AccentAlpha) or 0})
	end

	local thread = coroutine.running()
	local finished, busy = false, false
	local attempts, lockedUntil = 0, 0
	local maxAttempts = tonumber(ks.MaxAttempts)
	local lockTime = tonumber(ks.Cooldown) or 30

	local function Complete(result, info)
		if finished then return end
		finished = true
		VKB.SetReady(keyboardWasReady)
		Tween(holder, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {Position = UDim2.new(0.5, 0, 0.5, 12)})
		task.delay(0.12, function() gui:Destroy() end)
		if result then SafeCall(ks.OnSuccess or ks.Callback, info.Key, info) else SafeCall(ks.OnClose) end
		task.spawn(thread, result, info)
	end

	local function Attempt(key, fromSave, activated)
		if busy or finished then return end
		key = Trim(key)
		local now = os.clock()
		if now < lockedUntil then
			Status(Txt("TooMany"):format(math.ceil(lockedUntil - now)), "error")
			return
		end
		if not fromSave and SafeCall(ks.OnAttempt, key) == false then return end
		busy = true
		setVerifyDisabled(true)
		verifyLbl.Text = Txt("Checking")
		Status(fromSave and Txt("CheckingSaved") or Txt("Verifying"))
		activated = math.floor(tonumber(activated) or Now())
		task.spawn(function()
			local valid, msg, exp, definitive, meta = B.Check(key, activated)
			busy = false
			if finished or not gui.Parent then return end
			setVerifyDisabled(false)
			verifyLbl.Text = verifyText
			if valid then
				Status(exp and Txt("AcceptedExpires"):format(FormatDuration(exp - Now())) or Txt("Accepted"), "ok")
				B.Save(key, activated)
				local info = {Key = B.Normalize(key), Expires = exp, Activated = activated, Hwid = B.Hwid,
					Source = meta and meta.Source or "static", Note = meta and meta.Note or nil}
				task.delay(0.35, function() Complete(true, info) end)
				return
			end
			if fromSave then
				if definitive then
					B.Forget()
					box.Text = ""
					Status(msg == "Key expired" and Txt("SavedExpired") or Txt("SavedInvalid"), "error")
				else
					Status(msg or Txt("SavedUnverified"), "error")
				end
				return
			end
			attempts = attempts + 1
			FlashError()
			SafeCall(ks.OnFail, key, msg, attempts)
			if maxAttempts and attempts >= maxAttempts then
				attempts = 0
				lockedUntil = os.clock() + lockTime
				Status(Txt("TooMany"):format(math.ceil(lockTime)), "error")
				SafeCall(ks.OnLocked, lockTime)
			else
				Status(msg or "Invalid key", "error")
			end
		end)
	end

	gui.Destroying:Connect(function() Complete(false) end)
	verifyBtn.MouseButton1Click:Connect(function() Attempt(box.Text) end)
	onKeyEnter = function() Attempt(box.Text) end
	closeBtn.MouseButton1Click:Connect(function()
		if ks.CanClose ~= false then Complete(false) end
	end)
	if getBtn then
		getBtn.MouseButton1Click:Connect(function()
			local clip = setclipboard or toclipboard or (Clipboard and Clipboard.set)
			if clip and pcall(clip, tostring(link)) then
				Status(Txt("LinkCopied"), "ok")
			else
				Status(tostring(link))
			end
			SafeCall(ks.OnGetKey, link)
		end)
	end

	holder.Position = UDim2.new(0.5, 0, 0.5, 12)
	Tween(holder, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0.5, 0.5)})

	if ctx.Reason then Status(ctx.Reason, "error") end
	local saved, savedAt
	if not ctx.SkipSaved then saved, savedAt = B.Load() end
	if saved then
		box.Text = saved
		Attempt(saved, true, savedAt)
	elseif ks.AutoFocus ~= false and not TouchDevice() then
		task.defer(function()
			if not finished and gui.Parent then pcall(function() box:CaptureFocus() end) end
		end)
	end
	return coroutine.yield()
end
end -- key system

local function CreateWindow(o)
	o = Opts(o)
	local guiKey = o.GuiName or Library.GuiName
	-- Re-running the script: fully unload the previous window (connections, loops, keybinds),
	-- not just its ScreenGui, even if it came from an older copy of the library.
	local prev = LiveWindows[guiKey]
	if prev then
		LiveWindows[guiKey] = nil
		pcall(prev)
	end
	if o.CustomKeyboard ~= nil then Library.SetCustomKeyboard(o.CustomKeyboard) end
	if type(o.Keyboard) == "table" then Library.Keyboard.Configure(o.Keyboard) end
	-- Held back until the window is fully built; the key prompt never gets the on-screen keyboard.
	VKB.SetReady(false)
	if o.Name and not o.Title then o.Title = o.Name end
	-- Runs before any window or API exists, so nothing below is reachable until a key passes.
	local keyCfg, keyCtx, keyInfo
	if o.KeySystem and o.KeySystem ~= false then
		keyCfg = o.KeySystem == true and {} or o.KeySystem
		keyCtx = {
			Theme = o.Theme, Accent = o.Accent, AccentAlpha = o.AccentAlpha,
			Title = o.Title, Logo = o.Logo or o.Icon, Parent = o.Parent, GuiName = o.GuiName,
			DisplayOrder = o.DisplayOrder, Folder = o.ConfigFolder or Library.ConfigFolder,
		}
		if keyCfg.Enabled ~= false then keyCtx.Backend = KeyBackend(keyCfg, keyCtx) end
		local ok, info = RunKeySystem(keyCfg, keyCtx)
		if not ok then error("[Zenin] key verification was not completed", 0) end
		keyInfo = info
	end
	if Library.ActiveWindow then pcall(Library.ActiveWindow.Destroy) end

	local themeName = Library.Themes[o.Theme or ""] and o.Theme or "Dark"
	local W = {
		Alive = true,
		Title = o.Title or "Zenin",
		ThemeName = themeName,
		RequestedTheme = o.Theme,
		Theme = Library.Themes[themeName],
		Accent = ToColor(o.Accent) or rgb(255, 89, 89),
		AccentAlpha = ToAlpha(o.AccentAlpha) or 1,
		Maid = Maid.new(),
		Listeners = {}, Popups = {}, LogoHooks = {},
		Pages = {}, Tabs = {}, Elements = {}, HeaderButtons = {}, AccentIcons = {}, UnloadCallbacks = {},
		BarW = math.clamp(math.floor(tonumber(o.ScrollbarSize) or 6), 3, 24),
		WheelScroll = o.MouseWheel == true,
		ToggleKey = ParseKey(o.ToggleKey or o.Keybind) or Enum.KeyCode.RightShift,
		Nav = {main = "settings"},
		TransitionName = o.Transition,
		NotifyOrder = 0,
		ConfigFolder = o.ConfigFolder or Library.ConfigFolder,
	}
	W.LogoSpec = NormalizeLogo(o.Logo or o.Icon, W.Title)
	LoadIcons()
	-- Placeholder until Window.Destroy exists, so a build that errors part-way can still be released.
	LiveWindows[guiKey] = function()
		W.Alive = false
		W.Maid:Destroy()
		VKB.SetReady(true)
	end

	function W.Bind(fn, owner)
		table.insert(W.Listeners, {fn = fn, owner = owner})
		fn(W.Theme, W.Accent, W.AccentAlpha)
	end
	function W.Prune()
		local alive = {}
		for _, e in ipairs(W.Listeners) do
			if not e.owner or e.owner.Parent then table.insert(alive, e) end
		end
		W.Listeners = alive
	end
	function W.Refresh()
		if not W.Alive then return end
		W.Prune()
		for _, e in ipairs(W.Listeners) do
			local ok, err = pcall(e.fn, W.Theme, W.Accent, W.AccentAlpha)
			if not ok then warn("[Zenin] theme listener error: " .. tostring(err)) end
		end
		if VKB.Target and VKB.Opts and VKB.Opts.theme == W then
			VKB.Paint()
			VKB.Render()
		end
	end
	function W.Paint(obj, prop, key)
		W.Bind(function(T) obj[prop] = T[key] end, obj)
	end
	function W.NavIcon(ic)
		W.Bind(function(T)
			if not IndexOf(W.AccentIcons, ic) then ic.ImageColor3 = T.NavGray end
		end, ic)
	end
	-- maid: optional owner (e.g. an element's maid); defaults to the window's.
	function W.Connect(signal, fn, maid)
		return (maid or W.Maid):Give(signal:Connect(fn))
	end
	W.Drag = nil
	local function Stale(d, input)
		if d.input == input then return false end
		if d.input.UserInputType == Enum.UserInputType.Touch then
			return d.input.UserInputState == Enum.UserInputState.End
		end
		return input.UserInputType == d.input.UserInputType
	end
	function W.BeginDrag(input, move, finish, tag)
		if W.Drag and Stale(W.Drag, input) then W.CancelDrag() end
		if W.Drag then return false end
		W.Drag = {input = input, move = move, finish = finish, tag = tag}
		return true
	end
	function W.CancelDrag(tag)
		local d = W.Drag
		if d and (tag == nil or d.tag == tag) then
			W.Drag = nil
			if d.finish then SafeCall(d.finish, nil, true) end
		end
	end
	local function SameInput(d, input, ended)
		if d.input.UserInputType == Enum.UserInputType.Touch then return input == d.input end
		if ended then return input.UserInputType == d.input.UserInputType end
		return input.UserInputType == Enum.UserInputType.MouseMovement
	end
	W.Connect(UserInputService.InputChanged, function(input)
		local d = W.Drag
		if d and d.move and SameInput(d, input, false) then SafeCall(d.move, input) end
	end)
	W.Connect(UserInputService.InputEnded, function(input)
		local d = W.Drag
		if not d or not SameInput(d, input, true) then return end
		W.Drag = nil
		if d.finish then SafeCall(d.finish, input, false) end
	end)

	W.PopupFading = 0
	local function LayerCheck()
		if #W.Popups == 0 and W.PopupFading == 0 and W.PopupLayer then W.PopupLayer.Visible = false end
	end
	local function Dispose(e)
		if e.keep then
			e.frame.Visible = false
		else
			e.frame:Destroy()
		end
	end
	function W.ClosePopupsFrom(level)
		W.CancelDrag("popup")
		for i = #W.Popups, math.max(level, 1), -1 do
			local e = table.remove(W.Popups, i)
			if e.catcher then e.catcher:Destroy() end
			if W.Alive and W.Visible ~= false and e.frame.Parent then
				W.PopupFading = W.PopupFading + 1
				FadeContent(e.frame, W.PopupLayer, UDim2.fromScale(1, 1), false, POP_OUT, e.frame.ZIndex, function(current)
					W.PopupFading = math.max(0, W.PopupFading - 1)
					if current and W.Alive then pcall(Dispose, e) end
					if W.Alive then LayerCheck() end
				end)
			else
				pcall(Dispose, e)
			end
			if e.onClose then SafeCall(e.onClose) end
		end
		LayerCheck()
	end
	function W.ClosePopup()
		W.ClosePopupsFrom(1)
	end
	function W.PopupOf(owner)
		for i, e in ipairs(W.Popups) do
			if e.owner == owner or (type(e.owner) == "table" and e.owner.el == owner) then return i end
		end
		return nil
	end
	function W.ClosePopupOf(owner)
		local i = W.PopupOf(owner)
		if i then W.ClosePopupsFrom(i) end
	end
	function W.PreparePopup(owner, anchor)
		local i = W.PopupOf(owner)
		if i then
			W.ClosePopupsFrom(i)
			return false
		end
		local keep = 0
		for j, e in ipairs(W.Popups) do
			if anchor and anchor:IsDescendantOf(e.frame) then keep = j end
		end
		W.ClosePopupsFrom(keep + 1)
		return true
	end
	function W.PushPopup(frame, owner, opts)
		opts = opts or {}
		local level = #W.Popups + 1
		local z = 30 + level * 2
		local catcher = Create("TextButton", {
			Position = UDim2.fromOffset(-4000, -4000),
			Size = UDim2.fromOffset(8000 + WIN_W, 8000 + WIN_H),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = z,
			Parent = W.PopupLayer,
		})
		catcher.MouseButton1Click:Connect(function() W.ClosePopupsFrom(level) end)
		frame.ZIndex = z + 1
		frame.Parent = W.PopupLayer
		frame.Visible = true
		if opts.Fade ~= false then FadeContent(frame, W.PopupLayer, UDim2.fromScale(1, 1), true, POP_IN, z + 1) end
		table.insert(W.Popups, {frame = frame, owner = owner, keep = opts.Keep, catcher = catcher, onClose = opts.OnClose})
		W.PopupLayer.Visible = true
	end
	function W.SetAccent(c, alpha)
		if not W.Alive then return end
		c, alpha = ToColor(c), ToAlpha(alpha)
		local changed = false
		if c and c ~= W.Accent then W.Accent, changed = c, true end
		if alpha and alpha ~= W.AccentAlpha then W.AccentAlpha, changed = alpha, true end
		if changed then W.Refresh() end
	end
	-- For changes coming from outside the accent modal: an open modal would hold stale HSV and overwrite them.
	function W.SetAccentExternal(c, alpha)
		if W.AccentPickerEl then W.ClosePopupOf(W.AccentPickerEl) end
		W.SetAccent(c, alpha)
	end
	function W.SetTheme(name)
		local t = W.Alive and Library.Themes[name]
		if not t then return false end
		W.Theme, W.ThemeName = t, name
		W.Refresh()
		if W.ThemeDropdown and W.ThemeDropdown.Get() ~= name then W.ThemeDropdown.Set(name, true) end
		return true
	end
	function W.SetScale(s, animate)
		s = math.clamp(tonumber(s) or 1, 0.3, 3)
		W.UserScale = s
		if W.ScaleDropdown and SCALE_MAP[W.ScaleDropdown.Get()] ~= s then W.ScaleDropdown.Set(ScaleLabelFor(s), true) end
		-- The open/close animation drives W.Scale; it lands on UserScale when it finishes.
		if W.Animating then return end
		if animate then
			Tween(W.Scale, TweenInfo.new(0.18), {Scale = s})
		else
			W.Scale.Scale = s
		end
	end
	function W.SetBarWidth(v)
		W.BarW = math.clamp(math.floor((tonumber(v) or 6) + 0.5), 3, 24)
		for _, p in ipairs(W.Pages) do
			p.LayoutColumns()
			p.Update()
		end
	end

	local parent = o.Parent
	if not parent then
		local ok, hui = pcall(function() return gethui and gethui() end)
		parent = (ok and hui) or LocalPlayer:WaitForChild("PlayerGui")
	end
	local guiName = guiKey
	local old = parent:FindFirstChild(guiName)
	if old then old:Destroy() end
	VKB.Purge(parent)
	W.Gui = Create("ScreenGui", {
		Name = guiName,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = o.DisplayOrder or 100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = parent,
	})
	-- First task, so it is cleaned last: everything else still has its UI while it cleans up.
	W.Maid:Give(W.Gui)

	W.WatermarkApi = BuildWatermark(W, o.Watermark)
	W.KeybindListApi = BuildKeybindList(W, o.KeybindList)
	BuildShell(W)
	BuildNavigation(W)

	W.UserScale = W.Scale.Scale
	W.Visible = true
	W.Animate = o.Animation ~= false and o.Animations ~= false
	-- CanvasGroup is only used while animating (wrapping Main) so the window can fade as one layer.
	local okFader, Fader = pcall(Create, "CanvasGroup", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = W.Holder,
	})
	if not okFader then Fader = nil end
	local OPEN_TI = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local CLOSE_TI = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	local CLOSED_SCALE = 0.94
	local animToken = 0
	local function Unwrap()
		if Fader and W.Main.Parent == Fader then
			W.Main.Parent = W.Holder
		end
		if Fader then
			Fader.Visible = false
			Fader.GroupTransparency = 0
		end
	end
	-- Returns every user element to its default, firing callbacks so script features switch off.
	function W.ResetElements()
		W.ClosePopup()
		W.CancelDrag()
		W.PendingFlags = nil
		for _, el in ipairs(CopyList(W.Elements)) do
			local f = el.Flag
			if not (f and f:sub(1, 7) == "__Zenin") then
				if el._reset then
					SafeCall(el._reset)
				elseif el._default ~= nil then
					ApplyFlag(el, el._default)
				end
			end
		end
	end

	function W.SetShown(show, instant)
		if not W.Alive then return end
		show = show ~= false
		if show and W.KeyLocked then return end
		W.Visible = show
		animToken = animToken + 1
		local token = animToken
		if not show then
			W.ClosePopup()
			W.CancelDrag()
		end
		StopTweens(W.Scale, Fader)
		if instant or not W.Animate or (not show and not W.Holder.Visible) then
			W.Animating = false
			Unwrap()
			W.Scale.Scale = W.UserScale
			W.Holder.Visible = show
			return
		end
		local fresh = not W.Holder.Visible
		W.Animating = true
		W.Holder.Visible = true
		if Fader and W.Main.Parent ~= Fader then
			Fader.GroupTransparency = fresh and 1 or 0
			Fader.Visible = true
			W.Main.Parent = Fader
		end
		if fresh then W.Scale.Scale = W.UserScale * CLOSED_SCALE end
		local ti = show and OPEN_TI or CLOSE_TI
		local t = Tween(W.Scale, ti, {Scale = W.UserScale * (show and 1 or CLOSED_SCALE)})
		if Fader then Tween(Fader, ti, {GroupTransparency = show and 0 or 1}) end
		t.Completed:Connect(function()
			if token ~= animToken or not W.Alive then return end
			W.Animating = false
			if not show then W.Holder.Visible = false end
			Unwrap()
			W.Scale.Scale = W.UserScale
		end)
	end
	local settingsApi = BuildSettings(W, o)
	if o.Scale then W.SetScale(o.Scale) end
	W.RefreshNav(true)

	W.Connect(UserInputService.InputBegan, function(input, gp)
		if W.Capturing or W.LastCaptured == input then return end
		if not gp and KeyMatches(W.ToggleKey, input) then
			W.Window.Toggle()
		end
	end)

	local Window = {Library = Library, Settings = settingsApi}
	W.Window = Window
	Window.Watermark = W.WatermarkApi
	Window.KeybindList = W.KeybindListApi

	Method(Window, "AddTab", function(x) return AddTab(W, x) end)
	Window.Tab = Window.AddTab
	Window.CreateTab = Window.AddTab
	Method(Window, "AddSettingsSection", function(x) return settingsApi.AddSection(x) end)
	Method(Window, "SelectSettings", function() W.Navigate("settings") end)

	Method(Window, "SetTitle", function(t)
		W.Title = tostring(t)
		W.TitleLabel.Text = W.Title
	end)
	Method(Window, "SetLogo", function(spec)
		W.LogoSpec = NormalizeLogo(spec, W.Title)
		W.BuildHeaderLogo()
		W.WM.BuildLogo()
		for _, fn in ipairs(W.LogoHooks) do SafeCall(fn) end
	end)

	Method(Window, "SetTheme", function(name) return W.SetTheme(name) end)
	Method(Window, "GetTheme", function() return W.ThemeName end)
	Method(Window, "GetThemes", function() return CopyList(Library.ThemeOrder) end)
	Method(Window, "SetAccent", function(c, a) W.SetAccentExternal(c, a) end)
	Method(Window, "GetAccent", function() return W.Accent, W.AccentAlpha end)
	Method(Window, "SetScale", function(s, animate) W.SetScale(s, animate) end)
	Method(Window, "GetScale", function() return W.UserScale end)
	Method(Window, "SetScrollbarSize", function(px) W.ScrollSlider.Set(px) end)
	Method(Window, "SetMouseWheel", function(b)
		W.WheelScroll = b == true
		for _, p in ipairs(W.Pages) do p.scroll.ScrollingEnabled = W.WheelScroll end
	end)

	Method(Window, "SetVisible", function(b, instant) W.SetShown(b ~= false, instant) end)
	Method(Window, "Show", function(instant) W.SetShown(true, instant) end)
	Method(Window, "Hide", function(instant) W.SetShown(false, instant) end)
	Method(Window, "Toggle", function(instant) W.SetShown(not W.Visible, instant) end)
	Method(Window, "IsVisible", function() return W.Visible end)
	Method(Window, "SetAnimation", function(b) W.Animate = b ~= false end)
	Method(Window, "SetTransition", function(name) return W.SetTransition(name) end)
	Method(Window, "GetTransition", function() return W.GetTransition() end)
	Method(Window, "GetTransitions", function()
		local names = {}
		for i, t in ipairs(PAGE_TRANSITIONS) do names[i] = t.Name end
		return names
	end)
	Method(Window, "SetToggleKey", function(k) W.ToggleKey = ParseKey(k) or W.ToggleKey end)
	Method(Window, "GetToggleKey", function() return W.ToggleKey end)
	Method(Window, "SetPosition", function(p) W.Holder.Position = p end)
	Method(Window, "Center", function()
		Tween(W.Holder, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0.5, 0.5)})
	end)

	Method(Window, "AddHeaderButton", function(bo)
		bo = Opts(bo)
		local b = Create("TextButton", {
			Size = UDim2.fromOffset(24, 24),
			BackgroundTransparency = 1,
			Text = "",
			Parent = W.Header,
		})
		local ic = CreateIcon(b, bo.Icon or "circle", 12, UDim2.new(0.5, -6, 0.5, -6))
		W.Paint(ic, "ImageColor3", "NavGray")
		local hs = Create("UIScale", {Parent = ic})
		OnMouseEnter(b, function()
			Anim(ic, {ImageColor3 = W.Theme.Text}, true)
			Anim(hs, {Scale = 1.12}, true, MOVE_TI)
		end)
		b.MouseLeave:Connect(function()
			Anim(ic, {ImageColor3 = W.Theme.NavGray}, true)
			Anim(hs, {Scale = 1}, true, MOVE_TI)
		end)
		b.MouseButton1Click:Connect(function()
			SoftPress(ic)
			SafeCall(bo.Callback)
		end)
		table.insert(W.HeaderButtons, b)
		W.LayoutHeader()
		local hb = {}
		Method(hb, "SetIcon", function(spec) ApplyIcon(ic, spec) end)
		Method(hb, "SetCallback", function(fn) bo.Callback = fn end)
		Method(hb, "Destroy", function()
			local i = IndexOf(W.HeaderButtons, b)
			if i then table.remove(W.HeaderButtons, i) end
			b:Destroy()
			W.LayoutHeader()
		end)
		return hb
	end)

	Method(Window, "Notify", function(x) return Notify(W, x) end)
	Method(Window, "ClosePopups", function() W.ClosePopup() end)

	local Configs = BuildConfigManager(W, Window, o)
	Window.Configs = Configs
	Method(Window, "GetConfig", function() return Configs.Get() end)
	Method(Window, "ApplyConfig", function(data) return Configs.Apply(data) end)
	Method(Window, "SaveConfig", function(name) return Configs.Save(name) end)
	Method(Window, "LoadConfig", function(name) return Configs.Load(name) end)
	Method(Window, "DeleteConfig", function(name) return Configs.Delete(name) end)
	Method(Window, "ListConfigs", function() return Configs.List() end)

	Method(Window, "EnableConfigs", function(co)
		if type(co) == "table" then Configs.Configure(co) end
		if W.ConfigPage then return W.ConfigApi end
		W.ConfigApi = BuildConfigs(W, Window)
		W.RefreshNav(true)
		if not (type(co) == "table" and co.AutoLoad == false) then Configs.LoadAutoLoad() end
		return W.ConfigApi
	end)
	Method(Window, "SelectConfigs", function()
		if not W.ConfigPage then return end
		W.Navigate("configs")
		W.RefreshConfigs()
	end)
	Method(Window, "RefreshConfigs", function() if W.RefreshConfigs then W.RefreshConfigs() end end)
	Method(Window, "GetActiveConfig", function() return Configs.GetActive() end)
	Method(Window, "GetStats", function()
		return {
			Listeners = #W.Listeners,
			Connections = W.Maid:Count(true),
			Elements = #W.Elements,
			Pages = #W.Pages,
			Instances = W.Alive and #W.Gui:GetDescendants() or 0,
		}
	end)

	Method(Window, "OnUnload", function(fn) table.insert(W.UnloadCallbacks, fn) end)
	Method(Window, "GiveTask", function(job) return W.Maid:Give(job) end)
	Method(Window, "Connect", function(signal, fn) return W.Connect(signal, fn) end)
	Method(Window, "Destroy", function()
		if not W.Alive then return end
		W.Alive = false
		if LiveWindows[guiKey] == Window.Destroy then LiveWindows[guiKey] = nil end
		local wi = IndexOf(Library.Windows, Window)
		if wi then table.remove(Library.Windows, wi) end
		if W.KeyGui then pcall(function() W.KeyGui:Destroy() end) end
		W.ClosePopup()
		W.CancelDrag()
		for _, p in ipairs(W.Pages) do p.StopScroll() end
		local hi = IndexOf(ThemeHooks, W.ThemeHook)
		if hi then table.remove(ThemeHooks, hi) end
		-- User callbacks run first, while the UI and element state still exist.
		for _, fn in ipairs(W.UnloadCallbacks) do SafeCall(fn) end
		for _, el in ipairs(W.Elements) do
			if el.Flag and Library.Options[el.Flag] == el then
				Library.Flags[el.Flag] = nil
				Library.Options[el.Flag] = nil
			end
		end
		VKB.Destroy()
		-- Connections, loops, element maids and user tasks, newest first; the ScreenGui last.
		W.Maid:Destroy()
		W.Listeners = {}
		for _, t in ipairs({W.Elements, W.Pages, W.Tabs, W.HeaderButtons, W.AccentIcons, W.UnloadCallbacks, W.Popups, W.LogoHooks}) do
			table.clear(t)
		end
		W.CurrentPage, W.ConfigPage = nil, nil
		if Library.ActiveWindow == Window then Library.ActiveWindow = nil end
	end)
	Window.Unload = Window.Destroy

	-- Also re-applies a theme that is replaced while active, or one passed as Theme = "..." to
	-- CreateWindow before it was added with AddTheme.
	W.ThemeHook = function(name)
		if not W.Alive then return end
		if W.ThemeDropdown then W.ThemeDropdown.SetOptions(CopyList(Library.ThemeOrder), true) end
		if name and (name == W.ThemeName or (name == W.RequestedTheme and W.ThemeName ~= name)) then
			W.SetTheme(name)
		end
	end
	table.insert(ThemeHooks, W.ThemeHook)
	if o.Configs then Window.EnableConfigs(type(o.Configs) == "table" and o.Configs or nil) end

	local KS = keyInfo and keyInfo.Key and {
		Key = keyInfo.Key, Expires = keyInfo.Expires, Activated = keyInfo.Activated, Valid = true,
		Source = keyInfo.Source, Note = keyInfo.Note, Hwid = keyInfo.Hwid,
	}
	local expireHooks, acceptHooks = {}, {}
	Method(Window, "IsKeyValid", function() return KS == nil or KS.Valid end)
	Method(Window, "GetKeyInfo", function()
		if not KS then return nil end
		return {
			Key = KS.Key, Valid = KS.Valid, Expires = KS.Expires, Activated = KS.Activated,
			Remaining = KS.Expires and math.max(0, KS.Expires - Now()) or nil,
			Source = KS.Source, Note = KS.Note, Hwid = KS.Hwid,
		}
	end)
	Method(Window, "OnKeyExpired", function(fn) table.insert(expireHooks, fn) end)
	Method(Window, "OnKeyAccepted", function(fn) table.insert(acceptHooks, fn) end)
	Method(Window, "CheckKey", function() end)
	Method(Window, "ExpireKey", function() end)
	Method(Window, "ForgetKey", function() if keyCtx and keyCtx.Backend then keyCtx.Backend.Forget() end end)
	if KS then
		local backend = keyCtx.Backend
		local interval = keyCfg.CheckInterval
		if interval == nil then interval = (keyCfg.Url or keyCfg.Verify) and 60 or false end
		interval = interval and math.max(tonumber(interval) or 60, 5)
		local lastCheck, checking, warned = os.clock(), false, {}
		local WARN_AT = {300, 60}

		-- Locks the menu and asks for a new key; closing that prompt unloads the window.
		local function Expire(reason)
			if not W.Alive or not KS.Valid then return end
			KS.Valid = false
			W.KeyLocked = true
			reason = reason or "Your key has expired"
			backend.Forget()
			W.SetShown(false)
			if keyCfg.ResetOnExpire ~= false then W.ResetElements() end
			W.WM.ApplyLock()
			if W.KBList then W.KBList.Refresh() end
			SafeCall(keyCfg.OnExpire, reason)
			for _, fn in ipairs(expireHooks) do SafeCall(fn, reason) end
			W.Maid:Spawn(function()
				VKB.SetReady(false)
				local ctx2 = setmetatable({
					Reason = reason,
					SkipSaved = true,
					Theme = W.ThemeName, Accent = W.Accent, AccentAlpha = W.AccentAlpha,
					OnGui = function(g) W.KeyGui = g end,
				}, {__index = keyCtx})
				local ok, info = RunKeySystem(keyCfg, ctx2)
				W.KeyGui = nil
				if not W.Alive then return end
				if not ok then
					Window.Destroy()
					return
				end
				KS.Key, KS.Expires, KS.Activated, KS.Valid = info.Key, info.Expires, info.Activated, true
				KS.Source, KS.Note = info.Source, info.Note
				table.clear(warned)
				lastCheck = os.clock()
				W.KeyLocked = false
				W.WM.ApplyLock()
				if W.KBList then W.KBList.Refresh() end
				W.SetShown(true)
				VKB.SetReady(true)
				for _, fn in ipairs(acceptHooks) do SafeCall(fn, Window.GetKeyInfo()) end
				Window.Notify({Title = "Key", Content = "Key accepted", Icon = {"key-round", "key"}})
			end)
		end
		local function Recheck()
			if checking or not KS.Valid then return end
			checking = true
			local key = KS.Key
			W.Maid:Spawn(function()
				local valid, msg, exp, definitive = backend.Check(key, KS.Activated)
				checking = false
				lastCheck = os.clock()
				if not W.Alive or not KS.Valid or KS.Key ~= key then return end
				if valid then
					KS.Expires = exp
				elseif definitive or keyCfg.StrictOnline then
					Expire(msg == "Key expired" and "Your key has expired" or (msg or "Your key is no longer valid"))
				end
			end)
		end
		Method(Window, "CheckKey", Recheck)
		Method(Window, "ExpireKey", function(reason) Expire(reason) end)

		local keyLbl
		if keyCfg.ShowInSettings ~= false then
			local keySec = settingsApi.AddSection({Name = "Key", Side = "Right"})
			keyLbl = keySec.AddLabel("")
			keySec.AddButton({Name = "Check Key Now", Callback = function()
				Recheck()
				return "Checking..."
			end})
		end
		local function UpdateLabel()
			if not keyLbl then return end
			local k = tostring(KS.Key)
			local masked = (#k > 6 and k:sub(1, 4) or "") .. "••••"
			local state
			if not KS.Valid then
				state = "Expired"
			elseif KS.Expires then
				state = "Expires in " .. FormatDuration(KS.Expires - Now())
			else
				state = "Never expires"
			end
			keyLbl.Set("Key: " .. masked .. "   ·   " .. state)
		end

		W.Maid:Spawn(function()
			while W.Alive do
				if KS.Valid then
					local left = KS.Expires and (KS.Expires - Now())
					if left and left <= 0 then
						Expire("Your key has expired")
					else
						if left and keyCfg.Warn ~= false then
							local due = false
							for _, mark in ipairs(WARN_AT) do
								if left <= mark and not warned[mark] then
									warned[mark] = true
									due = true
								end
							end
							if due then
								Window.Notify({Title = "Key", Content = "Your key expires in " .. FormatDuration(left), Icon = {"key-round", "key"}, Duration = 5})
							end
						end
						if interval and os.clock() - lastCheck >= interval then Recheck() end
					end
				end
				UpdateLabel()
				task.wait(1)
			end
		end)
	end

	if o.Visible == false then
		W.SetShown(false, true)
	else
		W.Holder.Visible = false
		W.SetShown(true)
	end

	Library.ActiveWindow = Window
	table.insert(Library.Windows, Window)
	LiveWindows[guiKey] = Window.Destroy
	VKB.SetReady(true)
	return Window
end

Method(Library, "CreateWindow", function(o)
	o = Opts(o)
	local ok, res = pcall(CreateWindow, o)
	if ok then return res end
	-- Release a half-built window (its Maid owns everything created so far) before re-raising.
	local abort = LiveWindows[o.GuiName or Library.GuiName]
	if type(abort) == "function" then
		LiveWindows[o.GuiName or Library.GuiName] = nil
		pcall(abort)
	end
	error(res, 0)
end)
Method(Library, "KeySystem", function(ks, ctx) return RunKeySystem(ks, type(ctx) == "table" and ctx or {}) end)
Library.FormatDuration = FormatDuration
Library.Sha256 = Sha256
Library.HashKey = Sha256
Library.GetHwid = GetHwid
Library.Window = Library.CreateWindow
Library.new = Library.CreateWindow
Method(Library, "Notify", function(o)
	if Library.ActiveWindow then return Library.ActiveWindow.Notify(o) end
	return nil
end)
Method(Library, "Unload", function()
	for _, w in ipairs(CopyList(Library.Windows)) do w.Destroy() end
	VKB.Destroy()
end)
Library.Destroy = Library.Unload
Method(Library, "SetTheme", function(name)
	return Library.ActiveWindow ~= nil and Library.ActiveWindow.SetTheme(name)
end)

return Library
