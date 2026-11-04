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

	LogoTint = true,
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
-- Tab switching always uses Cross Dissolve: the old page fades out while the new one fades in
-- on top of it, both visible at once.
local PAGE_FADE_TI = TweenInfo.new(0.32, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
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

-- Logo spec (every field optional; a plain string / number / icon list is detected automatically):
--   Text | Image | Icon   what to draw
--   Size      header logo in px. A number scales every slot proportionally; a table sets slots
--             one by one: {Header = 18, Watermark = 14, Panel = 12, Key = 18}
--   TextSize  text logos: a number for every slot, or a per-slot table (default follows Size)
--   Aspect    width / height for wide images (default 1)
--   Tint      true: follows the accent (default, images too); false: image keeps its own colours,
--             text/icons use the theme text colour; Color3 or "#hex": fixed colour
--   Color     fixed colour (same as Tint = Color3)
--   Corner    corner radius for images
--   Visible   false hides the logo; a per-slot table hides it in some places: {Watermark = false}
local NormalizeLogo, CreateLogo
do
	-- slot = {default px, default text size, max px}
	local LOGO_SLOTS = {
		Header = {12, 15, 30}, Key = {12, 15, 30},
		Watermark = {10, 12, 22}, Panel = {10, 12, 22},
	}

	local function SlotValue(v, slot, def, base)
		if typeof(v) == "Vector2" then v = v.Y end
		if type(v) == "table" then
			local own = tonumber(v[slot])
			if own then return own end
			v = v.Header or v.Default or v.All
		end
		local n = tonumber(v)
		if not n then return nil end
		return n * def / base
	end

	function NormalizeLogo(spec, title, style)
		local out
		if type(spec) == "number" then
			out = {Image = spec}
		elseif type(spec) == "string" and spec ~= "" then
			if IsImage(spec) then
				out = {Image = spec}
			elseif #spec <= 2 then
				out = {Text = spec}
			else
				out = {Icon = spec}
			end
		elseif type(spec) == "table" then
			out = {}
			if spec[1] ~= nil then out.Icon = CopyList(spec) end
			for k, v in pairs(spec) do
				if type(k) == "string" then out[k] = v end
			end
		else
			out = {}
		end
		if out.Text == nil and out.Image == nil and out.Icon == nil then
			local first = tostring(title or "Z"):match("[%w]") or "Z"
			out.Text = first:upper()
			out.Auto = true
		end
		if type(style) == "table" then
			for k, v in pairs(style) do
				if out[k] == nil then out[k] = v end
			end
		end
		return out
	end

	-- slot: "Header", "Watermark", "Panel" or "Key". Returns the frame and its fade list.
	function CreateLogo(W, parent, spec, slot)
		local d = LOGO_SLOTS[slot] or LOGO_SLOTS.Header
		local size = SlotValue(spec.Size, slot, d[1], 12) or d[1]
		size = math.clamp(math.floor(size + 0.5), 6, d[3])
		local aspect = tonumber(spec.Aspect)
		if typeof(spec.Size) == "Vector2" and spec.Size.Y > 0 then aspect = aspect or spec.Size.X / spec.Size.Y end
		aspect = math.clamp(aspect or 1, 0.25, 8)
		local vis = spec.Visible
		if type(vis) == "table" then vis = vis[slot] end

		local box = Create("Frame", {
			Size = UDim2.fromOffset(math.floor(size * aspect + 0.5), size),
			BackgroundTransparency = 1,
			Visible = vis ~= false,
			Parent = parent,
		})
		local fades = {}
		local fixed = ToColor(spec.Color)
		local tint = spec.Tint
		if typeof(tint) == "Color3" or type(tint) == "string" then
			fixed = fixed or ToColor(tint)
			tint = true
		end
		if tint == nil then tint = Library.LogoTint ~= false end
		local target, prop
		if spec.Text then
			local ts = SlotValue(spec.TextSize, slot, d[2], 15)
			if type(spec.TextSize) == "number" then ts = spec.TextSize end
			ts = math.floor((ts or d[2] * size / d[1]) + 0.5)
			box.Size = UDim2.fromOffset(0, math.max(size, ts))
			box.AutomaticSize = Enum.AutomaticSize.X
			local lbl = Label(box, spec.Text, {
				Size = UDim2.new(0, 0, 1, 0),
				AutoX = true,
				TextSize = ts,
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
			-- ImageColor3 multiplies the picture, so a white / light logo takes the exact accent colour.
			if not (spec.Image and tint == false and not fixed) then
				target, prop = img, "ImageColor3"
			end
			table.insert(fades, {img, "ImageTransparency", 0})
		end
		if fixed and target then
			target[prop] = fixed
		elseif target and tint == false then
			W.Bind(function(T) target[prop] = T.Text end, target)
		elseif target then
			W.Bind(function(_, accent) target[prop] = accent end, target)
		end
		return box, fades
	end
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
			logo = CreateLogo(W, brand, W.LogoSpec, "Panel")
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
	-- false / {Enabled = false}: no list at all (and no settings section);
	-- {Visible = false}: hidden until switched on; {ShowInSettings = false}: list without its settings section.
	if cfg == false then cfg = {Enabled = false} end
	if type(cfg) ~= "table" then cfg = {} end
	local touch = cfg.TouchMode
	if touch == nil then touch = TouchOnly() end
	local ROW_H = touch and 30 or 22
	local LIST_W = touch and 214 or 190

	local L = {
		Entries = {}, Wanted = cfg.Visible ~= false, ShowInactive = cfg.ShowInactive ~= false, Collapsed = false,
		Enabled = cfg.Enabled ~= false, InSettings = cfg.ShowInSettings ~= false,
	}
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
		SetShown(L.Enabled and L.Wanted and any and not W.KeyLocked, not instant)
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
	Method(api, "GetShowInactive", function() return L.ShowInactive end)
	-- Disabled: the list never shows and its settings section is removed; keybinds keep working.
	Method(api, "SetEnabled", function(b)
		L.Enabled = b ~= false
		L.Refresh()
		if W.ApplySettings then W.ApplySettings() end
	end)
	Method(api, "IsEnabled", function() return L.Enabled end)
	Method(api, "SetShowInSettings", function(b)
		L.InSettings = b ~= false
		if W.ApplySettings then W.ApplySettings() end
	end)
	Method(api, "GetShowInSettings", function() return L.InSettings end)
	Method(api, "SetCollapsed", function(b) L.Collapsed = b == true L.Refresh() end)
	Method(api, "IsCollapsed", function() return L.Collapsed end)
	Method(api, "SetTitle", function(t) title.Text = tostring(t) end)
	Method(api, "SetPosition", function(p) root.Position = p end)
	Method(api, "GetPosition", function() return root.Position end)
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
	Method(S, "IsVisible", function() return card.Visible end)
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
		local sc = W.Scale.Scale
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
		local box, fades = CreateLogo(W, frame, W.LogoSpec, "Watermark")
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
		W.HeaderLogo = CreateLogo(W, brand, W.LogoSpec, "Header")
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

	local PageTweens = {}
	local SwitchToken = 0
	local CROSS = "Cross Dissolve"

	function W.GetTransition() return CROSS end
	function W.SetTransition(name) return name == CROSS end

	-- Each page fades inside its own temporary CanvasGroup; wrappers exist only mid-fade, so text
	-- stays crisp at rest.
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
	local function Settle(p, show)
		p.Leaving = nil
		if not show then p.Show(false) end
		Unwrap(p)
	end

	function W.ShowPage(page, animate)
		SwitchToken = SwitchToken + 1
		local token = SwitchToken
		for _, t in ipairs(PageTweens) do t:Cancel() end
		table.clear(PageTweens)
		local old = W.CurrentPage

		local function Cut()
			for _, p in ipairs(W.Pages) do
				if p ~= page then Settle(p, false) end
			end
			Settle(page, true)
			page.ScrollTo(0, true)
			page.Show(true)
		end

		if not animate or not old or old == page then
			Cut()
			return
		end

		-- Coming back to a page that is still fading out: continue from its current opacity.
		local back = page.wrap ~= nil and page.scroll.Visible
		if not back then
			Unwrap(page)
			page.ScrollTo(0, true)
		end
		page.Leaving = nil
		local inGroup = Wrap(page, 1)
		if not inGroup then
			Cut()
			return
		end
		if not back then inGroup.GroupTransparency = 1 end
		inGroup.ZIndex = 3

		local leaving = {}
		for _, p in ipairs(W.Pages) do
			if p ~= page then
				local g = p.scroll.Visible and Wrap(p, 0)
				if g then
					g.ZIndex = 2
					-- Keeps rendering while it fades, but its scrollbar and bottom fade hide at once.
					p.Leaving = true
					p.Update()
					table.insert(leaving, p)
					table.insert(PageTweens, Tween(g, PAGE_FADE_TI, {GroupTransparency = 1}))
				else
					Settle(p, false)
				end
			end
		end
		page.Show(true)
		local t = Tween(inGroup, PAGE_FADE_TI, {GroupTransparency = 0})
		table.insert(PageTweens, t)
		t.Completed:Connect(function(state)
			if state ~= Enum.PlaybackState.Completed or token ~= SwitchToken or not W.Alive then return end
			for _, p in ipairs(leaving) do Settle(p, false) end
			Unwrap(page)
		end)
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
		if W.Emit then
			if type(main) == "table" then
				local cur = main.CurSub
				W.Emit("tab", main.Name, main.Api, cur and cur.Api or nil)
			else
				W.Emit("tab", main == "configs" and "Configs" or "Settings")
			end
		end
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
	tab.Api = api
	AttachSections(W, api, tab.Page)
	Method(api, "Select", function() W.Navigate(tab) end)
	Method(api, "IsSelected", function() return W.Nav.main == tab end)
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
		sub.Api = sapi
		AttachSections(W, sapi, sub.Page)
		Method(sapi, "Select", function() W.Navigate(tab, sub) end)
		Method(sapi, "IsSelected", function() return W.Nav.main == tab and tab.CurSub == sub end)
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

-- Built-in settings. Every section and item has an id; CreateWindow({Settings = {Id = false}}) or
-- Window.Settings.SetVisible(id, false) removes it, and a section disappears once all of its
-- items are hidden. "MenuKeybind" (a "Menu Key" bind for the toggle key) is opt-in.
local function BuildSettings(W, o)
	local page = NewPage(W)
	W.SettingsPage = page
	local api = AttachSections(W, {}, page)
	W.SettingsApi = api

	local LAYOUT = {
		{"Appearance", {"Theme", "Accent"}},
		{"Interface", {"Scale", "Scrollbar", "MenuKeybind"}},
		{"Watermark", {"WatermarkOpacity", "WatermarkIcons", "WatermarkDetails"}},
		{"KeybindList", {"KeybindListVisible", "KeybindListInactive"}},
		{"Key", {"KeyStatus", "KeyCheck"}},
	}
	local ALIAS = {
		accentcolor = "Accent", uiscale = "Scale", scrollbarsize = "Scrollbar",
		menukey = "MenuKeybind", menubind = "MenuKeybind", togglekey = "MenuKeybind", menutoggle = "MenuKeybind",
		keybinds = "KeybindList", keybindslist = "KeybindList", kblist = "KeybindList",
		showlist = "KeybindListVisible", showinactive = "KeybindListInactive",
		wmopacity = "WatermarkOpacity", wmicons = "WatermarkIcons", wmdetails = "WatermarkDetails",
		keysystem = "Key", checkkey = "KeyCheck",
	}
	for _, sec in ipairs(LAYOUT) do
		ALIAS[sec[1]:lower()] = sec[1]
		for _, id in ipairs(sec[2]) do ALIAS[id:lower()] = id end
	end
	-- Case, spaces, "_" and "-" are ignored: "Keybind List", "keybind_list" and "KeybindList" match.
	local function Canon(id)
		if type(id) ~= "string" then return nil end
		return ALIAS[(id:lower():gsub("[%s_%-]", ""))]
	end
	local shown = {MenuKeybind = false}
	local function Configure(t)
		if t == false then
			for _, sec in ipairs(LAYOUT) do shown[sec[1]] = false end
			return
		end
		if type(t) ~= "table" then return end
		for k, v in pairs(t) do
			local id = Canon(k)
			if id then shown[id] = v ~= false end
		end
		for _, pair in ipairs({{t.Hide, false}, {t.Show, true}}) do
			if type(pair[1]) == "table" then
				for _, k in ipairs(pair[1]) do
					local id = Canon(k)
					if id then shown[id] = pair[2] end
				end
			end
		end
	end
	Configure(o.Settings)
	local secs, items = {}, {}
	W.SettingsSections, W.SettingsItems = secs, items

	secs.Appearance = NewSection(W, page, {Name = "Appearance", Side = "Left"})
	W.ThemeDropdown = secs.Appearance.AddDropdown({
		Name = "Theme", Icon = "moon",
		Options = CopyList(Library.ThemeOrder), Default = W.ThemeName,
		Flag = "__ZeninTheme",
		Callback = function(v) W.SetTheme(v) end,
	})
	items.Theme = W.ThemeDropdown
	items.Accent = AccentPicker(W, secs.Appearance, "Accent Color")

	secs.Interface = NewSection(W, page, {Name = "Interface", Side = "Left"})
	W.ScaleDropdown = secs.Interface.AddDropdown({
		Name = "UI Scale", Icon = {"expand", "maximize-2"},
		Options = SCALE_OPTIONS, Default = ScaleLabelFor(o.Scale),
		Flag = "__ZeninScale",
		Callback = function(v) W.SetScale(SCALE_MAP[v] or 1, true) end,
	})
	items.Scale = W.ScaleDropdown
	W.ScrollSlider = secs.Interface.AddSlider({
		Name = "Scrollbar Size", Min = 3, Max = 24, Default = W.BarW, Suffix = "px",
		Flag = "__ZeninScrollbar",
		Callback = function(v) W.SetBarWidth(v) end,
	})
	items.Scrollbar = W.ScrollSlider

	secs.Watermark = NewSection(W, page, {Name = "Watermark", Side = "Right"})
	W.WmOpacity = secs.Watermark.AddSlider({
		Name = "Opacity", Min = 0, Max = 100, Default = 100, Suffix = "%",
		Flag = "__ZeninWmOpacity",
		Callback = function(v)
			W.WM.Opacity = v / 100
			W.WM.ApplyOpacity()
		end,
	})
	W.WmIcons = secs.Watermark.AddToggle({
		Name = "Show Icons", Default = true,
		Flag = "__ZeninWmIcons",
		Callback = function(v) W.WM.SetIconsVisible(v) end,
	})
	W.WmDetails = secs.Watermark.AddMultiDropdown({
		Name = "Details", Options = DETAIL_MODES, Default = W.WM.GetModes(),
		Flag = "__ZeninWmDetails",
		Callback = function(v) W.WM.SetModes(v) end,
	})
	items.WatermarkOpacity, items.WatermarkIcons, items.WatermarkDetails = W.WmOpacity, W.WmIcons, W.WmDetails

	if W.KBList then
		secs.KeybindList = NewSection(W, page, {Name = "Keybind List", Side = "Right"})
		W.KbListToggle = secs.KeybindList.AddToggle({
			Name = "Show List", Default = W.KBList.Wanted,
			Flag = "__ZeninKbList",
			Callback = function(v) W.KeybindListApi.SetVisible(v) end,
		})
		W.KbInactiveToggle = secs.KeybindList.AddToggle({
			Name = "Show Inactive", Default = W.KBList.ShowInactive,
			Flag = "__ZeninKbInactive",
			Callback = function(v) W.KeybindListApi.SetShowInactive(v) end,
		})
		items.KeybindListVisible, items.KeybindListInactive = W.KbListToggle, W.KbInactiveToggle
	end

	-- The bind itself toggles the window (modifiers included), so the plain ToggleKey listener
	-- steps aside while it exists. Hiding it later keeps the bind working.
	function W.EnsureMenuKeybind()
		if W.MenuKeybind or not W.Alive then return W.MenuKeybind end
		local el = secs.Interface.AddKeybind({
			Name = "Menu Key", Default = W.ToggleKey,
			Mode = "Press", Modes = {"Press"}, ShowMode = false,
			ShowInList = false, TouchTrigger = false,
			Flag = "__ZeninMenuKey",
			Callback = function()
				if W.Window and not W.KeyLocked then W.Window.Toggle() end
			end,
		})
		table.insert(el._deps, function(k)
			if W.ToggleKey == k then return end
			W.ToggleKey = k
			if W.Emit then W.Emit("togglekey", k) end
		end)
		W.MenuKeybind = el
		items.MenuKeybind = el
		return el
	end

	function W.ApplySettings()
		if not W.Alive then return end
		for _, sec in ipairs(LAYOUT) do
			local sid = sec[1]
			local S = secs[sid]
			if S then
				local any = false
				for _, id in ipairs(sec[2]) do
					local el = items[id]
					if el then
						local on = shown[id] ~= false
						if el.IsVisible() ~= on then el.SetVisible(on) end
						any = any or on
					end
				end
				local on = shown[sid] ~= false and any
				if sid == "KeybindList" and W.KBList then on = on and W.KBList.Enabled and W.KBList.InSettings end
				S.SetVisible(on)
			end
		end
	end
	-- Lets later built-ins (the key section) join the same visibility rules.
	function W.RegisterSettings(sid, S, list)
		secs[sid] = S
		for id, el in pairs(list or {}) do items[id] = el end
		W.ApplySettings()
	end

	local function SetShown(id, b)
		local c = Canon(id)
		if not c then return false end
		shown[c] = b ~= false
		if c == "MenuKeybind" and shown[c] then W.EnsureMenuKeybind() end
		W.ApplySettings()
		return true
	end
	Method(api, "SetVisible", SetShown)
	Method(api, "Show", function(id) return SetShown(id, true) end)
	Method(api, "Hide", function(id) return SetShown(id, false) end)
	api.Remove = api.Hide
	Method(api, "IsVisible", function(id)
		local c = Canon(id)
		local x = c and (secs[c] or items[c])
		return x ~= nil and x.IsVisible() == true
	end)
	-- The built-in section or element behind an id (nil if it doesn't exist, e.g. "Key" without a key system).
	Method(api, "Get", function(id)
		local c = Canon(id)
		return c and (secs[c] or items[c]) or nil
	end)
	Method(api, "Configure", function(t)
		Configure(t)
		if shown.MenuKeybind then W.EnsureMenuKeybind() end
		W.ApplySettings()
	end)
	Method(api, "GetIds", function()
		local out = {}
		for _, sec in ipairs(LAYOUT) do
			table.insert(out, sec[1])
			for _, id in ipairs(sec[2]) do table.insert(out, id) end
		end
		return out
	end)
	Method(api, "Select", function() W.Navigate("settings") end)

	if shown.MenuKeybind then W.EnsureMenuKeybind() end
	W.ApplySettings()
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
	local logo = CreateLogo(K, brand, NormalizeLogo(ks.Logo or ctx.Logo, title, ctx.LogoStyle), "Key")
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
	-- Window-wide logo defaults; fields set on the Logo table itself win.
	local logoStyle = {Size = o.LogoSize, Tint = o.LogoTint, Color = o.LogoColor}
	-- Runs before any window or API exists, so nothing below is reachable until a key passes.
	local keyCfg, keyCtx, keyInfo
	if o.KeySystem and o.KeySystem ~= false then
		keyCfg = o.KeySystem == true and {} or o.KeySystem
		keyCtx = {
			Theme = o.Theme, Accent = o.Accent, AccentAlpha = o.AccentAlpha,
			Title = o.Title, Logo = o.Logo or o.Icon, LogoStyle = logoStyle, Parent = o.Parent, GuiName = o.GuiName,
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
		NotifyOrder = 0,
		ConfigFolder = o.ConfigFolder or Library.ConfigFolder,
	}
	W.LogoStyle = logoStyle
	W.LogoSpec = NormalizeLogo(o.Logo or o.Icon, W.Title, logoStyle)
	-- Size / Tint / Color / Visible carry over when Window.SetLogo swaps the picture.
	function W.CaptureLogoStyle()
		for _, k in ipairs({"Size", "Tint", "Color", "Visible"}) do W.LogoStyle[k] = W.LogoSpec[k] end
	end
	W.CaptureLogoStyle()
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
	-- Window events (Window.On). Names are case-insensitive; "On" / "Changed" are optional.
	W.Events = {}
	function W.EventName(name)
		local k = tostring(name or ""):lower():gsub("[%s_%-]", ""):gsub("^on", ""):gsub("changed$", "")
		local alias = {visible = "visibility", toggle = "visibility", toggled = "visibility", shown = "visibility",
			navigate = "tab", page = "tab", subtab = "tab", key = "togglekey", menukey = "togglekey", destroy = "unload"}
		return alias[k] or k
	end
	function W.Emit(name, ...)
		local list = W.Events[name]
		if not list then return end
		for _, fn in ipairs(CopyList(list)) do SafeCall(fn, ...) end
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
		if changed then
			W.Refresh()
			W.Emit("accent", W.Accent, W.AccentAlpha)
		end
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
		W.Emit("theme", name)
		return true
	end
	function W.SetScale(s, animate)
		s = math.clamp(tonumber(s) or 1, 0.3, 3)
		local changed = W.UserScale ~= s
		W.UserScale = s
		if W.ScaleDropdown and SCALE_MAP[W.ScaleDropdown.Get()] ~= s then W.ScaleDropdown.Set(ScaleLabelFor(s), true) end
		if changed then W.Emit("scale", s) end
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

	local function ShowNow(show, instant)
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
	function W.SetShown(show, instant)
		if not W.Alive then return end
		show = show ~= false
		if show and W.KeyLocked then return end
		local changed = W.Visible ~= show
		W.Visible = show
		ShowNow(show, instant)
		if changed then W.Emit("visibility", show) end
	end
	local settingsApi = BuildSettings(W, o)
	if o.Scale then W.SetScale(o.Scale) end
	W.RefreshNav(true)

	W.Connect(UserInputService.InputBegan, function(input, gp)
		-- The settings "Menu Key" bind does the toggling itself while it exists.
		if W.MenuKeybind or W.Capturing or W.LastCaptured == input then return end
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
		-- The automatic logo is the title's first letter.
		if W.LogoSpec.Auto then W.SetLogoSpec(nil) end
	end)
	Method(Window, "GetTitle", function() return W.Title end)

	-- Logo: header, watermark, element settings panels (and the key prompt on re-checks).
	function W.RebuildLogos()
		if not W.Alive then return end
		W.BuildHeaderLogo()
		W.WM.BuildLogo()
		for _, fn in ipairs(CopyList(W.LogoHooks)) do SafeCall(fn) end
		W.Emit("logo", Window.GetLogo())
	end
	function W.SetLogoSpec(spec)
		W.LogoSpec = NormalizeLogo(spec, W.Title, W.LogoStyle)
		W.CaptureLogoStyle()
		W.RebuildLogos()
	end
	function W.SetLogoField(k, v)
		W.LogoStyle[k] = v
		W.LogoSpec[k] = v
		W.RebuildLogos()
	end
	Method(Window, "SetLogo", function(spec) W.SetLogoSpec(spec) end)
	Method(Window, "GetLogo", function()
		local out = {}
		for k, v in pairs(W.LogoSpec) do out[k] = v end
		out.Auto = nil
		return out
	end)
	-- px for the header logo (others scale with it) or a per-slot table; nil restores the default.
	Method(Window, "SetLogoSize", function(px) W.SetLogoField("Size", px) end)
	Method(Window, "GetLogoSize", function() return W.LogoSpec.Size or 12 end)
	-- true: accent colour (images too), false: original image colours, Color3 / "#hex": fixed colour.
	Method(Window, "SetLogoTint", function(v) W.SetLogoField("Tint", v) end)
	Method(Window, "SetLogoColor", function(c) W.SetLogoField("Color", c) end)
	-- false hides it; a table hides it per place: {Watermark = false, Panel = false}.
	Method(Window, "SetLogoVisible", function(b)
		if type(b) ~= "table" then b = b ~= false end
		W.SetLogoField("Visible", b)
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
	Method(Window, "GetTransitions", function() return {W.GetTransition()} end)
	Method(Window, "SetToggleKey", function(k)
		local key = ParseKey(k)
		if not key then return end
		if W.MenuKeybind then
			W.MenuKeybind.Set(key)
		elseif key ~= W.ToggleKey then
			W.ToggleKey = key
			W.Emit("togglekey", key)
		end
	end)
	Method(Window, "GetToggleKey", function() return W.ToggleKey end)
	Method(Window, "SetPosition", function(p) W.Holder.Position = p end)
	Method(Window, "GetPosition", function() return W.Holder.Position end)
	Method(Window, "Center", function()
		Tween(W.Holder, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0.5, 0.5)})
	end)
	Method(Window, "SetDisplayOrder", function(n) W.Gui.DisplayOrder = tonumber(n) or W.Gui.DisplayOrder end)
	Method(Window, "IsAlive", function() return W.Alive == true end)

	-- Events: Window.On(name, fn) -> connection with :Disconnect().
	--   "VisibilityChanged" (visible)    "ThemeChanged" (name)        "AccentChanged" (color, alpha)
	--   "ScaleChanged" (scale)           "TabChanged" (name, tab, subTab; "Settings"/"Configs" for built-ins)
	--   "ToggleKeyChanged" (key)         "LogoChanged" (logo)         "Unload" ()
	Method(Window, "On", function(name, fn)
		local conn = {Connected = false}
		Method(conn, "Disconnect", function() end)
		if type(fn) ~= "function" or not W.Alive then return conn end
		local key = W.EventName(name)
		W.Events[key] = W.Events[key] or {}
		table.insert(W.Events[key], fn)
		conn.Connected = true
		Method(conn, "Disconnect", function()
			conn.Connected = false
			local list = W.Events[key]
			local i = list and IndexOf(list, fn)
			if i then table.remove(list, i) end
		end)
		return conn
	end)
	for _, ev in ipairs({"VisibilityChanged", "ThemeChanged", "AccentChanged", "ScaleChanged", "TabChanged", "ToggleKeyChanged", "LogoChanged"}) do
		Method(Window, "On" .. ev, function(fn) return Window.On(ev, fn) end)
	end

	-- Tabs by name, index or the tab object itself.
	local function FindTab(ref)
		if type(ref) == "number" then return W.Tabs[ref] end
		for _, t in ipairs(W.Tabs) do
			if t.Api == ref or t.Name == ref then return t end
		end
		if type(ref) == "string" then
			local low = ref:lower()
			for _, t in ipairs(W.Tabs) do
				if tostring(t.Name):lower() == low then return t end
			end
		end
		return nil
	end
	Method(Window, "GetTabs", function()
		local out = {}
		for _, t in ipairs(W.Tabs) do table.insert(out, t.Api) end
		return out
	end)
	Method(Window, "GetTab", function(ref)
		local t = FindTab(ref)
		return t and t.Api or nil
	end)
	Method(Window, "SelectTab", function(ref)
		local t = FindTab(ref)
		if not t then return false end
		W.Navigate(t)
		return true
	end)
	-- The open tab object, or nil plus "Settings" / "Configs" while a built-in page is open.
	Method(Window, "GetActiveTab", function()
		local m = W.Nav.main
		if type(m) == "table" then return m.Api, m.CurSub and m.CurSub.Api or nil end
		return nil, m == "configs" and "Configs" or "Settings"
	end)
	Method(Window, "GetKeybinds", function() return CopyList(W.Keybinds) end)
	-- Built-in keybind list on/off at runtime (the KeybindList = false option does it at creation).
	Method(Window, "SetKeybindListEnabled", function(b) W.KeybindListApi.SetEnabled(b) end)
	-- Shortcuts for Window.Settings.SetVisible(id, b): hide built-in settings sections or items.
	Method(Window, "SetSettingVisible", function(id, b) return settingsApi.SetVisible(id, b) end)
	Method(Window, "ConfigureSettings", function(t) settingsApi.Configure(t) end)

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
		W.Emit("unload")
		table.clear(W.Events)
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
					Logo = W.LogoSpec, LogoStyle = W.LogoStyle,
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
			local keyBtn = keySec.AddButton({Name = "Check Key Now", Callback = function()
				Recheck()
				return "Checking..."
			end})
			W.RegisterSettings("Key", keySec, {KeyStatus = keyLbl, KeyCheck = keyBtn})
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
	-- Extended API (Zenin+) attaches its window methods here.
	for _, hook in ipairs(rawget(Library, "_WindowHooks") or {}) do SafeCall(hook, Window, W) end
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
-- Flag helpers: the element behind a flag, its current value, or set it (same as element.Set).
Method(Library, "GetOption", function(flag) return Library.Options[flag] end)
Method(Library, "GetFlag", function(flag) return Library.Flags[flag] end)
Method(Library, "SetFlag", function(flag, value)
	local el = Library.Options[flag]
	if not el then return false end
	ApplyFlag(el, value)
	return true
end)
Method(Library, "OnFlagChanged", function(flag, fn)
	local el = Library.Options[flag]
	if el and el.OnChanged then el.OnChanged(fn) return true end
	return false
end)
Method(Library, "GetWindows", function() return CopyList(Library.Windows) end)


-- =====================================================================================
-- Zenin+ extended API.
-- Everything below lives in one do-block with a single local (X) so the chunk stays far
-- below Luau's 200-local limit; every builder is its own function with its own locals.
-- Call Library.Help() in the console for a grouped list of every extended function.
-- =====================================================================================
do -- extended API
local X = {
	Maid = Maid.new(),
	Docs = {},
	Groups = {},
	Win = setmetatable({}, {__mode = "k"}),
	Sec = setmetatable({}, {__mode = "k"}),
}
Library.ApiVersion = "2.0.0"
Library._WindowHooks = Library._WindowHooks or {}

-- Docs: X.Doc(group, signature, description). Def also installs the function with Method().
function X.Doc(group, sig, desc)
	local g = X.Docs[group]
	if not g then
		g = {}
		X.Docs[group] = g
		table.insert(X.Groups, group)
	end
	table.insert(g, {Signature = sig, Description = desc or ""})
end
function X.Def(obj, group, name, sig, desc, fn)
	Method(obj, name, fn)
	X.Doc(group, sig, desc)
	return obj[name]
end

-- Shared colours for status-like elements (alerts, logs, statuses, notifications).
X.Tones = {
	info = Color3.fromRGB(96, 165, 250),
	success = Color3.fromRGB(74, 222, 128),
	warning = Color3.fromRGB(250, 204, 21),
	error = Color3.fromRGB(248, 113, 113),
	debug = Color3.fromRGB(150, 150, 160),
}
X.ToneIcons = {info = "info", success = "circle-check", warning = "triangle-alert", error = "circle-x", debug = "bug"}
function X.Tone(kind)
	kind = tostring(kind or "info"):lower()
	if kind == "warn" then kind = "warning" end
	if kind == "err" or kind == "danger" or kind == "fail" then kind = "error" end
	if kind == "ok" or kind == "done" then kind = "success" end
	if not X.Tones[kind] then kind = "info" end
	return kind, X.Tones[kind], X.ToneIcons[kind]
end

function X.Clipboard(text)
	text = tostring(text or "")
	local fn = (type(setclipboard) == "function" and setclipboard)
		or (type(toclipboard) == "function" and toclipboard)
		or (type(set_clipboard) == "function" and set_clipboard)
		or (type(Clipboard) == "table" and type(Clipboard.set) == "function" and Clipboard.set)
	if not fn then return false end
	return (pcall(fn, text))
end

function X.EventKey(name)
	return (tostring(name or ""):lower():gsub("[%s_%-]", ""))
end

function X.BuildSignal()
	local Signal = {}
	function Signal.new()
		local sig = {_dead = false}
		local handlers = {}
		local function Connect(fn, once)
			local conn = {Connected = false}
			local entry = {fn = fn, once = once, conn = conn}
			Method(conn, "Disconnect", function()
				if not conn.Connected then return end
				conn.Connected = false
				local i = IndexOf(handlers, entry)
				if i then table.remove(handlers, i) end
			end)
			conn.Destroy = conn.Disconnect
			if type(fn) ~= "function" or sig._dead then return conn end
			conn.Connected = true
			table.insert(handlers, entry)
			return conn
		end
		Method(sig, "Connect", function(fn) return Connect(fn, false) end)
		Method(sig, "Once", function(fn) return Connect(fn, true) end)
		Method(sig, "Fire", function(...)
			if sig._dead then return end
			for _, e in ipairs(CopyList(handlers)) do
				if e.conn.Connected then
					if e.once then e.conn.Disconnect() end
					SafeCall(e.fn, ...)
				end
			end
		end)
		-- Yields until the next Fire (or timeout seconds); returns the fired arguments.
		Method(sig, "Wait", function(timeout)
			local thread = coroutine.running()
			local done = false
			local conn
			conn = Connect(function(...)
				if done then return end
				done = true
				task.spawn(thread, ...)
			end, true)
			if tonumber(timeout) then
				task.delay(tonumber(timeout), function()
					if done then return end
					done = true
					conn.Disconnect()
					task.spawn(thread)
				end)
			end
			return coroutine.yield()
		end)
		Method(sig, "DisconnectAll", function()
			for _, e in ipairs(CopyList(handlers)) do e.conn.Disconnect() end
		end)
		Method(sig, "GetCount", function() return #handlers end)
		Method(sig, "Destroy", function()
			sig.DisconnectAll()
			sig._dead = true
		end)
		sig.Event = sig
		return sig
	end
	Library.Signal = Signal
	X.Signal = Signal.new
	X.Def(Library, "Signals & events", "CreateSignal", "Library.CreateSignal() -> Signal",
		"New signal with Connect / Once / Wait(timeout) / Fire / DisconnectAll / GetCount / Destroy.", Signal.new)
	X.Doc("Signals & events", "Signal.Connect(fn) -> Connection", "Connection has Connected and Disconnect().")

	-- Global event bus. Built-in events: WindowCreated(window), FlagChanged(flag, value, old, element),
	-- Notify(options), ThemeAdded(name), LoopStarted(name), LoopStopped(name), Unload().
	local bus = {}
	local function Get(name)
		local k = X.EventKey(name)
		local s = bus[k]
		if not s then
			s = Signal.new()
			bus[k] = s
		end
		return s
	end
	function X.Emit(name, ...)
		local s = bus[X.EventKey(name)]
		if s then s.Fire(...) end
	end
	X.Def(Library, "Signals & events", "On", "Library.On(event, fn) -> Connection",
		"Listen to a global event (WindowCreated, FlagChanged, Notify, ThemeAdded, LoopStarted, LoopStopped, Unload or any custom name).",
		function(name, fn) return Get(name).Connect(fn) end)
	X.Def(Library, "Signals & events", "Once", "Library.Once(event, fn) -> Connection", "Like On, fires only once.",
		function(name, fn) return Get(name).Once(fn) end)
	X.Def(Library, "Signals & events", "WaitFor", "Library.WaitFor(event, timeout?) -> ...", "Yields until the event fires.",
		function(name, timeout) return Get(name).Wait(timeout) end)
	X.Def(Library, "Signals & events", "Emit", "Library.Emit(event, ...)", "Fire a global event (custom events welcome).",
		function(name, ...) X.Emit(name, ...) end)
	X.Def(Library, "Signals & events", "Off", "Library.Off(event)", "Disconnect every listener of an event.",
		function(name)
			local s = bus[X.EventKey(name)]
			if s then s.DisconnectAll() end
		end)
	X.Def(Library, "Signals & events", "GetEvents", "Library.GetEvents() -> {name = listeners}", "Events that currently have listeners.",
		function()
			local out = {}
			for k, s in pairs(bus) do
				if s.GetCount() > 0 then out[k] = s.GetCount() end
			end
			return out
		end)
end

function X.BuildUtilTables(U)
	local G = "Util: tables"
	local function D(name, sig, desc, fn) return X.Def(U, G, name, "Util." .. sig, desc, fn) end
	local Copy = D("Copy", "Copy(t) -> table", "Shallow copy.", function(t)
		local out = {}
		for k, v in pairs(t or {}) do out[k] = v end
		return out
	end)
	local function Deep(t, seen)
		if type(t) ~= "table" then return t end
		if seen[t] then return seen[t] end
		local out = {}
		seen[t] = out
		for k, v in pairs(t) do out[Deep(k, seen)] = Deep(v, seen) end
		return setmetatable(out, getmetatable(t))
	end
	D("DeepCopy", "DeepCopy(t) -> table", "Recursive copy (handles cycles).", function(t) return Deep(t, {}) end)
	local function Merge(dst, src, deep)
		for k, v in pairs(src or {}) do
			if deep and type(v) == "table" and type(dst[k]) == "table" then
				Merge(dst[k], v, true)
			else
				dst[k] = v
			end
		end
		return dst
	end
	D("Merge", "Merge(dst, src, deep?) -> dst", "Copies src fields into dst (recursively when deep).", Merge)
	D("Defaults", "Defaults(t, defaults) -> t", "Fills missing fields of t from defaults.", function(t, defs)
		t = t or {}
		for k, v in pairs(defs or {}) do
			if t[k] == nil then t[k] = v end
		end
		return t
	end)
	D("Keys", "Keys(t) -> list", "Keys of a table.", function(t)
		local out = {}
		for k in pairs(t or {}) do table.insert(out, k) end
		return out
	end)
	D("Values", "Values(t) -> list", "Values of a table.", function(t)
		local out = {}
		for _, v in pairs(t or {}) do table.insert(out, v) end
		return out
	end)
	D("Count", "Count(t) -> number", "Number of entries (works for dictionaries).", function(t)
		local n = 0
		for _ in pairs(t or {}) do n = n + 1 end
		return n
	end)
	D("IsEmpty", "IsEmpty(t) -> bool", "True when the table has no entries.", function(t) return t == nil or next(t) == nil end)
	D("Map", "Map(t, fn(v, k)) -> table", "New table with fn applied to every value.", function(t, fn)
		local out = {}
		for k, v in pairs(t or {}) do out[k] = fn(v, k) end
		return out
	end)
	D("Filter", "Filter(list, fn(v, i)) -> list", "Values for which fn returns true.", function(t, fn)
		local out = {}
		for i, v in ipairs(t or {}) do
			if fn(v, i) then table.insert(out, v) end
		end
		return out
	end)
	D("Reduce", "Reduce(list, fn(acc, v, i), init) -> any", "Folds a list into one value.", function(t, fn, acc)
		for i, v in ipairs(t or {}) do acc = fn(acc, v, i) end
		return acc
	end)
	D("Find", "Find(t, fn(v, k)) -> value, key", "First entry for which fn returns true.", function(t, fn)
		for k, v in pairs(t or {}) do
			if fn(v, k) then return v, k end
		end
		return nil
	end)
	D("Includes", "Includes(t, value) -> bool", "Whether any value equals value.", function(t, value)
		for _, v in pairs(t or {}) do
			if v == value then return true end
		end
		return false
	end)
	D("IndexOf", "IndexOf(list, value) -> index?", "Position of value in a list.", function(t, v) return IndexOf(t or {}, v) end)
	D("Remove", "Remove(list, value) -> bool", "Removes the first occurrence of value.", function(t, v)
		local i = IndexOf(t or {}, v)
		if i then table.remove(t, i) return true end
		return false
	end)
	D("Reverse", "Reverse(list) -> list", "Reversed copy.", function(t)
		local out = {}
		for i = #t, 1, -1 do table.insert(out, t[i]) end
		return out
	end)
	D("Slice", "Slice(list, from, to?) -> list", "Sub-list (negative indices count from the end).", function(t, i, j)
		local n = #t
		i = tonumber(i) or 1
		j = tonumber(j) or n
		if i < 0 then i = n + i + 1 end
		if j < 0 then j = n + j + 1 end
		local out = {}
		for k = math.max(i, 1), math.min(j, n) do table.insert(out, t[k]) end
		return out
	end)
	D("Shuffle", "Shuffle(list) -> list", "Shuffled copy.", function(t)
		local out = CopyList(t)
		for i = #out, 2, -1 do
			local j = math.random(i)
			out[i], out[j] = out[j], out[i]
		end
		return out
	end)
	D("Unique", "Unique(list) -> list", "Copy without duplicates (keeps first occurrence).", function(t)
		local seen, out = {}, {}
		for _, v in ipairs(t or {}) do
			if not seen[v] then
				seen[v] = true
				table.insert(out, v)
			end
		end
		return out
	end)
	local function Flatten(t, depth, out)
		for _, v in ipairs(t) do
			if type(v) == "table" and depth > 0 then Flatten(v, depth - 1, out) else table.insert(out, v) end
		end
		return out
	end
	D("Flatten", "Flatten(list, depth?) -> list", "Flattens nested lists (default depth: unlimited).", function(t, depth)
		return Flatten(t or {}, tonumber(depth) or math.huge, {})
	end)
	D("Chunk", "Chunk(list, size) -> {list}", "Splits a list into lists of size.", function(t, size)
		size = math.max(1, math.floor(tonumber(size) or 1))
		local out, cur = {}, nil
		for i, v in ipairs(t or {}) do
			if (i - 1) % size == 0 then
				cur = {}
				table.insert(out, cur)
			end
			table.insert(cur, v)
		end
		return out
	end)
	D("Range", "Range(from, to, step?) -> list", "Numeric list from..to.", function(a, b, step)
		step = tonumber(step) or 1
		local out = {}
		if step == 0 then return out end
		for i = a, b, step do table.insert(out, i) end
		return out
	end)
	D("Sum", "Sum(list) -> number", "Sum of numbers.", function(t)
		local s = 0
		for _, v in ipairs(t or {}) do s = s + (tonumber(v) or 0) end
		return s
	end)
	D("Average", "Average(list) -> number", "Mean of numbers (0 for an empty list).", function(t)
		if not t or #t == 0 then return 0 end
		local s = 0
		for _, v in ipairs(t) do s = s + (tonumber(v) or 0) end
		return s / #t
	end)
	D("Min", "Min(list) -> number?", "Smallest number.", function(t)
		local m
		for _, v in ipairs(t or {}) do
			if type(v) == "number" and (m == nil or v < m) then m = v end
		end
		return m
	end)
	D("Max", "Max(list) -> number?", "Largest number.", function(t)
		local m
		for _, v in ipairs(t or {}) do
			if type(v) == "number" and (m == nil or v > m) then m = v end
		end
		return m
	end)
	D("Pick", "Pick(list) -> value", "Random element.", function(t)
		if not t or #t == 0 then return nil end
		return t[math.random(#t)]
	end)
	D("Sort", "Sort(list, key|fn?, descending?) -> list", "Sorted copy. key: field name; fn: comparator.", function(t, by, desc)
		local out = CopyList(t)
		local cmp
		if type(by) == "function" then
			cmp = by
		elseif by ~= nil then
			cmp = function(a, b)
				if desc then return a[by] > b[by] end
				return a[by] < b[by]
			end
		else
			cmp = function(a, b)
				if desc then return a > b end
				return a < b
			end
		end
		table.sort(out, cmp)
		return out
	end)
	D("GroupBy", "GroupBy(list, fn(v) -> key) -> {key = list}", "Groups values by key.", function(t, fn)
		local out = {}
		for _, v in ipairs(t or {}) do
			local k = fn(v)
			out[k] = out[k] or {}
			table.insert(out[k], v)
		end
		return out
	end)
	local function Equals(a, b)
		if a == b then return true end
		if type(a) ~= "table" or type(b) ~= "table" then return false end
		for k, v in pairs(a) do
			if not Equals(v, b[k]) then return false end
		end
		for k in pairs(b) do
			if a[k] == nil then return false end
		end
		return true
	end
	D("Equals", "Equals(a, b) -> bool", "Deep equality.", Equals)
	X.Equals = Equals
	X.Copy = Copy
end

function X.BuildUtilStrings(U)
	local G = "Util: strings"
	local function D(name, sig, desc, fn) return X.Def(U, G, name, "Util." .. sig, desc, fn) end
	D("Trim", "Trim(s) -> string", "Removes surrounding whitespace.", function(s)
		return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
	end)
	D("Split", "Split(s, sep?, keepEmpty?) -> list", "Splits by a plain separator (default: whitespace).", function(s, sep, keep)
		s = tostring(s or "")
		local out = {}
		if sep == nil or sep == "" then
			for w in s:gmatch("%S+") do table.insert(out, w) end
			return out
		end
		local start = 1
		while true do
			local i, j = s:find(sep, start, true)
			if not i then
				local part = s:sub(start)
				if keep or part ~= "" then table.insert(out, part) end
				break
			end
			local part = s:sub(start, i - 1)
			if keep or part ~= "" then table.insert(out, part) end
			start = j + 1
		end
		return out
	end)
	D("StartsWith", "StartsWith(s, prefix) -> bool", "", function(s, p)
		s, p = tostring(s or ""), tostring(p or "")
		return s:sub(1, #p) == p
	end)
	D("EndsWith", "EndsWith(s, suffix) -> bool", "", function(s, p)
		s, p = tostring(s or ""), tostring(p or "")
		return p == "" or s:sub(-#p) == p
	end)
	D("Contains", "Contains(s, part, ignoreCase?) -> bool", "Plain substring search.", function(s, p, ic)
		s, p = tostring(s or ""), tostring(p or "")
		if ic then s, p = s:lower(), p:lower() end
		return s:find(p, 1, true) ~= nil
	end)
	D("Replace", "Replace(s, old, new) -> string", "Plain (non-pattern) replace of every occurrence.", function(s, old, new)
		s, old, new = tostring(s or ""), tostring(old or ""), tostring(new or "")
		if old == "" then return s end
		local out, start = {}, 1
		while true do
			local i, j = s:find(old, start, true)
			if not i then break end
			table.insert(out, s:sub(start, i - 1))
			table.insert(out, new)
			start = j + 1
		end
		table.insert(out, s:sub(start))
		return table.concat(out)
	end)
	D("Capitalize", "Capitalize(s) -> string", "First letter upper-case.", function(s)
		s = tostring(s or "")
		return s:sub(1, 1):upper() .. s:sub(2)
	end)
	D("TitleCase", "TitleCase(s) -> string", "Every word capitalized.", function(s)
		return (tostring(s or ""):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end))
	end)
	D("CamelToWords", "CamelToWords(s) -> string", "\"WalkSpeed\" -> \"Walk Speed\".", function(s)
		return (tostring(s or ""):gsub("(%l)(%u)", "%1 %2"))
	end)
	D("PadLeft", "PadLeft(s, length, char?) -> string", "", function(s, n, c)
		s = tostring(s or "")
		c = tostring(c or " "):sub(1, 1)
		return string.rep(c, math.max(0, (tonumber(n) or 0) - #s)) .. s
	end)
	D("PadRight", "PadRight(s, length, char?) -> string", "", function(s, n, c)
		s = tostring(s or "")
		c = tostring(c or " "):sub(1, 1)
		return s .. string.rep(c, math.max(0, (tonumber(n) or 0) - #s))
	end)
	D("Truncate", "Truncate(s, length, suffix?) -> string", "Shortens to length, adding suffix (default \"...\").", function(s, n, suf)
		s = tostring(s or "")
		n = tonumber(n) or #s
		suf = suf or "..."
		if #s <= n then return s end
		return s:sub(1, math.max(0, n - #suf)) .. suf
	end)
	local function Esc(s)
		return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;"))
	end
	X.Esc = Esc
	D("EscapeRich", "EscapeRich(s) -> string", "Escapes text for RichText labels.", Esc)
	D("StripRich", "StripRich(s) -> string", "Removes RichText tags.", function(s)
		return (tostring(s or ""):gsub("<[^>]->", ""))
	end)
	D("Colorize", "Colorize(text, color) -> string", "Wraps text in a RichText font colour tag.", function(text, c)
		c = ToColor(c) or WHITE
		return string.format('<font color="#%s">%s</font>', ToHex(c), tostring(text))
	end)
	D("Bold", "Bold(text) -> string", "RichText bold.", function(t) return "<b>" .. tostring(t) .. "</b>" end)
	D("Italic", "Italic(text) -> string", "RichText italic.", function(t) return "<i>" .. tostring(t) .. "</i>" end)
	D("Random", "Random(length?, charset?) -> string", "Random alphanumeric string.", function(n, set)
		set = set or "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
		local out = {}
		for i = 1, math.max(0, tonumber(n) or 8) do
			local k = math.random(#set)
			out[i] = set:sub(k, k)
		end
		return table.concat(out)
	end)
	D("Lines", "Lines(s) -> list", "Splits by newlines.", function(s)
		local out = {}
		for line in (tostring(s or "") .. "\n"):gmatch("(.-)\r?\n") do table.insert(out, line) end
		return out
	end)
	D("CountOf", "CountOf(s, part) -> number", "Plain occurrences of part.", function(s, p)
		s, p = tostring(s or ""), tostring(p or "")
		if p == "" then return 0 end
		local n, start = 0, 1
		while true do
			local i, j = s:find(p, start, true)
			if not i then return n end
			n = n + 1
			start = j + 1
		end
	end)
	-- Fuzzy score: 0 = no match; higher is better. Letters must appear in order.
	local function Fuzzy(s, q)
		s, q = tostring(s or ""):lower(), tostring(q or ""):lower()
		if q == "" then return 1 end
		if s == q then return 1000 end
		local plain = s:find(q, 1, true)
		if plain then return 500 - plain end
		local score, pos, streak = 0, 1, 0
		for i = 1, #q do
			local c = q:sub(i, i)
			local f = s:find(c, pos, true)
			if not f then return 0 end
			streak = (f == pos) and streak + 1 or 0
			score = score + 10 + streak * 5 - (f - pos)
			pos = f + 1
		end
		return math.max(score, 1)
	end
	X.Fuzzy = Fuzzy
	D("Fuzzy", "Fuzzy(text, query) -> score", "Fuzzy match score (0 means no match).", Fuzzy)
	D("FuzzySort", "FuzzySort(list, query, key?) -> list", "Matching items sorted by fuzzy score.", function(list, q, key)
		local scored = {}
		for _, v in ipairs(list or {}) do
			local sc = Fuzzy(key and v[key] or v, q)
			if sc > 0 then table.insert(scored, {v, sc}) end
		end
		table.sort(scored, function(a, b) return a[2] > b[2] end)
		local out = {}
		for i, p in ipairs(scored) do out[i] = p[1] end
		return out
	end)
	D("Slug", "Slug(s) -> string", "\"Auto Farm!\" -> \"auto-farm\".", function(s)
		return (tostring(s or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""))
	end)
end

function X.BuildUtilNumbers(U)
	local G = "Util: numbers & time"
	local function D(name, sig, desc, fn) return X.Def(U, G, name, "Util." .. sig, desc, fn) end
	local function Round(n, d)
		n = tonumber(n) or 0
		local m = 10 ^ (tonumber(d) or 0)
		return math.floor(n * m + 0.5) / m
	end
	D("Round", "Round(n, decimals?) -> number", "", Round)
	D("Snap", "Snap(n, step) -> number", "Rounds to the nearest multiple of step.", function(n, step)
		step = tonumber(step) or 1
		if step == 0 then return n end
		return math.floor(n / step + 0.5) * step
	end)
	D("Clamp", "Clamp(n, min, max) -> number", "", function(n, a, b) return math.clamp(tonumber(n) or 0, math.min(a, b), math.max(a, b)) end)
	D("Lerp", "Lerp(a, b, t) -> number", "", function(a, b, t) return a + (b - a) * t end)
	D("InverseLerp", "InverseLerp(a, b, v) -> number", "Where v sits between a and b (0..1).", function(a, b, v)
		if a == b then return 0 end
		return (v - a) / (b - a)
	end)
	D("MapRange", "MapRange(v, inMin, inMax, outMin, outMax) -> number", "Re-maps v between ranges.", function(v, a, b, c, d)
		if a == b then return c end
		return c + (v - a) * (d - c) / (b - a)
	end)
	local function Comma(n)
		n = tonumber(n) or 0
		local neg = n < 0
		local int, frac = tostring(math.abs(n)):match("^(%d+)(%.?%d*)$")
		if not int then return tostring(n) end
		int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
		return (neg and "-" or "") .. int .. frac
	end
	D("Comma", "Comma(n) -> string", "1234567 -> \"1,234,567\".", Comma)
	local SUFFIX = {"", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc"}
	D("Abbreviate", "Abbreviate(n, decimals?) -> string", "1520 -> \"1.5K\", 2.3e9 -> \"2.3B\".", function(n, d)
		n = tonumber(n) or 0
		d = tonumber(d) or 1
		local neg = n < 0
		n = math.abs(n)
		local i = 1
		while n >= 1000 and i < #SUFFIX do
			n = n / 1000
			i = i + 1
		end
		local s = string.format("%." .. d .. "f", n):gsub("%.?0+$", "")
		return (neg and "-" or "") .. s .. SUFFIX[i]
	end)
	D("Percent", "Percent(part, total, decimals?) -> string", "\"42.5%\".", function(a, b, d)
		if (tonumber(b) or 0) == 0 then return "0%" end
		return tostring(Round(a / b * 100, d or 0)) .. "%"
	end)
	D("Ordinal", "Ordinal(n) -> string", "1 -> \"1st\", 22 -> \"22nd\".", function(n)
		n = math.floor(tonumber(n) or 0)
		local t, h = n % 10, n % 100
		local s = "th"
		if h < 11 or h > 13 then
			if t == 1 then s = "st" elseif t == 2 then s = "nd" elseif t == 3 then s = "rd" end
		end
		return n .. s
	end)
	D("RandomNumber", "RandomNumber(min, max, float?) -> number", "", function(a, b, float)
		a, b = tonumber(a) or 0, tonumber(b) or 1
		if float then return a + math.random() * (b - a) end
		return math.random(math.floor(a), math.floor(b))
	end)
	D("ToNumber", "ToNumber(v, default?) -> number", "tonumber that ignores commas and falls back to default.", function(v, def)
		local n = tonumber(v)
		if n == nil and type(v) == "string" then n = tonumber((v:gsub(",", ""))) end
		if n == nil or n ~= n then return def end
		return n
	end)
	D("IsInteger", "IsInteger(n) -> bool", "", function(n) return type(n) == "number" and n == math.floor(n) end)
	local function Pad2(n) return string.format("%02d", n) end
	D("FormatTime", "FormatTime(seconds, alwaysHours?) -> string", "75 -> \"01:15\", 3725 -> \"01:02:05\".", function(s, hrs)
		s = math.max(0, math.floor(tonumber(s) or 0))
		local h, m, sec = math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60
		if h > 0 or hrs then return Pad2(h) .. ":" .. Pad2(m) .. ":" .. Pad2(sec) end
		return Pad2(m) .. ":" .. Pad2(sec)
	end)
	D("FormatDuration", "FormatDuration(seconds) -> string", "Human readable (\"2d 3h\").", function(s) return FormatDuration(s) end)
	D("Timestamp", "Timestamp() -> number", "Unix time (os.time).", function() return os.time() end)
	D("Clock", "Clock() -> number", "High resolution clock (os.clock).", function() return os.clock() end)
	D("Date", "Date(format?, time?) -> string", "os.date wrapper (default \"%Y-%m-%d %H:%M:%S\").", function(f, t)
		return os.date(f or "%Y-%m-%d %H:%M:%S", t or os.time())
	end)
	D("Ago", "Ago(unixTime) -> string", "\"just now\", \"5m ago\", \"3h ago\", \"2d ago\".", function(t)
		local d = os.time() - (tonumber(t) or os.time())
		if d < 10 then return "just now" end
		if d < 60 then return d .. "s ago" end
		if d < 3600 then return math.floor(d / 60) .. "m ago" end
		if d < 86400 then return math.floor(d / 3600) .. "h ago" end
		return math.floor(d / 86400) .. "d ago"
	end)
	D("Benchmark", "Benchmark(fn, iterations?) -> avgSeconds, total", "Times a function.", function(fn, n)
		n = math.max(1, tonumber(n) or 1)
		local t0 = os.clock()
		for _ = 1, n do fn() end
		local total = os.clock() - t0
		return total / n, total
	end)
end

function X.BuildUtilColors(U)
	local G = "Util: colors"
	local function D(name, sig, desc, fn) return X.Def(U, G, name, "Util." .. sig, desc, fn) end
	D("FromHex", "FromHex(\"#rrggbb\") -> Color3?", "Also accepts #rgb.", FromHex)
	D("ToHex", "ToHex(color, hash?) -> string", "\"FF5959\" (with # when hash is true).", function(c, hash)
		c = ToColor(c) or WHITE
		return (hash and "#" or "") .. ToHex(c)
	end)
	D("ToColor", "ToColor(Color3 | \"#hex\" | {r, g, b}) -> Color3?", "Normalises any colour input.", function(c)
		if type(c) == "table" then
			local r, g, b = c.R or c.r or c[1], c.G or c.g or c[2], c.B or c.b or c[3]
			if r and g and b then
				if r > 1 or g > 1 or b > 1 then return Color3.fromRGB(r, g, b) end
				return Color3.new(r, g, b)
			end
			return nil
		end
		return ToColor(c)
	end)
	D("FromRGB", "FromRGB(r, g, b) -> Color3", "0..255 channels.", function(r, g, b) return Color3.fromRGB(r, g, b) end)
	D("ToRGB", "ToRGB(color) -> r, g, b", "0..255 channels.", function(c)
		c = ToColor(c) or WHITE
		return math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)
	end)
	D("FromHSV", "FromHSV(h, s, v) -> Color3", "0..1 each.", function(h, s, v) return Color3.fromHSV(h % 1, s, v) end)
	D("ToHSV", "ToHSV(color) -> h, s, v", "", function(c) return (ToColor(c) or WHITE):ToHSV() end)
	D("Lighten", "Lighten(color, amount 0..1) -> Color3", "", function(c, a) return (ToColor(c) or WHITE):Lerp(WHITE, tonumber(a) or 0.2) end)
	D("Darken", "Darken(color, amount 0..1) -> Color3", "", function(c, a) return (ToColor(c) or WHITE):Lerp(Color3.new(0, 0, 0), tonumber(a) or 0.2) end)
	D("Mix", "Mix(a, b, t) -> Color3", "Blend two colours.", function(a, b, t) return (ToColor(a) or WHITE):Lerp(ToColor(b) or WHITE, tonumber(t) or 0.5) end)
	D("Invert", "Invert(color) -> Color3", "", function(c)
		c = ToColor(c) or WHITE
		return Color3.new(1 - c.R, 1 - c.G, 1 - c.B)
	end)
	D("Saturate", "Saturate(color, amount -1..1) -> Color3", "Changes saturation.", function(c, a)
		local h, s, v = (ToColor(c) or WHITE):ToHSV()
		return Color3.fromHSV(h, math.clamp(s + (tonumber(a) or 0.2), 0, 1), v)
	end)
	D("Luminance", "Luminance(color) -> number", "Perceived brightness 0..1.", function(c) return Luminance(ToColor(c) or WHITE) end)
	D("Contrast", "Contrast(background) -> Color3", "Readable black or white text colour for a background.", function(c)
		return Luminance(ToColor(c) or WHITE) > 0.6 and Color3.fromRGB(20, 20, 24) or WHITE
	end)
	D("Rainbow", "Rainbow(speed?, offset?, saturation?, value?) -> Color3", "Time based rainbow colour (call every frame).", function(speed, off, s, v)
		return Color3.fromHSV((os.clock() * (tonumber(speed) or 0.2) + (tonumber(off) or 0)) % 1, s or 0.7, v or 1)
	end)
	D("RandomColor", "RandomColor(saturation?, value?) -> Color3", "Random vivid colour.", function(s, v)
		return Color3.fromHSV(math.random(), s or 0.7, v or 1)
	end)
	D("Gradient", "Gradient(colors, t) -> Color3", "Samples a list of colours at t (0..1).", function(list, t)
		local n = #list
		if n == 0 then return WHITE end
		if n == 1 then return ToColor(list[1]) or WHITE end
		t = math.clamp(tonumber(t) or 0, 0, 1) * (n - 1)
		local i = math.min(math.floor(t) + 1, n - 1)
		return (ToColor(list[i]) or WHITE):Lerp(ToColor(list[i + 1]) or WHITE, t - (i - 1))
	end)
	D("ColorSequence", "ColorSequence(colors) -> ColorSequence", "Evenly spaced ColorSequence from a list.", function(list)
		local kps = {}
		local n = #list
		for i, c in ipairs(list) do
			table.insert(kps, ColorSequenceKeypoint.new(n == 1 and 0 or (i - 1) / (n - 1), ToColor(c) or WHITE))
		end
		if n == 1 then table.insert(kps, ColorSequenceKeypoint.new(1, ToColor(list[1]) or WHITE)) end
		return ColorSequence.new(kps)
	end)
end

function X.BuildUtilMisc(U)
	local G = "Util: functions, JSON, misc"
	local function D(name, sig, desc, fn) return X.Def(U, G, name, "Util." .. sig, desc, fn) end
	D("Debounce", "Debounce(fn, seconds) -> fn", "Runs fn once calls stop for `seconds` (trailing).", function(fn, wait)
		local token = 0
		return function(...)
			token = token + 1
			local my, args = token, table.pack(...)
			task.delay(tonumber(wait) or 0.25, function()
				if my == token then SafeCall(fn, table.unpack(args, 1, args.n)) end
			end)
		end
	end)
	D("Throttle", "Throttle(fn, seconds) -> fn", "Runs fn at most once every `seconds` (leading).", function(fn, interval)
		local last = -math.huge
		return function(...)
			local now = os.clock()
			if now - last < (tonumber(interval) or 0.25) then return nil end
			last = now
			return fn(...)
		end
	end)
	D("OnceFn", "OnceFn(fn) -> fn", "Wrapper that only runs fn the first time.", function(fn)
		local done, res = false, nil
		return function(...)
			if done then return res end
			done = true
			res = fn(...)
			return res
		end
	end)
	D("Memoize", "Memoize(fn) -> fn", "Caches results by the first argument.", function(fn)
		local cache = {}
		return function(a)
			local v = cache[a]
			if v == nil then
				v = fn(a)
				if a ~= nil then cache[a] = v end
			end
			return v
		end
	end)
	D("Try", "Try(fn, ...) -> ok, result", "pcall that warns on error.", function(fn, ...)
		local ok, res = pcall(fn, ...)
		if not ok then warn("[Zenin] " .. tostring(res)) end
		return ok, res
	end)
	D("Retry", "Retry(fn, attempts?, delay?) -> ok, result", "Retries fn until it succeeds (yields between tries).", function(fn, n, d)
		n = math.max(1, tonumber(n) or 3)
		local ok, res
		for i = 1, n do
			ok, res = pcall(fn, i)
			if ok then return true, res end
			if i < n then task.wait(tonumber(d) or 1) end
		end
		return false, res
	end)
	D("Timeout", "Timeout(fn, seconds) -> ok, result", "Runs fn in a thread; gives up after seconds.", function(fn, secs)
		local done, ok, res = false, false, "timeout"
		local thread = coroutine.running()
		task.spawn(function()
			local a, b = pcall(fn)
			if done then return end
			done, ok, res = true, a, b
			task.spawn(thread)
		end)
		if not done then
			task.delay(tonumber(secs) or 5, function()
				if done then return end
				done = true
				task.spawn(thread)
			end)
			coroutine.yield()
		end
		return ok, res
	end)
	D("Bind", "Bind(fn, ...) -> fn", "Partially applies arguments.", function(fn, ...)
		local pre = table.pack(...)
		return function(...)
			local args = {table.unpack(pre, 1, pre.n)}
			local post = table.pack(...)
			for i = 1, post.n do args[pre.n + i] = post[i] end
			return fn(table.unpack(args, 1, pre.n + post.n))
		end
	end)
	D("Noop", "Noop()", "Does nothing.", function() end)

	-- JSON with Roblox types: Color3, Vector3, Vector2, UDim2, EnumItem and CFrame survive a round trip.
	local function Pack(v, seen)
		local t = typeof(v)
		if t == "Color3" then return {__t = "Color3", v = ToHex(v)} end
		if t == "Vector3" then return {__t = "Vector3", v = {v.X, v.Y, v.Z}} end
		if t == "Vector2" then return {__t = "Vector2", v = {v.X, v.Y}} end
		if t == "UDim2" then return {__t = "UDim2", v = {v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset}} end
		if t == "CFrame" then return {__t = "CFrame", v = {v:GetComponents()}} end
		if t == "EnumItem" then return {__t = "EnumItem", v = {tostring(v.EnumType), v.Name}} end
		if t == "table" then
			seen = seen or {}
			if seen[v] then return nil end
			seen[v] = true
			local out = {}
			for k, x in pairs(v) do out[k] = Pack(x, seen) end
			seen[v] = nil
			return out
		end
		if t == "function" or t == "thread" or t == "userdata" or t == "Instance" or t == "RBXScriptConnection" then return nil end
		return v
	end
	local function Unpack(v)
		if type(v) ~= "table" then return v end
		if v.__t and v.v ~= nil then
			local d = v.v
			local ok, res = pcall(function()
				if v.__t == "Color3" then return FromHex(d) end
				if v.__t == "Vector3" then return Vector3.new(d[1], d[2], d[3]) end
				if v.__t == "Vector2" then return Vector2.new(d[1], d[2]) end
				if v.__t == "UDim2" then return UDim2.new(d[1], d[2], d[3], d[4]) end
				if v.__t == "CFrame" then return CFrame.new(table.unpack(d)) end
				if v.__t == "EnumItem" then return Enum[d[1]][d[2]] end
				return nil
			end)
			if ok then return res end
			return nil
		end
		local out = {}
		for k, x in pairs(v) do out[k] = Unpack(x) end
		return out
	end
	X.Pack, X.Unpack = Pack, Unpack
	local function Pretty(v, indent, depth)
		local t = type(v)
		if t ~= "table" then return HttpService:JSONEncode(v) end
		local pad = string.rep(indent, depth + 1)
		local isList = #v > 0 or next(v) == nil
		local parts = {}
		if isList then
			for _, x in ipairs(v) do table.insert(parts, pad .. Pretty(x, indent, depth + 1)) end
			if #parts == 0 then return "[]" end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep(indent, depth) .. "]"
		end
		local keys = {}
		for k in pairs(v) do table.insert(keys, tostring(k)) end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local x = v[k]
			if x == nil then x = v[tonumber(k)] end
			table.insert(parts, pad .. HttpService:JSONEncode(k) .. ": " .. Pretty(x, indent, depth + 1))
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep(indent, depth) .. "}"
	end
	local function Encode(v, pretty)
		local packed = Pack(v)
		if pretty then
			local ok, res = pcall(Pretty, packed, type(pretty) == "string" and pretty or "  ", 0)
			if ok then return res end
		end
		local ok, res = pcall(HttpService.JSONEncode, HttpService, packed)
		if ok then return res end
		return nil, res
	end
	local function Decode(s)
		if type(s) ~= "string" then return nil, "not a string" end
		local ok, res = pcall(HttpService.JSONDecode, HttpService, s)
		if not ok then return nil, res end
		return Unpack(res)
	end
	X.Encode, X.Decode = Encode, Decode
	D("JsonEncode", "JsonEncode(value, pretty?) -> string?", "JSON that keeps Color3/Vector3/UDim2/CFrame/EnumItem.", Encode)
	D("JsonDecode", "JsonDecode(string) -> value?, err", "Safe decode (restores Roblox types).", Decode)
	D("IsJson", "IsJson(string) -> bool", "", function(s) return type(s) == "string" and (pcall(HttpService.JSONDecode, HttpService, s)) end)
	D("Guid", "Guid(braces?) -> string", "Unique id.", function(b) return HttpService:GenerateGUID(b == true) end)
	D("SetClipboard", "SetClipboard(text) -> bool", "Copies to the clipboard when the executor supports it.", X.Clipboard)
	D("Typeof", "Typeof(v) -> string", "Roblox typeof.", function(v) return typeof(v) end)
	D("Executor", "Executor() -> name, version", "Executor name when available.", function()
		if type(identifyexecutor) == "function" then return identifyexecutor() end
		if type(getexecutorname) == "function" then return getexecutorname() end
		return "Unknown", nil
	end)
	D("Supports", "Supports(name) -> bool", "Whether an executor global exists in getgenv (e.g. \"writefile\").", function(name)
		local env = (type(getgenv) == "function" and getgenv()) or _G
		local ok, v = pcall(function() return env[name] end)
		return ok and v ~= nil
	end)
end

function X.BuildFiles()
	local F = {}
	Library.Files = F
	local G = "Files"
	local function D(name, sig, desc, fn) return X.Def(F, G, name, "Library.Files." .. sig, desc, fn) end
	-- Direct global references (no getfenv, which would de-optimise the whole chunk).
	local FS = {
		isfile = isfile, isfolder = isfolder, readfile = readfile, writefile = writefile, appendfile = appendfile,
		makefolder = makefolder, delfile = delfile, delfolder = delfolder, listfiles = listfiles,
	}
	local function Fn(name)
		local f = FS[name]
		if type(f) == "function" then return f end
		return nil
	end
	local function Has(name) return Fn(name) ~= nil end
	D("Supported", "Supported() -> bool", "Whether the executor has a file system.", function()
		return Has("writefile") and Has("readfile") and Has("isfile")
	end)
	local function Exists(p)
		local f = Fn("isfile")
		if not f then return false end
		local ok, r = pcall(f, p)
		return ok and r == true
	end
	local function IsFolder(p)
		local f = Fn("isfolder")
		if not f then return false end
		local ok, r = pcall(f, p)
		return ok and r == true
	end
	local function MakeFolder(p)
		local f = Fn("makefolder")
		if not f then return false end
		local cur = ""
		for part in tostring(p):gmatch("[^/\\]+") do
			cur = cur == "" and part or (cur .. "/" .. part)
			if not IsFolder(cur) then pcall(f, cur) end
		end
		return IsFolder(p)
	end
	local function Write(p, data)
		local f = Fn("writefile")
		if not f then return false end
		local folder = tostring(p):match("^(.*)[/\\][^/\\]+$")
		if folder then MakeFolder(folder) end
		return (pcall(f, p, tostring(data)))
	end
	local function Read(p)
		local f = Fn("readfile")
		if not f or not Exists(p) then return nil end
		local ok, r = pcall(f, p)
		return ok and r or nil
	end
	D("Exists", "Exists(path) -> bool", "", Exists)
	D("IsFolder", "IsFolder(path) -> bool", "", IsFolder)
	D("MakeFolder", "MakeFolder(path) -> bool", "Creates every missing folder in the path.", MakeFolder)
	D("Write", "Write(path, text) -> bool", "Writes a file (creates folders).", Write)
	D("Read", "Read(path) -> string?", "", Read)
	D("Append", "Append(path, text) -> bool", "", function(p, data)
		local f = Fn("appendfile")
		if f and Exists(p) then return (pcall(f, p, tostring(data))) end
		return Write(p, (Read(p) or "") .. tostring(data))
	end)
	D("Delete", "Delete(path) -> bool", "Deletes a file or folder.", function(p)
		if IsFolder(p) then
			local f = Fn("delfolder")
			return f ~= nil and (pcall(f, p))
		end
		local f = Fn("delfile")
		return f ~= nil and Exists(p) and (pcall(f, p))
	end)
	D("List", "List(folder) -> list", "Paths inside a folder.", function(p)
		local f = Fn("listfiles")
		if not f or not IsFolder(p) then return {} end
		local ok, r = pcall(f, p)
		return ok and r or {}
	end)
	D("ReadJson", "ReadJson(path) -> value?", "Reads and decodes a JSON file.", function(p)
		local s = Read(p)
		if not s then return nil end
		return (X.Decode(s))
	end)
	D("WriteJson", "WriteJson(path, value, pretty?) -> bool", "Encodes and writes JSON.", function(p, v, pretty)
		local s = X.Encode(v, pretty)
		return s ~= nil and Write(p, s)
	end)
	X.Files = F
end

function X.BuildUtil()
	local U = {}
	Library.Util = U
	X.BuildUtilTables(U)
	X.BuildUtilStrings(U)
	X.BuildUtilNumbers(U)
	X.BuildUtilColors(U)
	X.BuildUtilMisc(U)
	X.BuildFiles()
end

function X.BuildGame()
	local Gm = {}
	Library.Game = Gm
	local G = "Game & players"
	local function D(name, sig, desc, fn) return X.Def(Gm, G, name, "Library.Game." .. sig, desc, fn) end
	Gm.LocalPlayer = LocalPlayer
	local function Plr(p)
		if p == nil then return LocalPlayer end
		if typeof(p) == "Instance" then
			if p:IsA("Player") then return p end
			local owner = Players:GetPlayerFromCharacter(p)
			if owner then return owner end
			return nil
		end
		if type(p) == "string" then return Gm.FindPlayer(p) end
		return nil
	end
	D("GetPlayers", "GetPlayers(excludeLocal?) -> {Player}", "", function(ex)
		local out = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if not (ex and p == LocalPlayer) then table.insert(out, p) end
		end
		return out
	end)
	D("GetPlayerNames", "GetPlayerNames(excludeLocal?, displayNames?) -> {string}", "Sorted names.", function(ex, disp)
		local out = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if not (ex and p == LocalPlayer) then table.insert(out, disp and p.DisplayName or p.Name) end
		end
		table.sort(out, function(a, b) return a:lower() < b:lower() end)
		return out
	end)
	D("FindPlayer", "FindPlayer(query) -> Player?", "Exact, then prefix, then partial match on Name / DisplayName.", function(q)
		q = tostring(q or ""):lower()
		if q == "" then return nil end
		local list = Players:GetPlayers()
		for _, p in ipairs(list) do
			if p.Name:lower() == q or p.DisplayName:lower() == q then return p end
		end
		for _, p in ipairs(list) do
			if p.Name:lower():sub(1, #q) == q or p.DisplayName:lower():sub(1, #q) == q then return p end
		end
		for _, p in ipairs(list) do
			if p.Name:lower():find(q, 1, true) or p.DisplayName:lower():find(q, 1, true) then return p end
		end
		return nil
	end)
	D("GetCharacter", "GetCharacter(player?) -> Model?", "Defaults to the local player.", function(p)
		p = Plr(p)
		return p and p.Character or nil
	end)
	D("GetHumanoid", "GetHumanoid(player?) -> Humanoid?", "", function(p)
		p = Plr(p)
		local c = p and p.Character
		return c and c:FindFirstChildOfClass("Humanoid") or nil
	end)
	D("GetRoot", "GetRoot(player?) -> BasePart?", "HumanoidRootPart (or PrimaryPart).", function(p)
		p = Plr(p)
		local c = p and p.Character
		if not c then return nil end
		return c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart
	end)
	D("IsAlive", "IsAlive(player?) -> bool", "Has a character with health above 0.", function(p)
		local h = Gm.GetHumanoid(p)
		return h ~= nil and h.Health > 0
	end)
	D("GetHealth", "GetHealth(player?) -> health, maxHealth", "", function(p)
		local h = Gm.GetHumanoid(p)
		if not h then return 0, 0 end
		return h.Health, h.MaxHealth
	end)
	local function Pos(v)
		if typeof(v) == "Vector3" then return v end
		if typeof(v) == "CFrame" then return v.Position end
		if typeof(v) == "Instance" and v:IsA("BasePart") then return v.Position end
		if typeof(v) == "Instance" and v:IsA("Model") then
			local ok, cf = pcall(function() return v:GetPivot() end)
			if ok then return cf.Position end
		end
		local r = Gm.GetRoot(v)
		return r and r.Position or nil
	end
	D("GetPosition", "GetPosition(player | part | model?) -> Vector3?", "", Pos)
	D("GetDistance", "GetDistance(a, b?) -> number", "Distance between players / parts / Vector3s (b defaults to you).", function(a, b)
		local pa, pb = Pos(a), Pos(b == nil and LocalPlayer or b)
		if not (pa and pb) then return math.huge end
		return (pa - pb).Magnitude
	end)
	D("GetPlayersInRadius", "GetPlayersInRadius(radius, origin?) -> {Player}", "Other players within radius, nearest first.", function(radius, origin)
		local o = Pos(origin or LocalPlayer)
		local out = {}
		if not o then return out end
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LocalPlayer then
				local pp = Pos(p)
				if pp and (pp - o).Magnitude <= radius then table.insert(out, {p, (pp - o).Magnitude}) end
			end
		end
		table.sort(out, function(x, y) return x[2] < y[2] end)
		for i, v in ipairs(out) do out[i] = v[1] end
		return out
	end)
	D("GetTeams", "GetTeams() -> {string}", "Team names.", function()
		local out = {}
		local ok, teams = pcall(function() return game:GetService("Teams"):GetTeams() end)
		if ok then
			for _, t in ipairs(teams) do table.insert(out, t.Name) end
		end
		return out
	end)
	D("GetTeamPlayers", "GetTeamPlayers(team | name) -> {Player}", "", function(team)
		local out = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Team and (p.Team == team or p.Team.Name == team) then table.insert(out, p) end
		end
		return out
	end)
	D("IsTeammate", "IsTeammate(player) -> bool", "Same team as you (false when teams are off).", function(p)
		p = Plr(p)
		return p ~= nil and p ~= LocalPlayer and LocalPlayer.Team ~= nil and p.Team == LocalPlayer.Team
	end)
	D("OnPlayerAdded", "OnPlayerAdded(fn, existing?) -> Connection", "Also runs for current players when existing is true.", function(fn, existing)
		if existing then
			for _, p in ipairs(Players:GetPlayers()) do task.spawn(SafeCall, fn, p) end
		end
		return X.Maid:Give(Players.PlayerAdded:Connect(function(p) SafeCall(fn, p) end))
	end)
	D("OnPlayerRemoving", "OnPlayerRemoving(fn) -> Connection", "", function(fn)
		return X.Maid:Give(Players.PlayerRemoving:Connect(function(p) SafeCall(fn, p) end))
	end)
	D("OnCharacterAdded", "OnCharacterAdded(fn, player?) -> Connection", "Runs now when the character exists, and on every respawn.", function(fn, p)
		p = Plr(p) or LocalPlayer
		if p.Character then task.spawn(SafeCall, fn, p.Character) end
		return X.Maid:Give(p.CharacterAdded:Connect(function(c) SafeCall(fn, c) end))
	end)
	D("GetPing", "GetPing() -> ms", "Network ping in milliseconds.", function()
		local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
		if ok and v then return math.floor(v + 0.5) end
		ok, v = pcall(function() return LocalPlayer:GetNetworkPing() * 1000 end)
		return ok and math.floor(v + 0.5) or 0
	end)
	local frames, fps = {}, 60
	D("GetFPS", "GetFPS() -> number", "Frames per second (averaged over 1s).", function()
		if not X.Maid.FpsCounter then
			X.Maid.FpsCounter = RunService.Heartbeat:Connect(function()
				local now = os.clock()
				table.insert(frames, now)
				while frames[1] and frames[1] < now - 1 do table.remove(frames, 1) end
				fps = #frames
			end)
			return 60
		end
		return fps
	end)
	D("GetServerInfo", "GetServerInfo() -> table", "PlaceId, GameId, JobId, Players, MaxPlayers, Uptime.", function()
		return {
			PlaceId = game.PlaceId, GameId = game.GameId, JobId = game.JobId,
			Players = #Players:GetPlayers(), MaxPlayers = Players.MaxPlayers,
			Uptime = (pcall(function() return workspace.DistributedGameTime end)) and workspace.DistributedGameTime or 0,
			PrivateServer = game.PrivateServerId ~= "",
		}
	end)
	local gameName
	D("GetGameName", "GetGameName() -> string", "Place name from MarketplaceService (cached, yields once).", function()
		if gameName then return gameName end
		local ok, info = pcall(function() return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId) end)
		gameName = ok and info and info.Name or "Unknown"
		return gameName
	end)
	D("Rejoin", "Rejoin()", "Teleports you back into the same server.", function()
		local ts = game:GetService("TeleportService")
		local ok = pcall(function()
			if #Players:GetPlayers() <= 1 then
				ts:Teleport(game.PlaceId, LocalPlayer)
			else
				ts:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
			end
		end)
		return ok
	end)
	D("CopyJobId", "CopyJobId() -> bool", "Copies the server JobId.", function() return X.Clipboard(game.JobId) end)
	D("GetCamera", "GetCamera() -> Camera", "", function() return workspace.CurrentCamera end)
	D("GetMouseLocation", "GetMouseLocation() -> Vector2", "", function() return UserInputService:GetMouseLocation() end)
	D("IsMobile", "IsMobile() -> bool", "Touch screen without keyboard.", function()
		return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end)
	D("GetPlatform", "GetPlatform() -> \"PC\" | \"Mobile\" | \"Console\"", "", function()
		if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then return "Console" end
		if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then return "Mobile" end
		return "PC"
	end)
end

function X.BuildScheduler()
	local G = "Loops & scheduling"
	local loops = {}
	X.Loops = loops
	-- owner: optional maid (a window's) that stops the loop when cleaned.
	function X.NewLoop(o, owner)
		local name = o.Name or HttpService:GenerateGUID(false)
		local interval = math.max(tonumber(o.Interval) or 0, 0)
		local fn = o.Callback or o.Fn
		local loop = {Name = name, Ticks = 0}
		local running, gen = false, 0
		local function Body(my)
			if o.Immediate == false then
				if interval > 0 then task.wait(interval) else RunService.Heartbeat:Wait() end
			end
			while running and gen == my do
				loop.Ticks = loop.Ticks + 1
				local ok, err = pcall(fn, loop.Ticks, loop)
				if not ok then
					warn("[Zenin] loop '" .. tostring(name) .. "' error: " .. tostring(err))
					if o.StopOnError then running = false break end
				end
				if not (running and gen == my) then break end
				if interval > 0 then task.wait(interval) else RunService.Heartbeat:Wait() end
			end
		end
		Method(loop, "Start", function()
			if running then return loop end
			running = true
			gen = gen + 1
			local my = gen
			loop._thread = task.spawn(Body, my)
			X.Emit("LoopStarted", name)
			return loop
		end)
		Method(loop, "Stop", function()
			if not running then return loop end
			running = false
			gen = gen + 1
			local th = loop._thread
			loop._thread = nil
			if th and coroutine.status(th) == "suspended" then pcall(task.cancel, th) end
			X.Emit("LoopStopped", name)
			return loop
		end)
		Method(loop, "Toggle", function(b)
			if b == nil then b = not running end
			if b then loop.Start() else loop.Stop() end
			return running
		end)
		loop.SetEnabled = loop.Toggle
		Method(loop, "IsRunning", function() return running end)
		Method(loop, "SetInterval", function(s) interval = math.max(tonumber(s) or 0, 0) end)
		Method(loop, "GetInterval", function() return interval end)
		Method(loop, "SetCallback", function(f) fn = f end)
		Method(loop, "GetTicks", function() return loop.Ticks end)
		Method(loop, "Destroy", function()
			loop.Stop()
			if loops[name] == loop then loops[name] = nil end
		end)
		if loops[name] then loops[name].Destroy() end
		loops[name] = loop
		;(owner or X.Maid):Give(loop)
		if o.AutoStart ~= false then loop.Start() end
		return loop
	end
	local function Args(a, b, c)
		if type(a) == "table" then return a end
		if type(a) == "function" then return {Callback = a, Interval = b} end
		if type(b) == "function" then return {Interval = a, Callback = b} end
		return {Name = a, Interval = b, Callback = c}
	end
	X.LoopArgs = Args
	X.Def(Library, G, "Loop", "Library.Loop(name?, interval, fn(tick, loop)) -> Loop",
		"Repeating task (interval 0 = every frame). Also Library.Loop{Name, Interval, Callback, AutoStart, Immediate, StopOnError}. Loop: Start/Stop/Toggle/IsRunning/SetInterval/SetCallback/GetTicks/Destroy. Same name replaces the old loop.",
		function(a, b, c) return X.NewLoop(Args(a, b, c)) end)
	Library.Every = Library.Loop
	X.Def(Library, G, "GetLoop", "Library.GetLoop(name) -> Loop?", "", function(n) return loops[n] end)
	X.Def(Library, G, "GetLoops", "Library.GetLoops() -> {name}", "Names of every loop.", function()
		local out = {}
		for k in pairs(loops) do table.insert(out, k) end
		table.sort(out)
		return out
	end)
	X.Def(Library, G, "StopLoop", "Library.StopLoop(name) -> bool", "Stops and removes a loop.", function(n)
		local l = loops[n]
		if l then l.Destroy() return true end
		return false
	end)
	X.Def(Library, G, "StopAllLoops", "Library.StopAllLoops()", "", function()
		for _, l in pairs(X.Copy(loops)) do l.Destroy() end
	end)
	local function Frame(signal)
		return function(fn) return X.Maid:Give(signal:Connect(function(...) SafeCall(fn, ...) end)) end
	end
	X.Def(Library, G, "OnHeartbeat", "Library.OnHeartbeat(fn(dt)) -> Connection", "Every frame after physics.", Frame(RunService.Heartbeat))
	X.Def(Library, G, "OnRenderStep", "Library.OnRenderStep(fn(dt)) -> Connection", "Every frame before render.", Frame(RunService.RenderStepped))
	X.Def(Library, G, "OnStepped", "Library.OnStepped(fn(time, dt)) -> Connection", "Every frame before physics.", Frame(RunService.Stepped))
	X.Def(Library, G, "Delay", "Library.Delay(seconds, fn, ...) -> thread", "Cancelled automatically on Unload.", function(t, fn, ...)
		return X.Maid:Delay(t, fn, ...)
	end)
	X.Def(Library, G, "Spawn", "Library.Spawn(fn, ...) -> thread", "Cancelled automatically on Unload.", function(fn, ...)
		return X.Maid:Spawn(fn, ...)
	end)
	X.Def(Library, G, "GiveTask", "Library.GiveTask(task) -> task", "Connection / Instance / function cleaned on Unload.", function(job)
		return X.Maid:Give(job)
	end)
end

function X.BuildHotkeys()
	local H = {}
	Library.Hotkeys = H
	local G = "Hotkeys"
	local list = {}
	local MODS = {
		ctrl = {Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl},
		shift = {Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift},
		alt = {Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt},
	}
	local ALIAS = {control = "ctrl", cmd = "ctrl", option = "alt"}
	-- "Ctrl+Shift+F" / "F" / Enum.KeyCode.F / Enum.UserInputType.MouseButton2
	local function Parse(spec)
		if typeof(spec) == "EnumItem" then return ParseKey(spec), {} end
		local mods, key = {}, nil
		for part in tostring(spec or ""):gmatch("[^%+]+") do
			part = part:gsub("^%s+", ""):gsub("%s+$", "")
			local low = part:lower()
			low = ALIAS[low] or low
			if MODS[low] then
				mods[low] = true
			else
				key = ParseKey(part) or ParseKey(part:upper()) or ParseKey(part:sub(1, 1):upper() .. part:sub(2))
			end
		end
		return key, mods
	end
	local function ModsDown(mods)
		for m in pairs(mods) do
			local down = false
			for _, kc in ipairs(MODS[m]) do
				if UserInputService:IsKeyDown(kc) then down = true break end
			end
			if not down then return false end
		end
		return true
	end
	local function Match(key, input)
		if not key then return false end
		if key.EnumType == Enum.KeyCode then return input.KeyCode == key end
		return input.UserInputType == key
	end
	local function Ensure()
		if X.Maid.HotkeyBegan then return end
		X.Maid.HotkeyBegan = UserInputService.InputBegan:Connect(function(input, gp)
			local typing = UserInputService:GetFocusedTextBox() ~= nil
			for _, h in ipairs(CopyList(list)) do
				if h.Enabled and Match(h.Key, input) and ModsDown(h.Mods)
					and (h.AllowTyping or not typing) and (h.AllowGameProcessed or not gp) then
					h._down = true
					SafeCall(h.Callback, true, h)
				end
			end
		end)
		X.Maid.HotkeyEnded = UserInputService.InputEnded:Connect(function(input)
			for _, h in ipairs(CopyList(list)) do
				if h._down and Match(h.Key, input) then
					h._down = false
					if h.OnRelease then SafeCall(h.OnRelease, h) end
				end
			end
		end)
	end
	function X.BindKey(spec, fn, o, owner)
		o = type(o) == "table" and o or {}
		local key, mods = Parse(spec)
		local h = {
			Name = o.Name or tostring(spec), Key = key, Mods = mods, Enabled = o.Enabled ~= false,
			AllowTyping = o.AllowTyping == true, AllowGameProcessed = o.AllowGameProcessed == true,
			OnRelease = o.OnRelease,
		}
		h.Callback = function(...) if fn then return fn(...) end end
		if not key then warn("[Zenin] Hotkeys.Bind: unknown key '" .. tostring(spec) .. "'") end
		Method(h, "Unbind", function()
			local i = IndexOf(list, h)
			if i then table.remove(list, i) end
		end)
		h.Destroy, h.Disconnect = h.Unbind, h.Unbind
		Method(h, "SetKey", function(s) h.Key, h.Mods = Parse(s) end)
		Method(h, "GetKey", function() return h.Key, h.Mods end)
		Method(h, "SetEnabled", function(b) h.Enabled = b ~= false end)
		Method(h, "IsEnabled", function() return h.Enabled end)
		Method(h, "IsDown", function() return h._down == true end)
		Method(h, "Fire", function() SafeCall(h.Callback, true, h) end)
		if o.Name then
			for _, other in ipairs(CopyList(list)) do
				if other.Name == o.Name then other.Unbind() end
			end
		end
		table.insert(list, h)
		Ensure()
		if owner then owner:Give(h) end
		return h
	end
	X.Def(H, G, "Bind", "Library.Hotkeys.Bind(key, fn, {Name, OnRelease, AllowTyping, AllowGameProcessed}) -> Hotkey",
		"key: \"F\", \"Ctrl+Shift+K\", Enum.KeyCode.X or a mouse button. Hotkey: Unbind/SetKey/GetKey/SetEnabled/IsEnabled/IsDown/Fire.",
		function(spec, fn, o) return X.BindKey(spec, fn, o) end)
	Library.BindKey = H.Bind
	X.Def(H, G, "Unbind", "Library.Hotkeys.Unbind(name | hotkey) -> bool", "", function(ref)
		for _, h in ipairs(CopyList(list)) do
			if h == ref or h.Name == ref then h.Unbind() return true end
		end
		return false
	end)
	X.Def(H, G, "List", "Library.Hotkeys.List() -> {Hotkey}", "", function() return CopyList(list) end)
	X.Def(H, G, "Clear", "Library.Hotkeys.Clear()", "Unbinds every hotkey.", function() table.clear(list) end)
	X.Def(H, G, "IsDown", "Library.Hotkeys.IsDown(key) -> bool", "Whether a key (or \"Ctrl+X\" combo) is held.", function(spec)
		local key, mods = Parse(spec)
		if not key then return false end
		if not ModsDown(mods) then return false end
		if key.EnumType == Enum.KeyCode then return UserInputService:IsKeyDown(key) end
		local ok, v = pcall(function() return UserInputService:IsMouseButtonPressed(key) end)
		return ok and v
	end)
	X.Def(H, G, "Parse", "Library.Hotkeys.Parse(spec) -> KeyCode?, mods", "", Parse)
end

function X.BuildStorage()
	local G = "Storage"
	local stores = {}
	X.Def(Library, G, "Storage", "Library.Storage(name?, {Folder, AutoSave}) -> Store",
		"Persistent key/value store (JSON file when the executor has writefile, memory otherwise). Store: Get/Set/Delete/Has/Increment/Toggle/Clear/All/Keys/Save/Load/Path/OnChanged.",
		function(name, o)
			name = tostring(name or "default")
			o = type(o) == "table" and o or {}
			if stores[name] then return stores[name] end
			local folder = o.Folder or ((Library.ConfigFolder or "Zenin") .. "/storage")
			local path = folder .. "/" .. name:gsub("[^%w%-_ ]", "_") .. ".json"
			local data = {}
			local changed = X.Signal()
			local st = {Name = name}
			local saveQueued = false
			local function Save()
				saveQueued = false
				return X.Files.WriteJson(path, data, true)
			end
			local function Queue()
				if o.AutoSave == false or saveQueued then return end
				saveQueued = true
				task.defer(Save)
			end
			local function Load()
				local v = X.Files.ReadJson(path)
				if type(v) == "table" then data = v end
				return data
			end
			Method(st, "Get", function(k, def)
				local v = data[k]
				if v == nil then return def end
				return v
			end)
			Method(st, "Set", function(k, v)
				local old = data[k]
				data[k] = v
				Queue()
				if old ~= v then changed.Fire(k, v, old) end
				return v
			end)
			Method(st, "Delete", function(k) st.Set(k, nil) end)
			st.Remove = st.Delete
			Method(st, "Has", function(k) return data[k] ~= nil end)
			Method(st, "Increment", function(k, by) return st.Set(k, (tonumber(data[k]) or 0) + (tonumber(by) or 1)) end)
			Method(st, "Toggle", function(k) return st.Set(k, not data[k]) end)
			Method(st, "Clear", function()
				data = {}
				Queue()
				changed.Fire(nil, nil, nil)
			end)
			Method(st, "All", function() return X.Copy(data) end)
			Method(st, "Keys", function()
				local out = {}
				for k in pairs(data) do table.insert(out, k) end
				return out
			end)
			Method(st, "Save", Save)
			Method(st, "Load", Load)
			Method(st, "Path", function() return path end)
			Method(st, "OnChanged", function(fn) return changed.Connect(fn) end)
			Load()
			stores[name] = st
			return st
		end)
	Library.Store = Library.Storage
end

function X.BuildFlags()
	local G = "Flags"
	local function D(name, sig, desc, fn) return X.Def(Library, G, name, "Library." .. sig, desc, fn) end
	function X.ResetElement(el)
		if el._reset then
			SafeCall(el._reset)
		elseif el._default ~= nil then
			ApplyFlag(el, el._default)
		end
	end
	D("GetFlags", "GetFlags() -> {flag = value}", "Snapshot copy of every flag.", function() return X.Copy(Library.Flags) end)
	D("SetFlags", "SetFlags({flag = value}) -> count", "Sets many flags at once.", function(t)
		local n = 0
		for k, v in pairs(t or {}) do
			if Library.SetFlag(k, v) then n = n + 1 end
		end
		return n
	end)
	D("HasFlag", "HasFlag(flag) -> bool", "Whether an element owns this flag.", function(f) return Library.Options[f] ~= nil end)
	D("ToggleFlag", "ToggleFlag(flag) -> newValue", "Flips a boolean flag.", function(f)
		local el = Library.Options[f]
		if not el then return nil end
		local v = not el.Get()
		ApplyFlag(el, v)
		return v
	end)
	D("ResetFlag", "ResetFlag(flag) -> bool", "Back to the element's default.", function(f)
		local el = Library.Options[f]
		if not el then return false end
		X.ResetElement(el)
		return true
	end)
	D("ResetFlags", "ResetFlags()", "Every flagged element back to its default.", function()
		for f, el in pairs(Library.Options) do
			if not (type(f) == "string" and f:sub(1, 7) == "__Zenin") then X.ResetElement(el) end
		end
	end)
	D("GetFlagType", "GetFlagType(flag) -> string?", "Element type (Toggle, Slider ...).", function(f)
		local el = Library.Options[f]
		return el and el.Type or nil
	end)
	D("GetOptionsByType", "GetOptionsByType(type) -> {flag = element}", "", function(kind)
		local out = {}
		for f, el in pairs(Library.Options) do
			if el.Type == kind then out[f] = el end
		end
		return out
	end)
	D("FindOptions", "FindOptions(query) -> {element}", "Fuzzy search by flag or name.", function(q)
		local out = {}
		for f, el in pairs(Library.Options) do
			local sc = math.max(X.Fuzzy(f, q), X.Fuzzy(el.Name or "", q))
			if sc > 0 then table.insert(out, {el, sc}) end
		end
		table.sort(out, function(a, b) return a[2] > b[2] end)
		for i, v in ipairs(out) do out[i] = v[1] end
		return out
	end)
	D("OnAnyFlagChanged", "OnAnyFlagChanged(fn(flag, value, old, element)) -> Connection", "", function(fn)
		return Library.On("FlagChanged", fn)
	end)
	D("WatchFlag", "WatchFlag(flag, fn(value)) -> Connection", "Calls fn now and on every change of that flag.", function(f, fn)
		task.spawn(SafeCall, fn, Library.Flags[f])
		return Library.On("FlagChanged", function(flag, v)
			if flag == f then fn(v) end
		end)
	end)
	D("WaitForFlag", "WaitForFlag(flag, value?, timeout?) -> value", "Yields until the flag changes (to value, when given).", function(f, want, timeout)
		if want ~= nil and Library.Flags[f] == want then return want end
		local deadline = tonumber(timeout) and os.clock() + tonumber(timeout)
		while true do
			local left = deadline and (deadline - os.clock())
			if left and left <= 0 then return Library.Flags[f] end
			local flag, v = Library.WaitFor("FlagChanged", left)
			if flag == f and (want == nil or v == want) then return v end
		end
	end)
	D("ExportFlags", "ExportFlags(pretty?) -> json", "Every flag serialised to JSON.", function(pretty)
		local out = {}
		for f, el in pairs(Library.Options) do
			if not (type(f) == "string" and f:sub(1, 7) == "__Zenin") then
				local ok, v = pcall(SerializeFlag, el)
				if ok then out[f] = v end
			end
		end
		return X.Encode(out, pretty)
	end)
	D("ImportFlags", "ImportFlags(json | table) -> count", "Applies flags from ExportFlags output.", function(src)
		local t = src
		if type(src) == "string" then t = X.Decode(src) end
		if type(t) ~= "table" then return 0 end
		local n = 0
		for f, v in pairs(t) do
			local el = Library.Options[f]
			if el then
				ApplyFlag(el, v)
				n = n + 1
			end
		end
		return n
	end)
	D("CopyFlags", "CopyFlags() -> bool", "ExportFlags to the clipboard.", function() return X.Clipboard(Library.ExportFlags(true)) end)
	D("LockFlag", "LockFlag(flag, reason?) -> bool", "Locks the element behind a flag.", function(f, reason)
		local el = Library.Options[f]
		if el and el.Lock then el.Lock(reason) return true end
		return false
	end)
	D("UnlockFlag", "UnlockFlag(flag) -> bool", "", function(f)
		local el = Library.Options[f]
		if el and el.Unlock then el.Unlock() return true end
		return false
	end)
	D("GetOptionsByTag", "GetOptionsByTag(tag) -> {element}", "Every element (all windows) carrying a tag.", function(tag)
		local out = {}
		for _, w in ipairs(Library.Windows) do
			if w.GetElementsByTag then
				for _, el in ipairs(w.GetElementsByTag(tag)) do table.insert(out, el) end
			end
		end
		return out
	end)
end

function X.BuildThemes()
	local G = "Themes"
	local function D(name, sig, desc, fn) return X.Def(Library, G, name, "Library." .. sig, desc, fn) end
	-- Partial palettes; DeriveTheme (AddTheme) fills every other token from background + text.
	local P = {
		Midnight = {WindowBg = rgb(11, 13, 22), Text = rgb(232, 236, 255)},
		Ocean = {WindowBg = rgb(10, 22, 32), Text = rgb(222, 242, 250)},
		Forest = {WindowBg = rgb(13, 20, 15), Text = rgb(226, 240, 228)},
		Rose = {WindowBg = rgb(24, 13, 17), Text = rgb(252, 228, 236)},
		Mocha = {WindowBg = rgb(30, 30, 46), Text = rgb(205, 214, 244)},
		Nord = {WindowBg = rgb(46, 52, 64), Text = rgb(236, 239, 244)},
		Dracula = {WindowBg = rgb(40, 42, 54), Text = rgb(248, 248, 242)},
		Amoled = {WindowBg = rgb(0, 0, 0), Text = rgb(255, 255, 255)},
		Slate = {WindowBg = rgb(17, 20, 26), Text = rgb(226, 232, 240)},
		Grape = {WindowBg = rgb(20, 14, 30), Text = rgb(238, 230, 255)},
		Sand = {WindowBg = rgb(246, 241, 231), Text = rgb(40, 34, 26)},
		Paper = {WindowBg = rgb(250, 250, 250), Text = rgb(24, 24, 27)},
		Sakura = {WindowBg = rgb(253, 242, 246), Text = rgb(60, 28, 40)},
	}
	-- Suggested accents that match each preset.
	local A = {
		Midnight = rgb(129, 140, 248), Ocean = rgb(56, 189, 248), Forest = rgb(74, 222, 128), Rose = rgb(251, 113, 133),
		Mocha = rgb(203, 166, 247), Nord = rgb(136, 192, 208), Dracula = rgb(255, 121, 198), Amoled = rgb(255, 89, 89),
		Slate = rgb(148, 163, 184), Grape = rgb(192, 132, 252), Sand = rgb(217, 119, 6), Paper = rgb(37, 99, 235), Sakura = rgb(236, 72, 153),
	}
	Library.ThemePresets = P
	Library.ThemeAccents = A
	D("AddThemePreset", "AddThemePreset(name) -> theme?", "Registers one built-in preset (" .. "Midnight, Ocean, Forest, Rose, Mocha, Nord, Dracula, Amoled, Slate, Grape, Sand, Paper, Sakura).", function(name)
		local p = P[name]
		if not p then return nil end
		local t = AddTheme(name, X.Copy(p))
		X.Emit("ThemeAdded", name)
		return t
	end)
	D("LoadThemePresets", "LoadThemePresets(names?) -> {name}", "Registers every preset (or the listed ones) so they appear in the theme picker.", function(names)
		local out = {}
		local list = names
		if type(list) ~= "table" then
			list = {}
			for k in pairs(P) do table.insert(list, k) end
			table.sort(list)
		end
		for _, n in ipairs(list) do
			if Library.AddThemePreset(n) then table.insert(out, n) end
		end
		return out
	end)
	D("CreateTheme", "CreateTheme(name, background, text?, overrides?) -> theme", "Full theme from just two colours.", function(name, bg, text, extra)
		local t = {WindowBg = ToColor(bg) or rgb(14, 14, 14)}
		if text then t.Text = ToColor(text) end
		for k, v in pairs(type(extra) == "table" and extra or {}) do t[k] = ToColor(v) or v end
		local th = AddTheme(name, t)
		X.Emit("ThemeAdded", name)
		return th
	end)
	D("GetThemeTokens", "GetThemeTokens(name?) -> table", "Copy of a theme's colours (active window's theme by default).", function(name)
		name = name or (Library.ActiveWindow and Library.ActiveWindow.GetTheme()) or "Dark"
		return X.Copy(Library.Themes[name] or {})
	end)
	D("GetThemeNames", "GetThemeNames() -> {name}", "", function() return CopyList(Library.ThemeOrder) end)
	D("ExportTheme", "ExportTheme(name?) -> json", "Theme as {token = \"#hex\"} JSON.", function(name)
		name = name or (Library.ActiveWindow and Library.ActiveWindow.GetTheme()) or "Dark"
		local out = {}
		for k, v in pairs(Library.Themes[name] or {}) do
			if typeof(v) == "Color3" then out[k] = "#" .. ToHex(v) end
		end
		return X.Encode(out, true)
	end)
	D("ImportTheme", "ImportTheme(name, json | table) -> theme?", "Adds a theme from ExportTheme output.", function(name, src)
		local t = type(src) == "string" and X.Decode(src) or src
		if type(t) ~= "table" then return nil end
		local tokens = {}
		for k, v in pairs(t) do tokens[k] = ToColor(v) end
		local th = AddTheme(name, tokens)
		X.Emit("ThemeAdded", name)
		return th
	end)
	D("SetAccent", "SetAccent(color, alpha?)", "Accent of the active window.", function(c, a)
		if Library.ActiveWindow then Library.ActiveWindow.SetAccent(c, a) end
	end)
	D("GetAccent", "GetAccent() -> Color3, alpha", "", function()
		if Library.ActiveWindow then return Library.ActiveWindow.GetAccent() end
		return nil
	end)
	D("UsePreset", "UsePreset(name)", "Registers a preset, switches the active window to it and applies its accent.", function(name)
		if not Library.Themes[name] then Library.AddThemePreset(name) end
		local w = Library.ActiveWindow
		if w then
			w.SetTheme(name)
			if A[name] then w.SetAccent(A[name]) end
		end
	end)
	D("SetRainbowAccent", "SetRainbowAccent(enabled, speed?)", "Animated rainbow accent on the active window.", function(b, speed)
		local w = Library.ActiveWindow
		if w and w.SetRainbowAccent then w.SetRainbowAccent(b, speed) end
	end)
end

-- Tooltips: one floating label per window, mouse only.
function X.Tooltip(W)
	if W._tip then return W._tip end
	local frame = Create("Frame", {
		Name = "ZeninTooltip",
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 200,
		Parent = W.Gui,
	})
	Corner(frame, 4)
	local st = Stroke(frame, WHITE, 1)
	Create("UIPadding", {
		PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7),
		PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 5), Parent = frame,
	})
	Create("UISizeConstraint", {MaxSize = Vector2.new(240, 400), Parent = frame})
	local lbl = Label(frame, "", {Size = UDim2.fromOffset(0, 0), TextSize = 10, AutoX = false})
	lbl.AutomaticSize = Enum.AutomaticSize.XY
	lbl.TextWrapped = true
	lbl.RichText = true
	lbl.ZIndex = 201
	W.Bind(function(T)
		frame.BackgroundColor3 = T.PopupBg
		st.Color = T.DropdownBorder
		lbl.TextColor3 = T.Text
	end, frame)
	local tip = {Owner = nil, Token = 0}
	local function Place()
		local m = UserInputService:GetMouseLocation()
		local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
		local size = frame.AbsoluteSize
		local x, y = m.X + 14, m.Y + 16
		if x + size.X > vp.X - 4 then x = m.X - size.X - 10 end
		if y + size.Y > vp.Y - 4 then y = m.Y - size.Y - 10 end
		frame.Position = UDim2.fromOffset(x, y)
	end
	function tip.Show(owner, text)
		tip.Owner = owner
		tip.Token = tip.Token + 1
		local my = tip.Token
		task.delay(0.35, function()
			if tip.Token ~= my or tip.Owner ~= owner or not W.Alive then return end
			lbl.Text = tostring(text)
			Place()
			frame.Visible = true
		end)
	end
	function tip.Hide(owner)
		if owner and tip.Owner ~= owner then return end
		tip.Owner = nil
		tip.Token = tip.Token + 1
		frame.Visible = false
	end
	W.Connect(UserInputService.InputChanged, function(input)
		if frame.Visible and input.UserInputType == Enum.UserInputType.MouseMovement then Place() end
	end)
	W._tip = tip
	return tip
end

-- Element-level API added to every element (built-in and new). Element-specific code that runs
-- after NewElement can still override any of these.
function X.ExtendElement(W, S, el, row, o)
	local G = "Element methods (every element)"
	el._section = S
	el.Tags = {}
	for _, t in ipairs(type(o.Tags) == "table" and o.Tags or {o.Tag}) do el.Tags[tostring(t)] = true end
	if X.Sec[S] and X.Sec[S].Collapsed then row.Visible = false end

	-- Value tracking: FlagChanged bus + history for Undo.
	local history, applying = {}, false
	local baseSync = el._sync
	function el._sync(value)
		local prev = el._cur
		local flagOld = el.Flag and Library.Flags[el.Flag]
		baseSync(value)
		if prev ~= value and el._tracked then
			if not applying then
				table.insert(history, type(prev) == "table" and X.Copy(prev) or prev)
				if #history > 25 then table.remove(history, 1) end
			end
		end
		el._cur = type(value) == "table" and X.Copy(value) or value
		if el.Flag and flagOld ~= value then X.Emit("FlagChanged", el.Flag, value, flagOld, el) end
	end
	task.defer(function()
		if el.Get then
			local ok, v = pcall(el.Get)
			if ok and el._cur == nil then el._cur = type(v) == "table" and X.Copy(v) or v end
		end
		el._tracked = true
	end)

	Method(el, "GetType", function() return el.Type end)
	Method(el, "GetName", function() return el.Name end)
	Method(el, "GetFlag", function() return el.Flag end)
	Method(el, "GetRow", function() return row end)
	Method(el, "GetSection", function() return S end)
	Method(el, "GetWindow", function() return X.Win[W] end)
	Method(el, "Show", function() el.SetVisible(true) end)
	Method(el, "Hide", function() el.SetVisible(false) end)
	Method(el, "ToggleVisible", function() el.SetVisible(not el.Visible) end)
	Method(el, "Enable", function() el.SetEnabled(true) end)
	Method(el, "Disable", function() el.SetEnabled(false) end)

	-- Lock: disabled until Unlock, whatever SetEnabled / DependsOn ask for meanwhile.
	local baseSetEnabled = el.SetEnabled
	local wanted, locked, lockReason = el.Enabled, false, nil
	Method(el, "SetEnabled", function(b)
		wanted = b ~= false
		if locked then return end
		baseSetEnabled(wanted)
	end)
	Method(el, "Lock", function(reason)
		locked, lockReason = true, reason
		baseSetEnabled(false)
		if reason then el._lockTip = "🔒 " .. tostring(reason) end
	end)
	Method(el, "Unlock", function()
		locked, lockReason = false, nil
		el._lockTip = nil
		baseSetEnabled(wanted)
	end)
	Method(el, "IsLocked", function() return locked, lockReason end)

	local baseSetVisible = el.SetVisible
	Method(el, "SetVisible", function(b)
		baseSetVisible(b)
		if X.Sec[S] and X.Sec[S].Collapsed then row.Visible = false end
		if el._filtered then row.Visible = false end
	end)

	-- Tooltips (mouse hover).
	local tipText, hooked = o.Tooltip or o.Hint, false
	local function Hook()
		if hooked then return end
		hooked = true
		el.Maid:Give(OnMouseEnter(row, function()
			local t = el._lockTip or tipText
			if t and t ~= "" then X.Tooltip(W).Show(el, t) end
		end))
		el.Maid:Give(row.MouseLeave:Connect(function() if W._tip then W._tip.Hide(el) end end))
		el.Maid:Give(function() if W._tip then W._tip.Hide(el) end end)
	end
	Method(el, "SetTooltip", function(t)
		tipText = t
		if t then Hook() end
	end)
	el.SetHint = el.SetTooltip
	Method(el, "GetTooltip", function() return tipText end)
	if tipText then Hook() end
	local baseLock = el.Lock
	Method(el, "Lock", function(reason)
		baseLock(reason)
		if reason then Hook() end
	end)

	-- Accent flash behind the row.
	Method(el, "Highlight", function(duration, color)
		local f = Create("Frame", {
			Size = UDim2.new(1, 8, 1, 4), Position = UDim2.fromOffset(-4, -2),
			BackgroundColor3 = ToColor(color) or W.Accent, BackgroundTransparency = 0.75,
			BorderSizePixel = 0, ZIndex = 0, Parent = row,
		})
		Corner(f, 4)
		local t = Tween(f, TweenInfo.new(tonumber(duration) or 0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1})
		t.Completed:Connect(function() f:Destroy() end)
	end)
	el.Pulse = el.Highlight

	-- Change helpers.
	Method(el, "Once", function(fn)
		local done = false
		el.OnChanged(function(...)
			if done then return end
			done = true
			fn(...)
		end)
		return el
	end)
	Method(el, "Watch", function(fn)
		el.OnChanged(fn)
		if el.Get then task.spawn(SafeCall, fn, el.Get()) end
		return el
	end)
	Method(el, "OnChangedTo", function(value, fn)
		el.OnChanged(function(v, ...) if v == value then fn(v, ...) end end)
		return el
	end)
	Method(el, "OnChangedDebounced", function(fn, wait)
		el.OnChanged(Library.Util.Debounce(fn, wait or 0.3))
		return el
	end)
	-- Keeps this element in sync with another (element or flag); transform maps the value.
	Method(el, "Bind", function(other, transform)
		if type(other) == "string" then other = Library.Options[other] end
		if type(other) ~= "table" or not other.OnChanged then return el end
		local function Push(v)
			if transform then v = transform(v) end
			if el.Set then pcall(el.Set, v) end
		end
		other.OnChanged(Push)
		if other.Get then Push(other.Get()) end
		return el
	end)
	el.LinkTo = el.Bind
	Method(el, "Undo", function()
		local prev = table.remove(history)
		if prev == nil or not el.Set then return false end
		applying = true
		pcall(el.Set, prev)
		applying = false
		return true
	end)
	Method(el, "GetHistory", function() return CopyList(history) end)
	Method(el, "ClearHistory", function() table.clear(history) end)
	Method(el, "GetPrevious", function() return history[#history] end)
	Method(el, "Reset", function() X.ResetElement(el) end)
	Method(el, "Serialize", function() return SerializeFlag(el) end)
	Method(el, "Deserialize", function(v) ApplyFlag(el, v) end)

	-- Order inside the section.
	Method(el, "SetOrder", function(n) row.LayoutOrder = tonumber(n) or row.LayoutOrder end)
	Method(el, "GetOrder", function() return row.LayoutOrder end)
	Method(el, "MoveToTop", function() row.LayoutOrder = -1e6 - S.Order end)
	Method(el, "MoveToBottom", function()
		S.Order = S.Order + 1
		row.LayoutOrder = S.Order + 1e6
	end)

	-- Tags for bulk operations (Window.GetElementsByTag, Library.GetOptionsByTag).
	Method(el, "AddTag", function(t) el.Tags[tostring(t)] = true return el end)
	Method(el, "RemoveTag", function(t) el.Tags[tostring(t)] = nil return el end)
	Method(el, "HasTag", function(t) return el.Tags[tostring(t)] == true end)
	Method(el, "GetTags", function()
		local out = {}
		for k in pairs(el.Tags) do table.insert(out, k) end
		table.sort(out)
		return out
	end)

	if not X.ElementDocsDone then
		X.ElementDocsDone = true
		for _, d in ipairs({
			{"el.GetType() / GetName() / GetFlag() / GetRow() / GetSection() / GetWindow()", "Introspection."},
			{"el.Show() / Hide() / ToggleVisible() / Enable() / Disable()", "Shortcuts."},
			{"el.Lock(reason?) / Unlock() / IsLocked()", "Disabled until unlocked; the reason shows as a tooltip."},
			{"el.SetTooltip(text) / GetTooltip()", "Hover tooltip (also {Tooltip = \"...\"} in the options)."},
			{"el.Highlight(duration?, color?)", "Accent flash behind the element (alias Pulse)."},
			{"el.Once(fn) / Watch(fn) / OnChangedTo(value, fn) / OnChangedDebounced(fn, wait)", "Change listeners."},
			{"el.Bind(elementOrFlag, transform?)", "Mirror another element's value (alias LinkTo)."},
			{"el.Undo() / GetHistory() / GetPrevious() / ClearHistory()", "Value history (last 25 changes)."},
			{"el.Reset() / Serialize() / Deserialize(v)", "Defaults and config values."},
			{"el.SetOrder(n) / GetOrder() / MoveToTop() / MoveToBottom()", "Position inside the section."},
			{"el.AddTag(t) / RemoveTag(t) / HasTag(t) / GetTags()", "Tags ({Tags = {...}} in the options)."},
		}) do X.Doc(G, d[1], d[2]) end
	end
end

-- Small themed button used by the new elements and dialogs. kind: "primary" | "danger" | nil.
function X.Button(W, parent, text, o)
	o = o or {}
	local b = Create("TextButton", {
		Size = o.Size or UDim2.new(0, 0, 1, 0),
		AutomaticSize = o.Size and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.new(),
		BorderSizePixel = 0,
		Text = tostring(text),
		TextSize = o.TextSize or TEXT,
		Weight = o.Weight or "Medium",
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
		Parent = parent,
	})
	Corner(b, o.Radius or 3)
	local st = Stroke(b, WHITE, 1)
	if not o.Size then
		Create("UIPadding", {PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9), Parent = b})
	end
	local api = {Instance = b, Enabled = true, Kind = o.Kind}
	local hover, pressed = false, false
	function api.Paint(animate)
		local T = W.Theme
		local en = api.Enabled
		local bg, fg, sc
		if api.Kind == "primary" or api.Kind == "danger" then
			local base = api.Kind == "danger" and X.Tones.error or W.Accent
			bg = base:Lerp(T.DropdownBg, en and (pressed and 0.25 or (hover and 0.1 or 0)) or 0.6)
			fg = en and (Luminance(bg) > 0.62 and rgb(20, 20, 24) or WHITE) or T.TextDim
			sc = bg
		else
			bg = T.DropdownBg
			if en and pressed then bg = T.TileHover:Lerp(T.Text, 0.06) elseif en and hover then bg = T.TileHover end
			fg = not en and T.TextDim or (hover and T.Text or T.TextGray)
			sc = (hover and en) and T.DropdownBorder:Lerp(T.Text, 0.12) or (en and T.DropdownBorder or T.DropdownBorderOff)
		end
		Anim(b, {BackgroundColor3 = bg, TextColor3 = fg}, animate)
		Anim(st, {Color = sc}, animate)
	end
	W.Bind(function() api.Paint(false) end, b)
	OnMouseEnter(b, function() hover = true api.Paint(true) end)
	b.MouseLeave:Connect(function() hover, pressed = false, false api.Paint(true) end)
	b.InputBegan:Connect(function(i) if IsClickOrTouch(i) then pressed = true api.Paint(true) end end)
	b.InputEnded:Connect(function(i) if IsClickOrTouch(i) then pressed = false api.Paint(true) end end)
	b.MouseButton1Click:Connect(function()
		if api.Enabled and o.Callback then SafeCall(o.Callback, api) end
	end)
	function api.SetText(t) b.Text = tostring(t) end
	function api.SetEnabled(v) api.Enabled = v ~= false api.Paint(true) end
	function api.SetCallback(fn) o.Callback = fn end
	function api.Fire() if api.Enabled and o.Callback then SafeCall(o.Callback, api) end end
	return api
end

function X.ExtendSection(W, S, o)
	local G = "Section methods"
	local st = {Collapsed = false}
	X.Sec[S] = st
	local function Elements()
		local out = {}
		for _, el in ipairs(W.Elements) do
			if el._section == S then table.insert(out, el) end
		end
		return out
	end
	local function Apply()
		for _, el in ipairs(Elements()) do
			el.Row.Visible = (not st.Collapsed) and el.Visible and not el._filtered
		end
		if st.Chevron then Tween(st.Chevron, MOVE_TI, {Rotation = st.Collapsed and -90 or 0}) end
	end
	Method(S, "GetElements", Elements)
	Method(S, "GetElement", function(ref)
		for _, el in ipairs(Elements()) do
			if el == ref or el.Flag == ref or el.Name == ref then return el end
		end
		return nil
	end)
	S.FindElement = S.GetElement
	Method(S, "Count", function() return #Elements() end)
	Method(S, "Clear", function()
		for _, el in ipairs(Elements()) do el.Destroy() end
	end)
	Method(S, "SetEnabled", function(b)
		for _, el in ipairs(Elements()) do el.SetEnabled(b) end
	end)
	Method(S, "Lock", function(reason)
		for _, el in ipairs(Elements()) do el.Lock(reason) end
	end)
	Method(S, "Unlock", function()
		for _, el in ipairs(Elements()) do el.Unlock() end
	end)
	Method(S, "SetCollapsed", function(b)
		st.Collapsed = b == true
		if st.Collapsed then W.ClosePopup() end
		Apply()
	end)
	Method(S, "IsCollapsed", function() return st.Collapsed end)
	Method(S, "Collapse", function() S.SetCollapsed(true) end)
	Method(S, "Expand", function() S.SetCollapsed(false) end)
	Method(S, "ToggleCollapsed", function() S.SetCollapsed(not st.Collapsed) end)
	-- Hides elements whose name doesn't match query (fuzzy); "" shows everything again.
	Method(S, "Filter", function(query, except)
		query = tostring(query or "")
		for _, el in ipairs(Elements()) do
			if el ~= except then
				local name = el.Name or el.Type
				el._filtered = query ~= "" and X.Fuzzy(name, query) == 0
			end
		end
		Apply()
	end)
	-- Declarative: S.AddElements{{Type = "Toggle", Name = "God", Flag = "God"}, ...} -> list
	Method(S, "AddElements", function(list)
		local out = {}
		for _, spec in ipairs(list or {}) do
			local kind = spec.Type or spec.Kind or spec.Element
			local fn = kind and (S["Add" .. tostring(kind)] or S[tostring(kind)])
			if type(fn) == "function" then
				local ok, el = pcall(fn, spec)
				if ok then
					table.insert(out, el)
				else
					warn("[Zenin] AddElements: " .. tostring(kind) .. " failed: " .. tostring(el))
				end
			else
				warn("[Zenin] AddElements: unknown element type " .. tostring(kind))
			end
		end
		return out
	end)
	S.Build = S.AddElements

	if S.Card and (o.Collapsible or o.Collapsed) and (o.Name or o.Title) then
		for _, c in ipairs(S.Card:GetChildren()) do
			if c:IsA("TextLabel") then c.Size = UDim2.new(1, -36, 0, 14) end
		end
		local hit = Create("TextButton", {Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Text = "", ZIndex = 3, Parent = S.Card})
		local ic = Create("ImageLabel", {
			Size = UDim2.fromOffset(12, 12), Position = UDim2.new(1, -21, 0, 9),
			BackgroundTransparency = 1, ZIndex = 3, Parent = S.Card,
		})
		if not ApplyIcon(ic, "chevron-down") then
			ic.Image = ""
			local t = Label(ic, "v", {Size = UDim2.fromScale(1, 1), Align = Enum.TextXAlignment.Center, TextSize = 10})
			W.Bind(function(T) t.TextColor3 = T.TextGray end, t)
		end
		W.Bind(function(T) ic.ImageColor3 = T.TextGray end, ic)
		st.Chevron = ic
		hit.MouseButton1Click:Connect(function() S.ToggleCollapsed() end)
		if o.Collapsed then
			st.Collapsed = true
			ic.Rotation = -90
		end
	end

	if not X.SectionDocsDone then
		X.SectionDocsDone = true
		for _, d in ipairs({
			{"Tab.AddSection{Name, Side, Collapsible = true, Collapsed = false}", "Collapsible sections (click the header)."},
			{"S.Collapse() / Expand() / SetCollapsed(b) / ToggleCollapsed() / IsCollapsed()", ""},
			{"S.GetElements() / GetElement(nameOrFlag) / Count() / Clear()", ""},
			{"S.SetEnabled(b) / Lock(reason?) / Unlock()", "Bulk state for every element in the section."},
			{"S.Filter(query)", "Hide elements that don't fuzzy-match the query."},
			{"S.AddElements{{Type = \"Toggle\", ...}, ...} -> list", "Declarative element creation (alias Build)."},
		}) do X.Doc(G, d[1], d[2]) end
	end
end

X.El = {}

function X.El.Spacer(W, S, o)
	if type(o) ~= "table" then o = {Height = o} end
	local h = tonumber(o.Height or o.Size) or 8
	local el, row = NewElement(W, S, "Spacer", {Visible = o.Visible}, math.max(h - 5, 0))
	Method(el, "Set", function(v)
		h = tonumber(v) or h
		row.Size = UDim2.new(1, 0, 0, math.max(h - 5, 0))
	end)
	Method(el, "Get", function() return h end)
	return el
end

function X.El.Header(W, S, o)
	if type(o) ~= "table" then o = {Text = o} end
	local el, row = NewElement(W, S, "Header", {Visible = o.Visible, Tooltip = o.Tooltip, Tags = o.Tags}, (tonumber(o.TextSize) or 12) + 6)
	local x, ic = 0, nil
	if o.Icon then
		ic = CreateIcon(row, o.Icon, 13, UDim2.new(0, 0, 0.5, -6.5))
		x = 18
	end
	local text = tostring(o.Text or o.Name or o.Title or "Header")
	local lbl = Label(row, text, {
		Position = UDim2.fromOffset(x, 0), Size = UDim2.new(1, -x, 1, 0),
		Weight = "SemiBold", TextSize = tonumber(o.TextSize) or 12, Truncate = true,
		Align = o.Center and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left,
	})
	local color = ToColor(o.Color)
	W.Bind(function(T, accent)
		lbl.TextColor3 = color or (o.Accent and accent) or T.Text
		if ic then ic.ImageColor3 = accent end
	end, row)
	Method(el, "Set", function(t) text = tostring(t) lbl.Text = text end)
	Method(el, "Get", function() return text end)
	el.SetText, el.SetName = el.Set, el.Set
	Method(el, "SetIcon", function(spec) if ic then ApplyIcon(ic, spec) end end)
	Method(el, "SetColor", function(c) color = ToColor(c) lbl.TextColor3 = color or W.Theme.Text end)
	return el
end

function X.El.Image(W, S, o)
	if type(o) ~= "table" then o = {Image = o} end
	local h = tonumber(o.Height) or 100
	local el, row = NewElement(W, S, "Image", {Visible = o.Visible, Tooltip = o.Tooltip, Tags = o.Tags}, h)
	local img = Create("ImageLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = o.Background and 0 or 1, BorderSizePixel = 0,
		ScaleType = Enum.ScaleType[o.ScaleType or "Fit"] or Enum.ScaleType.Fit, Parent = row,
	})
	Corner(img, tonumber(o.Corner) or 4)
	local color = ToColor(o.Color)
	W.Bind(function(T) img.BackgroundColor3 = T.DropdownBg img.ImageColor3 = color or WHITE end, row)
	local src = o.Image or o.Source
	local function Apply(spec)
		src = spec
		if type(spec) == "number" or (type(spec) == "string" and spec:match("^%d+$")) then
			img.Image = "rbxassetid://" .. tostring(spec)
		elseif type(spec) == "string" and spec:find("://", 1, true) then
			img.Image = spec
		else
			ApplyIcon(img, spec)
		end
	end
	Apply(src)
	Method(el, "Set", Apply)
	Method(el, "Get", function() return src end)
	Method(el, "SetHeight", function(v) h = tonumber(v) or h row.Size = UDim2.new(1, 0, 0, h) end)
	Method(el, "SetColor", function(c) color = ToColor(c) img.ImageColor3 = color or WHITE end)
	Method(el, "GetImage", function() return img end)
	return el
end

function X.El.Stat(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Stat", o, 18)
	local value = o.Value
	if value == nil then value = o.Default end
	local color = ToColor(o.Color)
	local x, ic = 0, nil
	if o.Icon then
		ic = CreateIcon(row, o.Icon, 12, UDim2.new(0, 0, 0.5, -6))
		x = 17
	end
	local name = Label(row, o.Name or o.Title or "Stat", {Position = UDim2.fromOffset(x, 0), Size = UDim2.new(1, -x, 1, 0), Truncate = true})
	local val = Label(row, "", {AutoX = true, Size = UDim2.new(0, 0, 1, 0), Weight = "SemiBold", Align = Enum.TextXAlignment.Right})
	val.AnchorPoint = Vector2.new(1, 0)
	val.Position = UDim2.fromScale(1, 0)
	val.RichText = o.RichText == true
	local function Render()
		local v = value
		if type(o.Format) == "function" then
			v = SafeCall(o.Format, v)
		elseif type(o.Format) == "string" and v ~= nil then
			local ok, s = pcall(string.format, o.Format, v)
			v = ok and s or v
		end
		local s = v == nil and "-" or tostring(v)
		val.Text = tostring(o.Prefix or "") .. s .. tostring(o.Suffix or "")
		name.Size = UDim2.new(1, -x - TextWidth(val.Text, TEXT) - 10, 1, 0)
	end
	function el._apply()
		local T = W.Theme
		name.TextColor3 = el.Enabled and T.TextGray or T.TextDim
		val.TextColor3 = not el.Enabled and T.TextDim or (color or (o.Accent and W.Accent) or T.Text)
		if ic then ic.ImageColor3 = el.Enabled and (o.IconColor and ToColor(o.IconColor) or W.Accent) or T.TextDim end
	end
	W.Bind(function() el._apply() end, row)
	Method(el, "Set", function(v)
		value = v
		Render()
		el._fire(v)
	end)
	Method(el, "Get", function() return value end)
	Method(el, "Increment", function(by)
		el.Set((tonumber(value) or 0) + (tonumber(by) or 1))
		return value
	end)
	Method(el, "Decrement", function(by) return el.Increment(-(tonumber(by) or 1)) end)
	Method(el, "SetColor", function(c) color = ToColor(c) el._apply() end)
	Method(el, "SetName", function(t) name.Text = tostring(t) end)
	Method(el, "SetFormat", function(f) o.Format = f Render() end)
	Render()
	if o.DependsOn then el.DependsOn(o.DependsOn, o.InvertDependency) end
	el._apply()
	return el
end

function X.El.Status(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Status", o, 18)
	local PRESET = {
		online = "success", ready = "success", active = "success", enabled = "success", running = "success",
		idle = "warning", waiting = "warning", paused = "warning",
		offline = "off", disabled = "off", stopped = "off",
		error = "error", failed = "error", busy = "error", loading = "info", working = "info",
	}
	local status = tostring(o.Status or o.Value or o.Default or "Idle")
	local color = ToColor(o.Color)
	local name = Label(row, o.Name or o.Title or "Status", {Size = UDim2.new(1, 0, 1, 0), Truncate = true})
	local right = Create("Frame", {
		Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), BackgroundTransparency = 1, Parent = row,
	})
	Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = right,
	})
	local dot = Create("Frame", {Size = UDim2.fromOffset(6, 6), BorderSizePixel = 0, LayoutOrder = 1, Parent = right})
	Corner(dot, 3)
	local txt = Label(right, status, {AutoX = true, Size = UDim2.new(0, 0, 1, 0), Weight = "SemiBold"})
	txt.LayoutOrder = 2
	local function Tone()
		if color then return color end
		local p = PRESET[status:lower()]
		if p == "off" then return W.Theme.TextDim end
		if p then return X.Tones[p] end
		return W.Accent
	end
	function el._apply()
		local T = W.Theme
		local c = Tone()
		name.TextColor3 = el.Enabled and T.TextGray or T.TextDim
		dot.BackgroundColor3 = c
		txt.TextColor3 = el.Enabled and T.Text or T.TextDim
	end
	W.Bind(function() el._apply() end, row)
	Method(el, "SetStatus", function(s, c)
		status = tostring(s)
		color = ToColor(c)
		txt.Text = status
		el._apply()
		el._fire(status)
	end)
	el.Set = el.SetStatus
	Method(el, "Get", function() return status end)
	Method(el, "SetName", function(t) name.Text = tostring(t) end)
	Method(el, "SetPulse", function(b)
		el.Maid.Pulse = nil
		dot.BackgroundTransparency = 0
		if b ~= false then
			local tw = TweenService:Create(dot, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {BackgroundTransparency = 0.7})
			tw:Play()
			el.Maid.Pulse = tw
		end
	end)
	if o.Pulse then el.SetPulse(true) end
	el._apply()
	return el
end

function X.El.Alert(W, S, o)
	if type(o) ~= "table" then o = {Content = o} end
	local el, row = NewElement(W, S, "Alert", {Visible = o.Visible, Tooltip = o.Tooltip, Tags = o.Tags, Enabled = o.Enabled}, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local kind, tone, iconName = X.Tone(o.Type or o.Kind or o.Variant)
	local box = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = row})
	Corner(box, 4)
	local st = Stroke(box, WHITE, 1)
	local bar = Create("Frame", {Size = UDim2.new(0, 2, 1, -10), Position = UDim2.fromOffset(5, 5), BorderSizePixel = 0, Parent = box})
	Corner(bar, 1)
	local ic = CreateIcon(box, o.Icon or iconName, 13, UDim2.fromOffset(13, 8))
	local inner = Create("Frame", {
		Size = UDim2.new(1, -40, 0, 0), Position = UDim2.fromOffset(32, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1, Parent = box,
	})
	Create("UIPadding", {PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 8), Parent = inner})
	Create("UIListLayout", {Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = inner})
	local title = Label(inner, o.Title or o.Name or (kind:sub(1, 1):upper() .. kind:sub(2)), {Size = UDim2.new(1, 0, 0, 14), Weight = "SemiBold", Truncate = true})
	title.LayoutOrder = 1
	local body = Label(inner, o.Content or o.Text or o.Description or "", {Size = UDim2.new(1, 0, 0, 0), TextSize = 10})
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.TextWrapped = true
	body.RichText = o.RichText == true
	body.LayoutOrder = 2
	body.Visible = body.Text ~= ""
	local close
	if o.Dismissible or o.Closable then
		close = Create("TextButton", {Size = UDim2.fromOffset(16, 16), Position = UDim2.new(1, -20, 0, 6), BackgroundTransparency = 1, Text = "×", TextSize = 14, Parent = box})
		close.MouseButton1Click:Connect(function()
			el.SetVisible(false)
			SafeCall(o.OnDismiss)
		end)
	end
	function el._apply()
		local T = W.Theme
		box.BackgroundColor3 = T.DropdownBg:Lerp(tone, 0.07)
		st.Color = T.DropdownBorder:Lerp(tone, 0.35)
		bar.BackgroundColor3 = tone
		ic.ImageColor3 = tone
		title.TextColor3 = el.Enabled and T.Text or T.TextDim
		body.TextColor3 = el.Enabled and T.TextGray or T.TextDim
		if close then close.TextColor3 = T.TextGray end
	end
	W.Bind(function() el._apply() end, row)
	Method(el, "SetTitle", function(t) title.Text = tostring(t) end)
	Method(el, "SetContent", function(t)
		body.Text = tostring(t or "")
		body.Visible = body.Text ~= ""
	end)
	el.Set, el.SetText = el.SetContent, el.SetContent
	Method(el, "Get", function() return body.Text end)
	Method(el, "SetType", function(t)
		kind, tone, iconName = X.Tone(t)
		ApplyIcon(ic, iconName)
		el._apply()
	end)
	Method(el, "GetType", function() return kind end)
	if o.DependsOn then el.DependsOn(o.DependsOn, o.InvertDependency) end
	el._apply()
	return el
end

function X.El.Code(W, S, o)
	if type(o) ~= "table" then o = {Code = o} end
	local el, row = NewElement(W, S, "Code", {Visible = o.Visible, Tooltip = o.Tooltip, Tags = o.Tags}, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local code = tostring(o.Code or o.Text or o.Content or "")
	local box = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = row})
	Corner(box, 4)
	local st = Stroke(box, WHITE, 1)
	Create("UIPadding", {
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8), Parent = box,
	})
	Create("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = box})
	local head = Create("Frame", {Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, LayoutOrder = 1, Parent = box})
	local title = Label(head, o.Title or o.Name or o.Language or "Code", {Size = UDim2.new(1, -50, 1, 0), TextSize = 10, Truncate = true})
	local copy
	if o.Copy ~= false then
		copy = X.Button(W, head, "Copy", {
			Size = UDim2.fromOffset(44, 16), Position = UDim2.new(1, -44, 0, 0), TextSize = 10,
			Callback = function(b)
				local ok = X.Clipboard(code)
				b.SetText(ok and "Copied" or "No clipboard")
				task.delay(1.2, function() b.SetText("Copy") end)
			end,
		})
	end
	local body = Label(box, code, {Size = UDim2.new(1, 0, 0, 0), TextSize = tonumber(o.TextSize) or 10})
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.TextWrapped = true
	body.LayoutOrder = 2
	pcall(function() body.FontFace = Font.fromEnum(Enum.Font.Code) end)
	W.Bind(function(T)
		box.BackgroundColor3 = T.DropdownBg:Lerp(T.WindowBg, 0.4)
		st.Color = T.DropdownBorder
		title.TextColor3 = T.TextDim
		body.TextColor3 = T.Text
	end, row)
	Method(el, "Set", function(t) code = tostring(t or "") body.Text = code end)
	Method(el, "Get", function() return code end)
	el.SetCode, el.SetText = el.Set, el.Set
	Method(el, "SetTitle", function(t) title.Text = tostring(t) end)
	Method(el, "Copy", function() return X.Clipboard(code) end)
	return el
end

function X.El.ButtonRow(W, S, o)
	o = Opts(o)
	local specs = o.Buttons or o.Items or o.Options or {}
	local el, row = NewElement(W, S, "ButtonRow", o, tonumber(o.Height) or 27)
	local holder = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = row})
	Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = holder,
	})
	local buttons = {}
	local function Build()
		for _, b in ipairs(buttons) do b.Instance:Destroy() end
		table.clear(buttons)
		local n = #specs
		for i, sp in ipairs(specs) do
			if type(sp) ~= "table" then sp = {Name = tostring(sp)} end
			local api
			api = X.Button(W, holder, sp.Name or sp.Text or sp.Title or ("Button " .. i), {
				Size = UDim2.new(1 / n, -(5 * (n - 1)) / n, 1, 0), LayoutOrder = i, Kind = sp.Kind or sp.Style,
				Callback = function()
					if not el.Enabled then return end
					local res = SafeCall(sp.Callback)
					SafeCall(o.Callback, sp.Name or sp.Text, i)
					el._fire(sp.Name or sp.Text, i)
					if type(res) == "string" then
						local old = api.Instance.Text
						api.SetText(res)
						task.delay(1.2, function() api.SetText(old) end)
					end
				end,
			})
			api.Spec = sp
			api.SelfEnabled = sp.Enabled ~= false and sp.Disabled ~= true
			api.SetEnabled(el.Enabled and api.SelfEnabled)
			buttons[i] = api
		end
	end
	function el._apply()
		for _, b in ipairs(buttons) do b.SetEnabled(el.Enabled and b.SelfEnabled) end
	end
	Method(el, "GetButton", function(i) return buttons[i] end)
	Method(el, "SetButtonText", function(i, t) if buttons[i] then buttons[i].SetText(t) end end)
	Method(el, "SetButtonEnabled", function(i, b)
		local btn = buttons[i]
		if not btn then return end
		btn.SelfEnabled = b ~= false
		btn.SetEnabled(el.Enabled and btn.SelfEnabled)
	end)
	Method(el, "Fire", function(i) if buttons[i] then buttons[i].Fire() end end)
	Method(el, "SetButtons", function(list) specs = list or {} Build() end)
	Method(el, "Get", function() return nil end)
	Build()
	if o.DependsOn then el.DependsOn(o.DependsOn, o.InvertDependency) end
	el._apply()
	return el
end

function X.El.ConfirmButton(W, S, o)
	o = Opts(o)
	local name = tostring(o.Name or o.Title or o.Text or "Confirm")
	local confirmText = tostring(o.ConfirmText or "Click again to confirm")
	local timeout = tonumber(o.Timeout) or 2.5
	local armed, token = false, 0
	local el
	el = AddPlainButton(W, S, {
		Name = name, Enabled = o.Enabled, Disabled = o.Disabled, Visible = o.Visible,
		DependsOn = o.DependsOn, InvertDependency = o.InvertDependency,
		Callback = function()
			if not armed then
				armed = true
				token = token + 1
				local my = token
				el.Flash(confirmText, timeout)
				task.delay(timeout, function() if token == my then armed = false end end)
				return nil
			end
			armed = false
			token = token + 1
			el.SetName(name)
			return SafeCall(o.Callback)
		end,
	})
	el.Type = "ConfirmButton"
	if o.Tooltip then el.SetTooltip(o.Tooltip) end
	Method(el, "IsArmed", function() return armed end)
	Method(el, "Cancel", function()
		armed = false
		token = token + 1
		el.SetName(name)
	end)
	return el
end

function X.El.Link(W, S, o)
	if type(o) == "string" then o = {Url = o} end
	o = Opts(o)
	local url = tostring(o.Url or o.Link or o.Href or "")
	local spec = {
		Name = o.Name or o.Title or url, Description = o.Description, Icon = o.Icon or (o.Description and "link") or nil,
		ButtonText = o.ButtonText or (o.Description and "Copy") or nil, Tooltip = o.Tooltip or url,
		Callback = function()
			local ok = X.Clipboard(url)
			if o.Notify ~= false and X.Win[W] then
				X.Win[W].Notify({Title = ok and "Link copied" or "Link", Content = url, Icon = "link", Duration = 3})
			end
			SafeCall(o.Callback, url)
			return ok and "Copied!" or nil
		end,
	}
	local el = S.AddButton(spec)
	if spec.Tooltip and el.SetTooltip then el.SetTooltip(spec.Tooltip) end
	Method(el, "GetUrl", function() return url end)
	Method(el, "SetUrl", function(u) url = tostring(u) end)
	return el
end

-- Shared builder for Radio (single) and CheckboxGroup (multi) lists.
function X.ChoiceList(W, S, o, multi)
	o = Opts(o)
	local options = CopyList(o.Options or o.Values or o.List)
	local name = o.Name or o.Title
	local top = name and 18 or 0
	local ITEM = 20
	local el, row = NewElement(W, S, multi and "CheckboxGroup" or "Radio", o, top + #options * ITEM)
	local value
	local selected = {}
	if multi then
		local src = o.Default or o.Value or {}
		if type(src) ~= "table" then src = {src} end
		for k, v in pairs(src) do
			if type(k) == "number" then selected[v] = true elseif v then selected[k] = true end
		end
	else
		value = o.Default or o.Value
		if value ~= nil and not IndexOf(options, value) then value = nil end
		if value == nil and o.AllowNone ~= true then value = options[1] end
	end
	local title = name and Label(row, name, {Size = UDim2.new(1, 0, 0, 14), Truncate = true})
	local holder = Create("Frame", {Size = UDim2.new(1, 0, 1, -top), Position = UDim2.fromOffset(0, top), BackgroundTransparency = 1, Parent = row})
	local items = {}
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
	local function IsOn(opt)
		if multi then return selected[opt] == true end
		return opt == value
	end
	function el._apply(animate)
		local T, en = W.Theme, el.Enabled
		if title then title.TextColor3 = en and T.TextGray or T.TextDim end
		local a = W.AccentAlpha * (en and 1 or 0.45)
		for _, it in ipairs(items) do
			local on = IsOn(it.opt)
			if multi then
				Anim(it.box, {BackgroundColor3 = on and W.Accent or T.DropdownBg, BackgroundTransparency = on and (1 - a) or 0}, animate)
				it.check.ImageColor3 = OnAccent(W)
				Anim(it.check, {ImageTransparency = on and 0 or 1}, animate)
			else
				Anim(it.box, {BackgroundColor3 = T.DropdownBg}, animate)
				Anim(it.dot, {BackgroundColor3 = W.Accent, BackgroundTransparency = on and (1 - a) or 1}, animate)
			end
			Anim(it.st, {Color = on and W.Accent or (en and (it.hover and T.DropdownBorder:Lerp(T.Text, 0.15) or T.DropdownBorder) or T.DropdownBorderOff)}, animate)
			Anim(it.lbl, {TextColor3 = not en and T.TextDim or ((on or it.hover) and T.Text or T.TextGray)}, animate)
		end
	end
	local function Commit(silent)
		el.Value = Current()
		el._apply(true)
		if silent then el._sync(Current()) else el._fire(Current()) end
	end
	local function Build()
		for _, it in ipairs(items) do it.btn:Destroy() end
		table.clear(items)
		row.Size = UDim2.new(1, 0, 0, top + #options * ITEM)
		for i, opt in ipairs(options) do
			local btn = Create("TextButton", {
				Size = UDim2.new(1, 0, 0, ITEM), Position = UDim2.fromOffset(0, (i - 1) * ITEM),
				BackgroundTransparency = 1, Text = "", Parent = holder,
			})
			local box = Create("Frame", {Size = UDim2.fromOffset(12, 12), Position = UDim2.new(0, 0, 0.5, -6), BorderSizePixel = 0, Parent = btn})
			Corner(box, multi and 3 or 6)
			local it = {btn = btn, box = box, st = Stroke(box, WHITE, 1), opt = opt}
			if multi then
				it.check = CreateIcon(box, "check", 10, UDim2.fromOffset(1, 1))
			else
				it.dot = Create("Frame", {Size = UDim2.fromOffset(6, 6), Position = UDim2.fromOffset(3, 3), BorderSizePixel = 0, Parent = box})
				Corner(it.dot, 3)
			end
			it.lbl = Label(btn, tostring(opt), {Position = UDim2.fromOffset(19, 0), Size = UDim2.new(1, -19, 1, 0), Truncate = true})
			table.insert(items, it)
			OnMouseEnter(btn, function() it.hover = true el._apply(true) end)
			btn.MouseLeave:Connect(function() it.hover = false el._apply(true) end)
			btn.MouseButton1Click:Connect(function()
				if not el.Enabled then return end
				if multi then
					selected[opt] = not selected[opt] or nil
					Commit(false)
				elseif value ~= opt then
					value = opt
					Commit(false)
				end
			end)
		end
		el._apply(false)
	end
	W.Bind(function() el._apply(false) end, row)
	Method(el, "Set", function(v, silent)
		if multi then
			selected = {}
			if type(v) ~= "table" then v = {v} end
			for k, x in pairs(v) do
				if type(k) == "number" then
					if IndexOf(options, x) then selected[x] = true end
				elseif x and IndexOf(options, k) then
					selected[k] = true
				end
			end
		else
			if v ~= nil and not IndexOf(options, v) then return end
			if v == nil and o.AllowNone ~= true then return end
			if v == value then el._sync(v) return end
			value = v
		end
		Commit(silent)
	end)
	Method(el, "Get", Current)
	Method(el, "GetOptions", function() return CopyList(options) end)
	Method(el, "SetOptions", function(list, silent)
		options = CopyList(list)
		if multi then
			for k in pairs(selected) do
				if not IndexOf(options, k) then selected[k] = nil end
			end
		elseif value ~= nil and not IndexOf(options, value) then
			value = (o.AllowNone ~= true) and options[1] or nil
		elseif value == nil and o.AllowNone ~= true then
			value = options[1]
		end
		Build()
		Commit(silent)
	end)
	el.Refresh = el.SetOptions
	Method(el, "AddOption", function(opt)
		if IndexOf(options, opt) then return end
		local l = CopyList(options)
		table.insert(l, opt)
		el.SetOptions(l, true)
	end)
	Method(el, "RemoveOption", function(opt)
		local l = CopyList(options)
		local i = IndexOf(l, opt)
		if not i then return end
		table.remove(l, i)
		el.SetOptions(l)
	end)
	Method(el, "IsSelected", function(opt) return IsOn(opt) end)
	Method(el, "SetName", function(t) if title then title.Text = tostring(t) end end)
	if multi then
		Method(el, "SelectAll", function()
			for _, opt in ipairs(options) do selected[opt] = true end
			Commit(false)
		end)
		Method(el, "Clear", function()
			selected = {}
			Commit(false)
		end)
		el.DeselectAll = el.Clear
		Method(el, "ToggleOption", function(opt)
			if not IndexOf(options, opt) then return end
			selected[opt] = not selected[opt] or nil
			Commit(false)
		end)
		Method(el, "GetCount", function() return #List() end)
	end
	el.Value = Current()
	Build()
	return Finish(el, o)
end

function X.El.Checkbox(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Checkbox", o, 20)
	local state = o.Default == true or o.Value == true
	el.Value = state
	local btn = Create("TextButton", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = row})
	local box = Create("Frame", {Size = UDim2.fromOffset(13, 13), Position = UDim2.new(0, 0, 0.5, -6.5), BorderSizePixel = 0, Parent = btn})
	Corner(box, 3)
	local st = Stroke(box, WHITE, 1)
	local check = CreateIcon(box, "check", 11, UDim2.fromOffset(1, 1))
	local lbl = Label(btn, o.Name or o.Title or "Checkbox", {Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -20, 1, 0), Truncate = true})
	local hover = false
	function el._apply(animate)
		local T, en = W.Theme, el.Enabled
		local a = W.AccentAlpha * (en and 1 or 0.45)
		Anim(box, {BackgroundColor3 = state and W.Accent or T.DropdownBg, BackgroundTransparency = state and (1 - a) or 0}, animate)
		Anim(st, {Color = state and W.Accent or (en and T.DropdownBorder or T.DropdownBorderOff)}, animate)
		check.ImageColor3 = OnAccent(W)
		Anim(check, {ImageTransparency = state and 0 or 1}, animate)
		Anim(lbl, {TextColor3 = not en and T.TextDim or ((state or hover) and T.Text or T.TextGray)}, animate)
	end
	W.Bind(function() el._apply(false) end, row)
	Method(el, "Set", function(v, silent)
		v = v and true or false
		local changed = v ~= state
		state = v
		el.Value = v
		el._apply(true)
		if changed and not silent then el._fire(v) else el._sync(v) end
	end)
	Method(el, "Get", function() return state end)
	Method(el, "Toggle", function() el.Set(not state) end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	btn.MouseButton1Click:Connect(function() if el.Enabled then el.Set(not state) end end)
	OnMouseEnter(btn, function() hover = true el._apply(true) end)
	btn.MouseLeave:Connect(function() hover = false el._apply(true) end)
	return Finish(el, o)
end

function X.Scroller(W, parent, height, top)
	local box = Create("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, height), Position = UDim2.fromOffset(0, top or 0), BorderSizePixel = 0,
		ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y, ElasticBehavior = Enum.ElasticBehavior.Never, Parent = parent,
	})
	Corner(box, 4)
	local st = Stroke(box, WHITE, 1)
	Create("UIPadding", {
		PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 7), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = box,
	})
	local layout = Create("UIListLayout", {Padding = UDim.new(0, 1), SortOrder = Enum.SortOrder.LayoutOrder, Parent = box})
	W.Bind(function(T)
		box.BackgroundColor3 = T.DropdownBg:Lerp(T.WindowBg, 0.35)
		st.Color = T.DropdownBorder
		box.ScrollBarImageColor3 = T.DropdownBorder:Lerp(T.Text, 0.2)
	end, box)
	return box, layout
end

function X.El.Log(W, S, o)
	o = Opts(o)
	local name = o.Name or o.Title
	local height = tonumber(o.Height) or 130
	local top = name and 22 or 0
	local el, row = NewElement(W, S, "Log", o, top + height)
	local maxLines = tonumber(o.MaxLines) or 150
	local stamps = o.Timestamps ~= false
	local autoScroll = o.AutoScroll ~= false
	local lines, order = {}, 0
	local title
	if name then
		title = Label(row, name, {Size = UDim2.new(1, -110, 0, 16), Truncate = true})
		local bar = Create("Frame", {
			Size = UDim2.new(0, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.X, AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0), BackgroundTransparency = 1, Parent = row,
		})
		Create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = bar,
		})
		X.Button(W, bar, "Copy", {TextSize = 10, LayoutOrder = 1, Callback = function(b)
			b.SetText(el.Copy() and "Copied" or "No clipboard")
			task.delay(1.2, function() b.SetText("Copy") end)
		end})
		X.Button(W, bar, "Clear", {TextSize = 10, LayoutOrder = 2, Callback = function() el.Clear() end})
	end
	local box = X.Scroller(W, row, height, top)
	local function Paint(e)
		local T = W.Theme
		local parts = {}
		if stamps then table.insert(parts, string.format('<font color="#%s">%s</font>', ToHex(T.TextDim), os.date("%H:%M:%S", e.Time))) end
		local msgColor = T.TextGray
		if e.Level ~= "log" then
			local _, tone = X.Tone(e.Level)
			table.insert(parts, string.format('<font color="#%s"><b>%s</b></font>', ToHex(tone), e.Level:upper()))
			if e.Level == "error" or e.Level == "warning" then msgColor = T.TextGray:Lerp(tone, 0.6) end
		end
		table.insert(parts, string.format('<font color="#%s">%s</font>', ToHex(msgColor), X.Esc(e.Text)))
		e.Label.Text = table.concat(parts, " ")
	end
	local function ScrollDown()
		task.defer(function()
			if box.Parent then
				box.CanvasPosition = Vector2.new(0, math.max(0, box.AbsoluteCanvasSize.Y - box.AbsoluteWindowSize.Y))
			end
		end)
	end
	local function Add(level, ...)
		local n = select("#", ...)
		local parts = {}
		for i = 1, n do parts[i] = tostring((select(i, ...))) end
		order = order + 1
		local lbl = Label(box, "", {Size = UDim2.new(1, 0, 0, 0), TextSize = tonumber(o.TextSize) or 10})
		lbl.AutomaticSize = Enum.AutomaticSize.Y
		lbl.TextWrapped = true
		lbl.RichText = true
		lbl.LayoutOrder = order
		if o.Monospace ~= false then pcall(function() lbl.FontFace = Font.fromEnum(Enum.Font.Code) end) end
		local e = {Level = level, Text = table.concat(parts, " "), Time = os.time(), Label = lbl}
		Paint(e)
		table.insert(lines, e)
		while #lines > maxLines do
			local old = table.remove(lines, 1)
			old.Label:Destroy()
		end
		if autoScroll then ScrollDown() end
		el._fire(e.Text, level)
		return e
	end
	W.Bind(function()
		if title then title.TextColor3 = W.Theme.TextGray end
		for _, e in ipairs(lines) do Paint(e) end
	end, row)
	for _, lvl in ipairs({"Log", "Info", "Success", "Warn", "Error", "Debug"}) do
		local level = lvl == "Warn" and "warning" or lvl:lower()
		Method(el, lvl, function(...) Add(level, ...) return el end)
	end
	el.Print, el.Warning, el.Add, el.Write = el.Log, el.Warn, el.Log, el.Log
	Method(el, "Set", function(t) el.Clear() if t then Add("log", t) end end)
	Method(el, "Get", function() return nil end)
	Method(el, "Clear", function()
		for _, e in ipairs(lines) do e.Label:Destroy() end
		table.clear(lines)
	end)
	Method(el, "GetLines", function()
		local out = {}
		for i, e in ipairs(lines) do out[i] = {Level = e.Level, Text = e.Text, Time = e.Time} end
		return out
	end)
	Method(el, "Export", function()
		local out = {}
		for i, e in ipairs(lines) do
			out[i] = string.format("[%s] %s%s", os.date("%H:%M:%S", e.Time), e.Level ~= "log" and (e.Level:upper() .. " ") or "", e.Text)
		end
		return table.concat(out, "\n")
	end)
	Method(el, "Copy", function() return X.Clipboard(el.Export()) end)
	Method(el, "Count", function() return #lines end)
	Method(el, "SetMaxLines", function(n) maxLines = math.max(1, tonumber(n) or maxLines) end)
	Method(el, "SetAutoScroll", function(b) autoScroll = b ~= false end)
	Method(el, "SetTimestamps", function(b)
		stamps = b ~= false
		for _, e in ipairs(lines) do Paint(e) end
	end)
	Method(el, "ScrollToBottom", ScrollDown)
	-- CaptureOutput = true mirrors the game's output (print / warn / errors) into this log.
	Method(el, "SetCaptureOutput", function(b)
		el.Maid.Capture = nil
		if b == false then return end
		local ok, ls = pcall(function() return game:GetService("LogService") end)
		if not ok then return end
		local busy = false
		el.Maid.Capture = ls.MessageOut:Connect(function(msg, kind)
			if busy then return end
			busy = true
			local lvl = "log"
			if kind == Enum.MessageType.MessageWarning then lvl = "warning"
			elseif kind == Enum.MessageType.MessageError then lvl = "error"
			elseif kind == Enum.MessageType.MessageInfo then lvl = "info" end
			pcall(Add, lvl, msg)
			busy = false
		end)
	end)
	if o.CaptureOutput then el.SetCaptureOutput(true) end
	for _, line in ipairs(type(o.Lines) == "table" and o.Lines or {}) do Add("log", line) end
	return el
end
X.El.Console = X.El.Log

function X.El.List(W, S, o)
	o = Opts(o)
	local name = o.Name or o.Title
	local height = tonumber(o.Height) or 120
	local top = name and 18 or 0
	local el, row = NewElement(W, S, "List", o, top + height)
	local items = CopyList(o.Items or o.Options or o.Values)
	local selected = o.Default or o.Value
	local query = ""
	local title = name and Label(row, name, {Size = UDim2.new(1, 0, 0, 14), Truncate = true})
	local box = X.Scroller(W, row, height, top)
	local empty = Label(box, o.EmptyText or "Nothing here", {Size = UDim2.new(1, 0, 0, 20), TextSize = 10, Align = Enum.TextXAlignment.Center})
	empty.LayoutOrder = 1e6
	local rows = {}
	local function Text(item)
		if type(o.Format) == "function" then return tostring(SafeCall(o.Format, item)) end
		if type(item) == "table" then return tostring(item.Name or item.Text or item.Title or item[1]) end
		return tostring(item)
	end
	function el._apply(animate)
		local T, en = W.Theme, el.Enabled
		if title then title.TextColor3 = en and T.TextGray or T.TextDim end
		empty.TextColor3 = T.TextDim
		for _, r in ipairs(rows) do
			local on = r.item == selected
			Anim(r.btn, {
				BackgroundColor3 = on and W.Accent or T.TileHover,
				BackgroundTransparency = on and (1 - 0.22 * W.AccentAlpha) or (r.hover and en and 0 or 1),
			}, animate)
			Anim(r.lbl, {TextColor3 = not en and T.TextDim or ((on or r.hover) and T.Text or T.TextGray)}, animate)
			if r.x then r.x.TextColor3 = r.xhover and X.Tones.error or T.TextDim end
		end
	end
	local function Build()
		for _, r in ipairs(rows) do r.btn:Destroy() end
		table.clear(rows)
		local shown = 0
		for i, item in ipairs(items) do
			local text = Text(item)
			if query == "" or X.Fuzzy(text, query) > 0 then
				shown = shown + 1
				local btn = Create("TextButton", {Size = UDim2.new(1, 0, 0, 22), BorderSizePixel = 0, Text = "", LayoutOrder = i, Parent = box})
				Corner(btn, 3)
				local r = {btn = btn, item = item}
				r.lbl = Label(btn, text, {Position = UDim2.fromOffset(7, 0), Size = UDim2.new(1, o.Removable and -30 or -14, 1, 0), Truncate = true})
				if o.Removable then
					r.x = Create("TextButton", {
						Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -20, 0.5, -9), BackgroundTransparency = 1,
						Text = "×", TextSize = 14, Parent = btn,
					})
					OnMouseEnter(r.x, function() r.xhover = true el._apply(true) end)
					r.x.MouseLeave:Connect(function() r.xhover = false el._apply(true) end)
					r.x.MouseButton1Click:Connect(function()
						if el.Enabled then el.RemoveItem(item) end
					end)
				end
				OnMouseEnter(btn, function() r.hover = true el._apply(true) end)
				btn.MouseLeave:Connect(function() r.hover = false el._apply(true) end)
				btn.MouseButton1Click:Connect(function()
					if not el.Enabled then return end
					if selected == item and o.Toggleable then el.Set(nil) else el.Set(item) end
				end)
				table.insert(rows, r)
			end
		end
		empty.Visible = shown == 0
		el._apply(false)
	end
	W.Bind(function() el._apply(false) end, row)
	Method(el, "Set", function(item, silent)
		if item ~= nil and not IndexOf(items, item) then return end
		local changed = item ~= selected
		selected = item
		el.Value = item
		el._apply(true)
		if changed and not silent then el._fire(item) else el._sync(item) end
	end)
	el.Select = el.Set
	Method(el, "Deselect", function() el.Set(nil) end)
	Method(el, "Get", function() return selected end)
	Method(el, "GetItems", function() return CopyList(items) end)
	Method(el, "SetItems", function(list)
		items = CopyList(list)
		if selected ~= nil and not IndexOf(items, selected) then el.Set(nil) end
		Build()
	end)
	el.SetOptions = el.SetItems
	Method(el, "AddItem", function(item, index)
		if index then table.insert(items, math.clamp(index, 1, #items + 1), item) else table.insert(items, item) end
		Build()
	end)
	el.Add = el.AddItem
	Method(el, "RemoveItem", function(ref)
		local i = type(ref) == "number" and items[ref] ~= nil and ref or IndexOf(items, ref)
		if not i then return false end
		local item = table.remove(items, i)
		if item == selected then el.Set(nil) end
		Build()
		SafeCall(o.OnRemoved, item)
		return true
	end)
	el.Remove = el.RemoveItem
	Method(el, "Clear", function()
		items = {}
		el.Set(nil)
		Build()
	end)
	Method(el, "Count", function() return #items end)
	Method(el, "Filter", function(q) query = tostring(q or "") Build() end)
	Method(el, "SetName", function(t) if title then title.Text = tostring(t) end end)
	Build()
	return Finish(el, o)
end

function X.El.Table(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Table", o, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local columns = CopyList(o.Columns or o.Headers)
	local data = {}
	for i, r in ipairs(o.Rows or o.Data or {}) do data[i] = CopyList(r) end
	local box = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, ClipsDescendants = true, Parent = row})
	Corner(box, 4)
	local st = Stroke(box, WHITE, 1)
	Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = box})
	local lines = {}
	local function Widths(n)
		local w = o.Widths
		local out, sum = {}, 0
		for i = 1, n do
			out[i] = tonumber(w and w[i]) or 1
			sum = sum + out[i]
		end
		for i = 1, n do out[i] = out[i] / sum end
		return out
	end
	local function Line(cells, header, idx)
		local n = math.max(#columns, #cells, 1)
		local widths = Widths(n)
		local f = Create("Frame", {Size = UDim2.new(1, 0, 0, header and 20 or 18), BorderSizePixel = 0, LayoutOrder = idx, Parent = box})
		local x, labels = 0, {}
		for i = 1, n do
			local l = Label(f, tostring(cells[i] == nil and "" or cells[i]), {
				Position = UDim2.new(x, 8, 0, 0), Size = UDim2.new(widths[i], -12, 1, 0),
				TextSize = header and 10 or 10, Weight = header and "SemiBold" or "Medium", Truncate = true,
				Align = (o.Align and o.Align[i] == "Right") and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
			})
			l.RichText = o.RichText == true
			labels[i] = l
			x = x + widths[i]
		end
		table.insert(lines, {frame = f, labels = labels, header = header, idx = idx})
	end
	local function Paint()
		local T = W.Theme
		box.BackgroundColor3 = T.DropdownBg:Lerp(T.WindowBg, 0.35)
		st.Color = T.DropdownBorder
		for _, ln in ipairs(lines) do
			if ln.header then
				ln.frame.BackgroundColor3 = T.DropdownBg
				ln.frame.BackgroundTransparency = 0
			else
				ln.frame.BackgroundColor3 = T.TileHover
				ln.frame.BackgroundTransparency = ln.idx % 2 == 0 and 0.4 or 1
			end
			for _, l in ipairs(ln.labels) do
				l.TextColor3 = ln.header and T.Text or (el.Enabled and T.TextGray or T.TextDim)
			end
		end
	end
	local function Render()
		for _, ln in ipairs(lines) do ln.frame:Destroy() end
		table.clear(lines)
		if #columns > 0 then Line(columns, true, 0) end
		for i, r in ipairs(data) do Line(r, false, i) end
		if #data == 0 and o.EmptyText ~= false then Line({o.EmptyText or "No rows"}, false, 1) end
		Paint()
	end
	function el._apply() Paint() end
	W.Bind(function() Paint() end, row)
	Method(el, "SetRows", function(rows)
		data = {}
		for i, r in ipairs(rows or {}) do data[i] = CopyList(r) end
		Render()
	end)
	el.Set = el.SetRows
	Method(el, "Get", function()
		local out = {}
		for i, r in ipairs(data) do out[i] = CopyList(r) end
		return out
	end)
	el.GetRows = el.Get
	Method(el, "AddRow", function(r, index)
		if index then table.insert(data, math.clamp(index, 1, #data + 1), CopyList(r)) else table.insert(data, CopyList(r)) end
		Render()
	end)
	Method(el, "RemoveRow", function(i)
		if data[i] then table.remove(data, i) Render() return true end
		return false
	end)
	Method(el, "SetCell", function(r, c, v)
		if not data[r] then return end
		data[r][c] = v
		Render()
	end)
	Method(el, "GetCell", function(r, c) return data[r] and data[r][c] end)
	Method(el, "SetColumns", function(cols) columns = CopyList(cols) Render() end)
	Method(el, "Clear", function() data = {} Render() end)
	Method(el, "Count", function() return #data end)
	-- Rows from a dictionary: SetDictionary({Kills = 5, Deaths = 2}) -> two-column sorted table.
	Method(el, "SetDictionary", function(t)
		local keys = {}
		for k in pairs(t or {}) do table.insert(keys, k) end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		data = {}
		for i, k in ipairs(keys) do data[i] = {k, t[k]} end
		Render()
	end)
	Render()
	return el
end

function X.El.Graph(W, S, o)
	o = Opts(o)
	local name = o.Name or o.Title
	local height = tonumber(o.Height) or 60
	local top = name and 18 or 0
	local el, row = NewElement(W, S, "Graph", o, top + height)
	local points = math.clamp(math.floor(tonumber(o.Points or o.MaxPoints) or 30), 2, 200)
	local values = {}
	for _, v in ipairs(o.Values or o.Default or {}) do table.insert(values, tonumber(v) or 0) end
	local minV, maxV = tonumber(o.Min) or 0, tonumber(o.Max)
	local color = ToColor(o.Color)
	local title, valLbl
	if name then
		title = Label(row, name, {Size = UDim2.new(0.6, 0, 0, 14), Truncate = true})
		valLbl = Label(row, "", {Position = UDim2.new(0.4, 0, 0, 0), Size = UDim2.new(0.6, 0, 0, 14), Weight = "SemiBold", Align = Enum.TextXAlignment.Right})
	end
	local frame = Create("Frame", {Size = UDim2.new(1, 0, 0, height), Position = UDim2.fromOffset(0, top), BorderSizePixel = 0, ClipsDescendants = true, Parent = row})
	Corner(frame, 4)
	local st = Stroke(frame, WHITE, 1)
	local inner = Create("Frame", {Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4), BackgroundTransparency = 1, Parent = frame})
	local guide = Create("Frame", {Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, 0.5), BorderSizePixel = 0, BackgroundTransparency = 0.5, Parent = inner})
	local bars = {}
	for i = 1, points do
		local b = Create("Frame", {
			AnchorPoint = Vector2.new(0, 1), Position = UDim2.new((i - 1) / points, 0, 1, 0), Size = UDim2.new(1 / points, -1, 0, 0),
			BorderSizePixel = 0, Parent = inner,
		})
		Corner(b, 1)
		bars[i] = b
	end
	local function Fmt(v)
		if v == nil then return "-" end
		if type(o.Format) == "function" then return tostring(SafeCall(o.Format, v)) end
		local d = tonumber(o.Decimals) or (v == math.floor(v) and 0 or 1)
		return string.format("%." .. d .. "f", v) .. tostring(o.Suffix or "")
	end
	local function Render()
		while #values > points do table.remove(values, 1) end
		local mx = maxV
		if not mx then
			mx = minV
			for _, v in ipairs(values) do if v > mx then mx = v end end
			if mx == minV then mx = minV + 1 end
		end
		local accent = color or W.Accent
		local n = #values
		for i = 1, points do
			local v = values[n - points + i]
			local b = bars[i]
			if v == nil then
				b.Visible = false
			else
				b.Visible = true
				local h = math.clamp((v - minV) / (mx - minV), 0, 1)
				b.Size = UDim2.new(1 / points, -1, math.max(h, 0.02), 0)
				b.BackgroundColor3 = accent
				b.BackgroundTransparency = (i == points) and 0.05 or 0.45
			end
		end
		if valLbl then valLbl.Text = Fmt(values[n]) end
	end
	W.Bind(function(T)
		frame.BackgroundColor3 = T.DropdownBg:Lerp(T.WindowBg, 0.35)
		st.Color = T.DropdownBorder
		guide.BackgroundColor3 = T.Divider
		if title then title.TextColor3 = T.TextGray end
		if valLbl then valLbl.TextColor3 = T.Text end
		Render()
	end, row)
	Method(el, "Push", function(v)
		table.insert(values, tonumber(v) or 0)
		Render()
		el._fire(tonumber(v) or 0)
	end)
	el.Add, el.AddPoint = el.Push, el.Push
	Method(el, "Set", function(list)
		values = {}
		for _, v in ipairs(list or {}) do table.insert(values, tonumber(v) or 0) end
		Render()
	end)
	Method(el, "Get", function() return CopyList(values) end)
	Method(el, "Clear", function() values = {} Render() end)
	Method(el, "SetMax", function(v) maxV = tonumber(v) Render() end)
	Method(el, "SetMin", function(v) minV = tonumber(v) or 0 Render() end)
	Method(el, "SetColor", function(c) color = ToColor(c) Render() end)
	Method(el, "GetLast", function() return values[#values] end)
	Method(el, "GetAverage", function()
		if #values == 0 then return 0 end
		local s = 0
		for _, v in ipairs(values) do s = s + v end
		return s / #values
	end)
	Method(el, "SetName", function(t) if title then title.Text = tostring(t) end end)
	-- Track(fn, interval): pushes fn() every interval seconds (e.g. FPS / ping graphs).
	Method(el, "Track", function(fn, interval)
		el.Maid.Track = nil
		if type(fn) ~= "function" then return end
		local alive = true
		el.Maid.Track = function() alive = false end
		task.spawn(function()
			while alive and row.Parent do
				local ok, v = pcall(fn)
				if ok and tonumber(v) then el.Push(v) end
				task.wait(tonumber(interval) or 1)
			end
		end)
	end)
	if o.Track then el.Track(o.Track, o.Interval) end
	Render()
	return el
end
X.El.Chart = X.El.Graph

function X.El.Timer(W, S, o)
	o = Opts(o)
	local countdown = o.Countdown ~= false and o.Stopwatch ~= true and o.Mode ~= "Stopwatch"
	local duration = math.max(tonumber(o.Duration or o.Time or o.Seconds) or 60, 0)
	local el, row = NewElement(W, S, "Timer", o, countdown and 24 or 20)
	local elapsed, running = 0, false
	local name = Label(row, o.Name or o.Title or (countdown and "Countdown" or "Stopwatch"), {Size = UDim2.new(1, -80, 0, 18), Truncate = true})
	local timeLbl = Label(row, "", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 80, 0, 18),
		Weight = "SemiBold", Align = Enum.TextXAlignment.Right,
	})
	pcall(function() timeLbl.FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.SemiBold) end)
	local track, fill
	if countdown then
		track = Create("Frame", {Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -3), BorderSizePixel = 0, Parent = row})
		Corner(track, 1)
		fill = Create("Frame", {Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = track})
		Corner(fill, 1)
	end
	local function Fmt(s)
		if type(o.Format) == "function" then return tostring(SafeCall(o.Format, s)) end
		s = math.max(0, s)
		local whole = math.floor(s)
		local h, m, sec = math.floor(whole / 3600), math.floor(whole % 3600 / 60), whole % 60
		local base = h > 0 and string.format("%d:%02d:%02d", h, m, sec) or string.format("%02d:%02d", m, sec)
		if o.Milliseconds then base = base .. string.format(".%d", math.floor((s - whole) * 10)) end
		return base
	end
	local function Render()
		local shown = countdown and (duration - elapsed) or elapsed
		if countdown and not o.Milliseconds then shown = math.ceil(shown - 1e-6) end
		timeLbl.Text = Fmt(shown)
		if fill then fill.Size = UDim2.fromScale(duration > 0 and math.clamp(1 - elapsed / duration, 0, 1) or 0, 1) end
	end
	function el._apply()
		local T = W.Theme
		name.TextColor3 = el.Enabled and T.TextGray or T.TextDim
		timeLbl.TextColor3 = running and T.Text or T.TextGray
		if track then
			track.BackgroundColor3 = T.SliderTrack
			fill.BackgroundColor3 = W.Accent
			fill.BackgroundTransparency = 1 - W.AccentAlpha
		end
	end
	W.Bind(function() el._apply() end, row)
	local function Stop()
		running = false
		el.Maid.Tick = nil
		el._apply()
	end
	Method(el, "Start", function()
		if running then return el end
		if countdown and elapsed >= duration then elapsed = 0 end
		running = true
		el._apply()
		el.Maid.Tick = RunService.Heartbeat:Connect(function(dt)
			elapsed = elapsed + dt
			if countdown and elapsed >= duration then
				elapsed = duration
				Render()
				Stop()
				SafeCall(o.OnFinish or o.OnFinished)
				el._fire(true)
				if o.Loop then el.Restart() end
				return
			end
			Render()
			if o.OnTick then SafeCall(o.OnTick, countdown and (duration - elapsed) or elapsed) end
		end)
		return el
	end)
	el.Resume = el.Start
	Method(el, "Pause", function() Stop() return el end)
	el.Stop = el.Pause
	Method(el, "Toggle", function() if running then Stop() else el.Start() end end)
	Method(el, "Reset", function()
		Stop()
		elapsed = 0
		Render()
	end)
	Method(el, "Restart", function()
		Stop()
		elapsed = 0
		Render()
		el.Start()
	end)
	Method(el, "IsRunning", function() return running end)
	Method(el, "GetElapsed", function() return elapsed end)
	Method(el, "GetRemaining", function() return math.max(duration - elapsed, 0) end)
	Method(el, "SetDuration", function(s)
		duration = math.max(tonumber(s) or duration, 0)
		Render()
	end)
	Method(el, "GetDuration", function() return duration end)
	Method(el, "AddTime", function(s)
		if countdown then duration = duration + (tonumber(s) or 0) else elapsed = math.max(0, elapsed + (tonumber(s) or 0)) end
		Render()
	end)
	Method(el, "Get", function() return countdown and math.max(duration - elapsed, 0) or elapsed end)
	Method(el, "Set", function(s)
		if countdown then duration = math.max(tonumber(s) or duration, 0) elapsed = 0 else elapsed = math.max(tonumber(s) or 0, 0) end
		Render()
	end)
	Method(el, "SetName", function(t) name.Text = tostring(t) end)
	Render()
	if o.AutoStart then el.Start() end
	el._apply()
	return el
end
X.El.Countdown = X.El.Timer
function X.El.Stopwatch(W, S, o)
	o = Opts(o)
	o.Countdown = false
	return X.El.Timer(W, S, o)
end

-- Dropdowns that keep themselves up to date. Values are names; GetPlayer(s) returns objects.
function X.LiveDropdown(W, S, o, kind)
	o = Opts(o)
	local map = {}
	local leaving
	local function Names()
		table.clear(map)
		local out = {}
		if kind == "Player" then
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= leaving and not (o.ExcludeLocal and p == LocalPlayer) then
					local label = p.Name
					if o.DisplayNames then label = p.DisplayName == p.Name and p.Name or (p.DisplayName .. " (@" .. p.Name .. ")") end
					map[label] = p
					table.insert(out, label)
				end
			end
		else
			local ok, teams = pcall(function() return game:GetService("Teams"):GetTeams() end)
			for _, t in ipairs(ok and teams or {}) do
				if t ~= leaving then
					map[t.Name] = t
					table.insert(out, t.Name)
				end
			end
		end
		table.sort(out, function(a, b) return a:lower() < b:lower() end)
		return out
	end
	local spec = X.Copy(o)
	spec.Options = Names()
	if spec.AllowNone == nil then spec.AllowNone = true end
	local multi = o.Multi == true
	local el = multi and S.AddMultiDropdown(spec) or S.AddDropdown(spec)
	local function Refresh()
		el.SetOptions(Names(), true)
		leaving = nil
	end
	if kind == "Player" then
		el.GiveTask(Players.PlayerAdded:Connect(function() Refresh() end))
		el.GiveTask(Players.PlayerRemoving:Connect(function(p) leaving = p Refresh() end))
	else
		local ok, teams = pcall(function() return game:GetService("Teams") end)
		if ok then
			el.GiveTask(teams.ChildAdded:Connect(function() task.defer(Refresh) end))
			el.GiveTask(teams.ChildRemoved:Connect(function() task.defer(Refresh) end))
		end
	end
	Method(el, "Refresh" .. kind .. "s", Refresh)
	local function Objects()
		local v = el.Get()
		local out = {}
		if type(v) == "table" then
			for _, n in ipairs(v) do if map[n] then table.insert(out, map[n]) end end
		elseif v ~= nil and map[v] then
			table.insert(out, map[v])
		end
		return out
	end
	Method(el, "Get" .. kind, function() return Objects()[1] end)
	Method(el, "Get" .. kind .. "s", Objects)
	return el
end
function X.El.PlayerDropdown(W, S, o) return X.LiveDropdown(W, S, o, "Player") end
function X.El.TeamDropdown(W, S, o) return X.LiveDropdown(W, S, o, "Team") end

function X.El.ColorPalette(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "ColorPalette", o, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local DEFAULT = {"#FF5959", "#F97316", "#FACC15", "#4ADE80", "#2DD4BF", "#38BDF8", "#818CF8", "#C084FC", "#F472B6", "#FFFFFF", "#94A3B8", "#1E293B"}
	local colors = {}
	for _, c in ipairs(o.Colors or DEFAULT) do table.insert(colors, ToColor(c) or WHITE) end
	local index = 1
	local function Find(v)
		if type(v) == "number" then return colors[v] and v or nil end
		local c = ToColor(v)
		if not c then return nil end
		for i, x in ipairs(colors) do
			if ToHex(x) == ToHex(c) then return i end
		end
		return nil
	end
	index = Find(o.Default or o.Value) or 1
	Create("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = row})
	local name = o.Name or o.Title
	local title = name and Label(row, name, {Size = UDim2.new(1, 0, 0, 14), Truncate = true})
	if title then title.LayoutOrder = 1 end
	local grid = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2, Parent = row})
	local size = tonumber(o.SwatchSize) or 18
	Create("UIGridLayout", {CellSize = UDim2.fromOffset(size, size), CellPadding = UDim2.fromOffset(5, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid})
	local swatches = {}
	function el._apply(animate)
		local T = W.Theme
		if title then title.TextColor3 = el.Enabled and T.TextGray or T.TextDim end
		for i, sw in ipairs(swatches) do
			local on = i == index
			sw.btn.BackgroundColor3 = colors[i]
			sw.btn.BackgroundTransparency = el.Enabled and 0 or 0.5
			Anim(sw.st, {Color = on and T.Text or T.DropdownBorder, Thickness = on and 2 or 1}, animate)
		end
	end
	local function Build()
		for _, sw in ipairs(swatches) do sw.btn:Destroy() end
		table.clear(swatches)
		for i in ipairs(colors) do
			local btn = Create("TextButton", {BorderSizePixel = 0, Text = "", LayoutOrder = i, Parent = grid})
			Corner(btn, 4)
			local sw = {btn = btn, st = Stroke(btn, WHITE, 1)}
			swatches[i] = sw
			btn.MouseButton1Click:Connect(function()
				if el.Enabled and index ~= i then
					index = i
					el._apply(true)
					el._fire(colors[i])
				end
			end)
		end
		el._apply(false)
	end
	W.Bind(function() el._apply(false) end, row)
	Method(el, "Set", function(v, silent)
		local i = Find(v)
		if not i then
			-- A colour that isn't a swatch yet becomes a new custom swatch.
			local c = type(v) ~= "number" and ToColor(v)
			if not c then return end
			table.insert(colors, c)
			Build()
			i = #colors
		end
		local changed = i ~= index
		index = i
		el._apply(true)
		if changed and not silent then el._fire(colors[i]) else el._sync(colors[i]) end
	end)
	Method(el, "Get", function() return colors[index] end)
	Method(el, "GetHex", function() return "#" .. ToHex(colors[index] or WHITE) end)
	Method(el, "GetIndex", function() return index end)
	Method(el, "SetColors", function(list)
		local cur = colors[index]
		colors = {}
		for _, c in ipairs(list or {}) do table.insert(colors, ToColor(c) or WHITE) end
		index = Find(cur) or 1
		Build()
	end)
	Method(el, "GetColors", function() return CopyList(colors) end)
	Method(el, "AddColor", function(c)
		c = ToColor(c)
		if not c or Find(c) then return false end
		table.insert(colors, c)
		Build()
		return true
	end)
	Method(el, "SetName", function(t) if title then title.Text = tostring(t) end end)
	function el._serialize() return "#" .. ToHex(colors[index] or WHITE) end
	function el._deserialize(v) el.Set(v) end
	Build()
	return Finish(el, o)
end

-- Live filter for the elements of a section (or several sections: Targets = {S1, S2}).
function X.El.Search(W, S, o)
	o = Opts(o)
	local targets = o.Targets or {S}
	local el
	el = S.AddInput({
		Name = o.Name or o.Title or "Search", Placeholder = o.Placeholder or "Type to filter...", Finished = false,
		Tooltip = o.Tooltip,
		Callback = function(q)
			for _, sec in ipairs(targets) do
				if sec.Filter then sec.Filter(q, el) end
			end
			SafeCall(o.Callback, q)
		end,
	})
	el.Type = "Search"
	Method(el, "Clear", function() el.Set("") end)
	return el
end
X.El.SearchBox = X.El.Search

function X.El.Rating(W, S, o)
	o = Opts(o)
	local max = math.clamp(math.floor(tonumber(o.Max) or 5), 1, 10)
	local el, row = NewElement(W, S, "Rating", o, 20)
	local value = math.clamp(math.floor(tonumber(o.Default or o.Value) or 0), 0, max)
	local hoverAt
	local lbl = Label(row, o.Name or o.Title or "Rating", {Size = UDim2.new(1, -max * 17, 1, 0), Truncate = true})
	local stars = {}
	for i = 1, max do
		local b = Create("ImageButton", {
			Size = UDim2.fromOffset(14, 14), Position = UDim2.new(1, -(max - i + 1) * 17 + 3, 0.5, -7),
			BackgroundTransparency = 1, Parent = row,
		})
		if not ApplyIcon(b, o.Icon or "star") then
			b.Image = ""
			local t = Label(b, "★", {Size = UDim2.fromScale(1, 1), Align = Enum.TextXAlignment.Center, TextSize = 13})
			stars[i] = {b = b, t = t}
		else
			stars[i] = {b = b}
		end
		OnMouseEnter(b, function() hoverAt = i el._apply() end)
		b.MouseLeave:Connect(function() if hoverAt == i then hoverAt = nil el._apply() end end)
		b.MouseButton1Click:Connect(function()
			if not el.Enabled then return end
			el.Set((o.AllowZero ~= false and value == i) and 0 or i)
		end)
	end
	function el._apply()
		local T = W.Theme
		lbl.TextColor3 = el.Enabled and T.TextGray or T.TextDim
		local upto = (el.Enabled and hoverAt) or value
		for i, s in ipairs(stars) do
			local c = i <= upto and (ToColor(o.Color) or W.Accent) or T.DropdownBorder
			if not el.Enabled then c = c:Lerp(T.WindowBg, 0.5) end
			s.b.ImageColor3 = c
			if s.t then s.t.TextColor3 = c end
		end
	end
	W.Bind(function() el._apply() end, row)
	Method(el, "Set", function(v, silent)
		v = math.clamp(math.floor(tonumber(v) or 0), 0, max)
		local changed = v ~= value
		value = v
		el._apply()
		if changed and not silent then el._fire(v) else el._sync(v) end
	end)
	Method(el, "Get", function() return value end)
	Method(el, "GetMax", function() return max end)
	Method(el, "SetName", function(t) lbl.Text = tostring(t) end)
	return Finish(el, o)
end

function X.El.TextArea(W, S, o)
	o = Opts(o)
	local name = o.Name or o.Title
	local height = tonumber(o.Height) or 70
	local top = name and 18 or 0
	local el, row = NewElement(W, S, "TextArea", o, top + height)
	local value = tostring(o.Default or o.Value or "")
	local title = name and Label(row, name, {Size = UDim2.new(1, -50, 0, 14), Truncate = true})
	local counter = o.MaxLength and Label(row, "", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 50, 0, 14),
		TextSize = 10, Align = Enum.TextXAlignment.Right,
	})
	local box = Create("TextBox", {
		Size = UDim2.new(1, 0, 0, height), Position = UDim2.fromOffset(0, top), BorderSizePixel = 0,
		Text = value, PlaceholderText = tostring(o.Placeholder or ""), ClearTextOnFocus = false, MultiLine = true,
		TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = TEXT, Weight = "Medium", ClipsDescendants = true, Parent = row,
	})
	Corner(box, 4)
	local st = Stroke(box, WHITE, 1)
	Create("UIPadding", {PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7), PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5), Parent = box})
	local focused = false
	local maxLen = tonumber(o.MaxLength)
	local function Count()
		if counter then counter.Text = #box.Text .. "/" .. maxLen end
	end
	function el._apply(animate)
		local T, en = W.Theme, el.Enabled
		box.TextEditable = en
		if title then title.TextColor3 = en and T.TextGray or T.TextDim end
		if counter then counter.TextColor3 = T.TextDim end
		Anim(box, {BackgroundColor3 = T.DropdownBg, TextColor3 = en and T.Text or T.TextDim, PlaceholderColor3 = T.TextDim}, animate)
		Anim(st, {Color = focused and W.Accent or (en and T.DropdownBorder or T.DropdownBorderOff)}, animate)
	end
	W.Bind(function() el._apply(false) end, row)
	local function Commit()
		if box.Text == value then return end
		value = box.Text
		el._fire(value)
	end
	box.Focused:Connect(function() focused = true el._apply(true) end)
	box.FocusLost:Connect(function()
		focused = false
		el._apply(true)
		Commit()
	end)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if maxLen and #box.Text > maxLen then box.Text = box.Text:sub(1, maxLen) end
		Count()
		if o.Finished == false then Commit() end
	end)
	Method(el, "Set", function(t, silent)
		t = tostring(t or "")
		if maxLen then t = t:sub(1, maxLen) end
		local changed = t ~= value
		value = t
		box.Text = t
		if changed and not silent then el._fire(t) else el._sync(t) end
	end)
	Method(el, "Get", function() return value end)
	Method(el, "Clear", function() el.Set("") end)
	Method(el, "Focus", function() box:CaptureFocus() end)
	Method(el, "SetPlaceholder", function(t) box.PlaceholderText = tostring(t or "") end)
	Method(el, "SetName", function(t) if title then title.Text = tostring(t) end end)
	Method(el, "GetLines", function() return Library.Util.Lines(value) end)
	Count()
	return Finish(el, o)
end
X.El.MultilineInput = X.El.TextArea

function X.El.Chips(W, S, o)
	o = Opts(o)
	local el, row = NewElement(W, S, "Chips", o, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local items = CopyList(o.Items or o.Options or o.Values or o.Tags)
	Create("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = row})
	local name = o.Name or o.Title
	local title = name and Label(row, name, {Size = UDim2.new(1, 0, 0, 14), Truncate = true})
	if title then title.LayoutOrder = 1 end
	local wrap = Create("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2, Parent = row})
	local layout = Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = wrap,
	})
	pcall(function() layout.Wraps = true end)
	local chips = {}
	function el._apply()
		local T = W.Theme
		if title then title.TextColor3 = el.Enabled and T.TextGray or T.TextDim end
		for _, c in ipairs(chips) do
			local tone = ToColor(c.color) or W.Accent
			c.btn.BackgroundColor3 = T.DropdownBg:Lerp(tone, el.Enabled and 0.18 or 0.06)
			c.st.Color = T.DropdownBorder:Lerp(tone, 0.45)
			c.btn.TextColor3 = el.Enabled and T.Text or T.TextDim
		end
	end
	local function Build()
		for _, c in ipairs(chips) do c.btn:Destroy() end
		table.clear(chips)
		for i, item in ipairs(items) do
			local text, color = item, nil
			if type(item) == "table" then text, color = item.Text or item.Name or item[1], item.Color end
			local btn = Create("TextButton", {
				Size = UDim2.new(0, 0, 0, 18), AutomaticSize = Enum.AutomaticSize.X, BorderSizePixel = 0,
				Text = tostring(text) .. (o.Removable and "  ×" or ""), TextSize = 10, Weight = "Medium", LayoutOrder = i, Parent = wrap,
			})
			Corner(btn, 9)
			Create("UIPadding", {PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = btn})
			local c = {btn = btn, st = Stroke(btn, WHITE, 1), color = color, item = item}
			table.insert(chips, c)
			btn.MouseButton1Click:Connect(function()
				if not el.Enabled then return end
				if o.Removable then el.RemoveItem(item) end
				el._fire(item)
			end)
		end
		el._apply()
	end
	W.Bind(function() el._apply() end, row)
	Method(el, "SetItems", function(list) items = CopyList(list) Build() end)
	el.Set = el.SetItems
	Method(el, "Get", function() return CopyList(items) end)
	el.GetItems = el.Get
	Method(el, "AddItem", function(item) table.insert(items, item) Build() end)
	Method(el, "RemoveItem", function(item)
		local i = IndexOf(items, item)
		if i then table.remove(items, i) Build() return true end
		return false
	end)
	Method(el, "Clear", function() items = {} Build() end)
	Build()
	return el
end
X.El.Tags = X.El.Chips

X.El.Radio = function(W, S, o) return X.ChoiceList(W, S, o, false) end
X.El.CheckboxGroup = function(W, S, o) return X.ChoiceList(W, S, o, true) end
X.El.KeyValue = X.El.Stat
X.El.Callout = X.El.Alert
X.El.Notice = X.El.Alert

X.ElementDocs = {
	{"Spacer", "S.AddSpacer(height | {Height})", "Empty vertical space."},
	{"Header", "S.AddHeader{Text, Icon, TextSize, Accent, Color, Center}", "Bold heading. Set / SetIcon / SetColor."},
	{"Image", "S.AddImage{Image, Height, ScaleType, Corner, Color}", "Asset id, URL or icon name. Set / SetHeight / SetColor."},
	{"Stat", "S.AddStat{Name, Value, Icon, Prefix, Suffix, Format, Color, Accent}", "Name / value row (alias AddKeyValue). Set / Increment / Decrement / SetFormat."},
	{"Status", "S.AddStatus{Name, Status, Color, Pulse}", "Coloured status dot (online, idle, error ...). SetStatus(text, color?) / SetPulse(b)."},
	{"Alert", "S.AddAlert{Title, Content, Type = info|success|warning|error, Dismissible}", "Callout box (alias AddCallout / AddNotice). SetTitle / SetContent / SetType."},
	{"Code", "S.AddCode{Title, Code, Copy = true}", "Monospace block with a Copy button. Set / Get / Copy."},
	{"ButtonRow", "S.AddButtonRow{Buttons = {{Name, Callback, Kind}, ...}, Callback(name, i)}", "Buttons side by side. GetButton / SetButtonText / SetButtonEnabled / Fire / SetButtons."},
	{"ConfirmButton", "S.AddConfirmButton{Name, ConfirmText, Timeout, Callback}", "Needs a second click to run. IsArmed / Cancel."},
	{"Link", "S.AddLink{Name, Url, Description}", "Copies a link and notifies. GetUrl / SetUrl."},
	{"Radio", "S.AddRadio{Name, Options, Default, AllowNone, Flag, Callback}", "Single choice list. Set / Get / SetOptions / AddOption / RemoveOption."},
	{"CheckboxGroup", "S.AddCheckboxGroup{Name, Options, Default = {...}, Flag, Callback(list)}", "Multiple choice list. SelectAll / Clear / ToggleOption / IsSelected / GetCount."},
	{"Checkbox", "S.AddCheckbox{Name, Default, Flag, Callback}", "Square checkbox toggle. Set / Get / Toggle."},
	{"Log", "S.AddLog{Name, Height, MaxLines, Timestamps, AutoScroll, CaptureOutput}", "Console (alias AddConsole). Log / Info / Success / Warn / Error / Debug / Clear / Export / Copy / GetLines / SetCaptureOutput."},
	{"List", "S.AddList{Name, Items, Height, Removable, Toggleable, Format, Flag, Callback(item), OnRemoved}", "Selectable list. SetItems / AddItem / RemoveItem / Clear / Filter / Select / Deselect."},
	{"Table", "S.AddTable{Columns, Rows, Widths, Align, EmptyText}", "Data grid. SetRows / AddRow / RemoveRow / SetCell / GetCell / SetColumns / SetDictionary / Clear."},
	{"Graph", "S.AddGraph{Name, Height, Points, Min, Max, Suffix, Decimals, Color, Track = fn, Interval}", "Live bar chart (alias AddChart). Push / Set / Clear / SetMax / Track(fn, interval) / GetAverage."},
	{"Timer", "S.AddTimer{Name, Duration, AutoStart, Loop, Countdown = true, OnFinish, OnTick}", "Countdown / stopwatch (AddCountdown, AddStopwatch). Start / Pause / Reset / Restart / AddTime / GetRemaining."},
	{"PlayerDropdown", "S.AddPlayerDropdown{Name, Multi, ExcludeLocal, DisplayNames, Flag, Callback(name)}", "Auto-updating player list. GetPlayer / GetPlayers / RefreshPlayers."},
	{"TeamDropdown", "S.AddTeamDropdown{Name, Multi, Flag, Callback(name)}", "Auto-updating team list. GetTeam / GetTeams / RefreshTeams."},
	{"ColorPalette", "S.AddColorPalette{Name, Colors, Default, Flag, Callback(color)}", "Swatch picker. Set(color | hex | index) / Get / GetHex / SetColors."},
	{"Search", "S.AddSearch{Name, Placeholder, Targets = {sections}}", "Live fuzzy filter for section elements (alias AddSearchBox)."},
	{"Rating", "S.AddRating{Name, Max = 5, Default, Icon, Flag, Callback}", "Star rating. Set / Get / GetMax."},
	{"TextArea", "S.AddTextArea{Name, Placeholder, Default, Height, MaxLength, Finished, Flag, Callback}", "Multi-line input (alias AddMultilineInput). Set / Get / Clear / Focus / GetLines."},
	{"Chips", "S.AddChips{Name, Items, Removable, Callback(item)}", "Pill tags (alias AddTags). SetItems / AddItem / RemoveItem / Clear."},
}

-- Per-window helpers that need the internal window state W.
function X.Overlay(W, dim)
	local ov = Create("TextButton", {
		Name = "ZeninOverlay", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 60, Parent = W.Holder,
	})
	Corner(ov, 6)
	Tween(ov, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {BackgroundTransparency = dim or 0.45})
	return ov
end

function X.Card(W, parent, width)
	local card = Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width or 280, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BorderSizePixel = 0, Parent = parent,
	})
	Corner(card, 6)
	local st = Stroke(card, WHITE, 1)
	local sc = Create("UIScale", {Scale = 0.92, Parent = card})
	Create("UIPadding", {
		PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 11), PaddingBottom = UDim.new(0, 12), Parent = card,
	})
	Create("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = card})
	W.Bind(function(T)
		card.BackgroundColor3 = T.CardBg
		st.Color = T.DropdownBorder
	end, card)
	Tween(sc, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1})
	return card, sc
end

function X.Dialog(W, Window, o)
	o = type(o) == "string" and {Title = o} or (o or {})
	if not W.Visible then Window.Show(true) end
	W.ClosePopup()
	local result = X.Signal()
	local ov = X.Overlay(W)
	local card, sc = X.Card(W, ov, tonumber(o.Width) or 290)
	local head = Create("Frame", {Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, LayoutOrder = 1, Parent = card})
	local x = 0
	local ic
	if o.Icon ~= false then
		local _, tone, iconName = X.Tone(o.Type)
		ic = CreateIcon(head, o.Icon or (o.Type and iconName) or "message-circle", 14, UDim2.new(0, 0, 0.5, -7))
		W.Bind(function(_, accent) ic.ImageColor3 = o.Type and tone or accent end, ic)
		x = 20
	end
	local title = Label(head, o.Title or o.Name or W.Title, {Position = UDim2.fromOffset(x, 0), Size = UDim2.new(1, -x, 1, 0), Weight = "SemiBold", TextSize = 13, Truncate = true})
	local body
	if o.Content or o.Text or o.Description then
		body = Label(card, o.Content or o.Text or o.Description, {Size = UDim2.new(1, 0, 0, 0)})
		body.AutomaticSize = Enum.AutomaticSize.Y
		body.TextWrapped = true
		body.RichText = o.RichText == true
		body.LayoutOrder = 2
	end
	local input, ist
	local Press
	if o.Input then
		local io = type(o.Input) == "table" and o.Input or {}
		input = Create("TextBox", {
			Size = UDim2.new(1, 0, 0, 26), BorderSizePixel = 0, Text = tostring(io.Default or ""),
			PlaceholderText = tostring(io.Placeholder or ""), ClearTextOnFocus = false, TextSize = TEXT, Weight = "Medium",
			TextXAlignment = Enum.TextXAlignment.Left, ClipsDescendants = true, LayoutOrder = 3, Parent = card,
		})
		Corner(input, 4)
		ist = Stroke(input, WHITE, 1)
		Create("UIPadding", {PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = input})
		pcall(AttachKeyboard, input, W)
		input.Focused:Connect(function() ist.Color = W.Accent end)
		input.FocusLost:Connect(function(enter)
			ist.Color = W.Theme.DropdownBorder
			if enter and o.SubmitOnEnter ~= false then
				local def
				for _, b in ipairs(o.Buttons or {}) do if b.Default or b.Kind == "primary" then def = b end end
				if def then task.defer(function() Press(def) end) end
			end
		end)
	end
	W.Bind(function(T)
		title.TextColor3 = T.Text
		if body then body.TextColor3 = T.TextGray end
		if input then
			input.BackgroundColor3 = T.DropdownBg
			input.TextColor3 = T.Text
			input.PlaceholderColor3 = T.TextDim
			ist.Color = T.DropdownBorder
		end
	end, card)
	local bar = Create("Frame", {Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = 4, Parent = card})
	Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = bar,
	})
	local closed = false
	local handle = {Result = nil}
	local function Close(value)
		if closed then return end
		closed = true
		handle.Result = value
		Tween(sc, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0.92})
		local t = Tween(ov, TweenInfo.new(0.15, Enum.EasingStyle.Quad), {BackgroundTransparency = 1})
		card.Visible = false
		t.Completed:Connect(function() ov:Destroy() end)
		SafeCall(o.Callback, value, input and input.Text or nil)
		result.Fire(value, input and input.Text or nil)
		result.Destroy()
	end
	function Press(b)
		if closed then return end
		local text = input and input.Text or nil
		if b.Callback then
			local keep = SafeCall(b.Callback, text)
			if keep == false then return end
		end
		local value = b.Result
		if value == nil then value = b.Name or b.Text end
		if value == "__input" then value = text end
		Close(value)
	end
	local buttons = o.Buttons or {{Name = "OK", Result = true, Kind = "primary"}}
	for i, b in ipairs(buttons) do
		if type(b) == "string" then
			b = {Name = b}
			buttons[i] = b
		end
		X.Button(W, bar, b.Name or b.Text or "OK", {LayoutOrder = i, Kind = b.Kind or b.Style, Callback = function() Press(b) end})
	end
	if o.CloseOnOutside ~= false then
		ov.MouseButton1Click:Connect(function()
			if o.Dismissible == false then return end
			Close(o.DismissResult)
		end)
	end
	W.Maid:Give(function() if not closed then closed = true end end)
	Method(handle, "Close", Close)
	Method(handle, "SetTitle", function(t) title.Text = tostring(t) end)
	Method(handle, "SetContent", function(t) if body then body.Text = tostring(t) end end)
	Method(handle, "GetInput", function() return input and input.Text or nil end)
	Method(handle, "IsOpen", function() return not closed end)
	Method(handle, "Wait", function()
		if closed then return handle.Result end
		return result.Wait()
	end)
	if input then task.defer(function() pcall(function() input:CaptureFocus() end) end) end
	return handle
end

function X.Loading(W, Window, o)
	o = type(o) == "string" and {Text = o} or (o or {})
	if not W.Visible then Window.Show(true) end
	local ov = X.Overlay(W, o.Dim or 0.35)
	local card, sc = X.Card(W, ov, tonumber(o.Width) or 230)
	local head = Create("Frame", {Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, LayoutOrder = 1, Parent = card})
	local spin = CreateIcon(head, o.Icon or {"loader-circle", "loader", "refresh-cw"}, 14, UDim2.new(0, 0, 0.5, -7))
	local title = Label(head, o.Title or o.Text or "Loading...", {Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -20, 1, 0), Weight = "SemiBold", Truncate = true})
	local sub = Label(card, o.Content or o.Description or "", {Size = UDim2.new(1, 0, 0, 0), TextSize = 10})
	sub.AutomaticSize = Enum.AutomaticSize.Y
	sub.TextWrapped = true
	sub.LayoutOrder = 2
	sub.Visible = sub.Text ~= ""
	local track = Create("Frame", {Size = UDim2.new(1, 0, 0, 3), BorderSizePixel = 0, ClipsDescendants = true, LayoutOrder = 3, Parent = card})
	Corner(track, 2)
	local fill = Create("Frame", {Size = UDim2.fromScale(0.3, 1), BorderSizePixel = 0, Parent = track})
	Corner(fill, 2)
	W.Bind(function(T, accent, alpha)
		title.TextColor3 = T.Text
		sub.TextColor3 = T.TextGray
		spin.ImageColor3 = accent
		track.BackgroundColor3 = T.SliderTrack
		fill.BackgroundColor3 = accent
		fill.BackgroundTransparency = 1 - alpha
	end, card)
	local progress
	local closed = false
	local h = {}
	local conn = RunService.Heartbeat:Connect(function()
		spin.Rotation = (os.clock() * 360) % 360
		if progress == nil then
			local t = (os.clock() * 0.8) % 1
			fill.Position = UDim2.fromScale(t * 1.3 - 0.3, 0)
			fill.Size = UDim2.fromScale(0.3, 1)
		end
	end)
	W.Maid:Give(conn)
	local function Close()
		if closed then return end
		closed = true
		conn:Disconnect()
		Tween(sc, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0.92})
		local t = Tween(ov, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {BackgroundTransparency = 1})
		card.Visible = false
		t.Completed:Connect(function() ov:Destroy() end)
	end
	Method(h, "SetText", function(t) title.Text = tostring(t) end)
	h.SetTitle = h.SetText
	Method(h, "SetContent", function(t)
		sub.Text = tostring(t or "")
		sub.Visible = sub.Text ~= ""
	end)
	Method(h, "SetProgress", function(p)
		progress = tonumber(p)
		if progress then
			fill.Position = UDim2.new()
			Tween(fill, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {Size = UDim2.fromScale(math.clamp(progress, 0, 1), 1)})
		end
	end)
	Method(h, "GetProgress", function() return progress end)
	Method(h, "Close", Close)
	Method(h, "IsOpen", function() return not closed end)
	Method(h, "Finish", function(text, delay)
		h.SetProgress(1)
		if text then title.Text = tostring(text) end
		task.delay(tonumber(delay) or 0.6, Close)
	end)
	if o.Progress then h.SetProgress(o.Progress) end
	if tonumber(o.Duration) then task.delay(tonumber(o.Duration), Close) end
	return h
end

function X.IsInternal(W, el)
	if type(el.Flag) == "string" and el.Flag:sub(1, 7) == "__Zenin" then return true end
	for _, p in ipairs({W.SettingsPage, W.ConfigPage}) do
		if p and p.scroll and el.Row and el.Row:IsDescendantOf(p.scroll) then return true end
	end
	return false
end

function X.Match(W, el, f)
	if f == nil then return not X.IsInternal(W, el) end
	if type(f) == "function" then return f(el) == true end
	if type(f) == "string" then return el.Type == f and not X.IsInternal(W, el) end
	if not f.Internal and X.IsInternal(W, el) then return false end
	if f.Type and el.Type ~= f.Type then return false end
	if f.Tag and not (el.Tags and el.Tags[f.Tag]) then return false end
	if f.Flagged and not el.Flag then return false end
	if f.Section and el._section ~= f.Section then return false end
	if f.Name and X.Fuzzy(el.Name or "", f.Name) == 0 then return false end
	if f.Enabled ~= nil and el.Enabled ~= f.Enabled then return false end
	return true
end

function X.ExtendWindow(Window, W)
	local G = "Window methods"
	X.Win[W] = Window
	Window._ext = true
	local function D(name, sig, desc, fn)
		Method(Window, name, fn)
		if not X.WindowDocsDone then X.Doc(G, "Window." .. sig, desc) end
	end

	-- Notifications: typed shortcuts and Notify(title, content, duration).
	local baseNotify = Window.Notify
	D("Notify", "Notify(options | title, content?, duration?)", "Also {Type = \"success\" | \"warning\" | \"error\" | \"info\"}.", function(x, content, duration)
		if type(x) == "string" and content ~= nil then x = {Title = x, Content = content, Duration = duration} end
		if type(x) == "table" and x.Type then
			local kind, _, icon = X.Tone(x.Type)
			x.Icon = x.Icon or icon
			x.Title = x.Title or (kind:sub(1, 1):upper() .. kind:sub(2))
		end
		X.Emit("Notify", x, Window)
		return baseNotify(x)
	end)
	for _, kind in ipairs({"Success", "Info", "Warning", "Error"}) do
		D(kind, kind .. "(title | options, content?, duration?)", "Typed notification.", function(t, content, duration)
			local x = type(t) == "table" and X.Copy(t) or {Title = t, Content = content, Duration = duration}
			if type(t) == "string" and content == nil then x = {Title = kind, Content = t} end
			x.Type = kind
			return Window.Notify(x)
		end)
	end
	Window.Warn = Window.Warning

	-- Dialogs.
	D("Dialog", "Dialog{Title, Content, Icon, Type, Input = {Placeholder, Default}, Buttons = {{Name, Result, Kind, Callback}}, Callback(result, text), Width} -> Dialog",
		"Modal dialog. Dialog: Close(result) / Wait() / SetTitle / SetContent / GetInput / IsOpen. A button Callback returning false keeps it open.",
		function(o) return X.Dialog(W, Window, o) end)
	D("Confirm", "Confirm(title | options, content?, callback?) -> bool (yields without a callback)", "Yes / no dialog. Options: ConfirmText, CancelText, Danger.", function(t, content, cb)
		local o = type(t) == "table" and X.Copy(t) or {Title = t, Content = content}
		if type(content) == "function" then cb, o.Content = content, nil end
		o.Callback = cb or o.Callback
		o.Type = o.Type or (o.Danger and "warning" or nil)
		o.DismissResult = false
		o.Buttons = {
			{Name = o.CancelText or "Cancel", Result = false},
			{Name = o.ConfirmText or "Confirm", Result = true, Kind = o.Danger and "danger" or "primary", Default = true},
		}
		local d = X.Dialog(W, Window, o)
		if not o.Callback and coroutine.isyieldable() then return d.Wait() == true end
		return d
	end)
	D("Prompt", "Prompt(title | options, placeholder?, callback?) -> text? (yields without a callback)", "Text input dialog; nil when cancelled.", function(t, placeholder, cb)
		local o = type(t) == "table" and X.Copy(t) or {Title = t}
		if type(placeholder) == "function" then cb, placeholder = placeholder, nil end
		o.Input = o.Input or {Placeholder = placeholder or o.Placeholder, Default = o.Default}
		local user = cb or o.Callback
		o.Callback = user and function(v) if v == false then v = nil end user(v) end or nil
		o.Buttons = {
			{Name = o.CancelText or "Cancel", Result = false},
			{Name = o.SubmitText or "OK", Result = "__input", Kind = "primary", Default = true},
		}
		local d = X.Dialog(W, Window, o)
		if not user and coroutine.isyieldable() then
			local v = d.Wait()
			if v == false then return nil end
			return v
		end
		return d
	end)
	D("Alert", "Alert(title, content?, callback?)", "Information dialog with one OK button.", function(t, content, cb)
		local o = type(t) == "table" and X.Copy(t) or {Title = t, Content = content}
		o.Callback = cb or o.Callback
		o.Buttons = {{Name = o.ButtonText or "OK", Result = true, Kind = "primary", Default = true}}
		return X.Dialog(W, Window, o)
	end)
	D("Choose", "Choose(title, options, callback?) -> option? (yields without a callback)", "Dialog with one button per option.", function(t, opts, cb)
		local o = type(t) == "table" and X.Copy(t) or {Title = t}
		opts = opts or o.Options or {}
		o.Callback = cb or o.Callback
		o.Buttons = {}
		for i, v in ipairs(opts) do o.Buttons[i] = {Name = tostring(v), Result = v, Kind = i == #opts and "primary" or nil} end
		local d = X.Dialog(W, Window, o)
		if not o.Callback and coroutine.isyieldable() then return d.Wait() end
		return d
	end)
	D("Loading", "Loading(text | {Title, Content, Progress, Duration, Dim}) -> Loader", "Blocking overlay. Loader: SetText / SetContent / SetProgress(0..1 | nil) / Finish(text?, delay?) / Close / IsOpen.",
		function(o) return X.Loading(W, Window, o) end)
	local lockOverlay
	D("Lock", "Lock(reason?)", "Blocks the whole window with a message until Unlock().", function(reason)
		if lockOverlay and lockOverlay.IsOpen() then lockOverlay.SetText(reason or "Locked") return end
		lockOverlay = X.Loading(W, Window, {Title = reason or "Locked", Icon = "lock", Dim = 0.5})
		lockOverlay.SetProgress(0)
	end)
	D("Unlock", "Unlock()", "", function()
		if lockOverlay then lockOverlay.Close() lockOverlay = nil end
	end)
	D("IsLocked", "IsLocked() -> bool", "", function() return lockOverlay ~= nil and lockOverlay.IsOpen() end)

	-- Elements across the window. filter: nil | "Type" | fn(el) | {Type, Tag, Flagged, Section, Name, Enabled, Internal}
	local function List(f)
		local out = {}
		for _, el in ipairs(W.Elements) do
			if X.Match(W, el, f) then table.insert(out, el) end
		end
		return out
	end
	D("GetElements", "GetElements(filter?) -> {element}", "filter: \"Toggle\", fn(el), or {Type, Tag, Flagged, Section, Name, Enabled}.", List)
	D("GetElement", "GetElement(nameOrFlag) -> element?", "", function(ref)
		for _, el in ipairs(W.Elements) do
			if el.Flag == ref or el.Name == ref then return el end
		end
		return nil
	end)
	Window.FindElement = Window.GetElement
	D("GetElementsByTag", "GetElementsByTag(tag) -> {element}", "", function(tag) return List({Tag = tostring(tag)}) end)
	D("GetElementsByType", "GetElementsByType(type) -> {element}", "", function(t) return List({Type = t}) end)
	D("SearchElements", "SearchElements(query) -> {element}", "Fuzzy search by name, best first.", function(q)
		local scored = {}
		for _, el in ipairs(List()) do
			local sc = X.Fuzzy(el.Name or "", q)
			if sc > 0 then table.insert(scored, {el, sc}) end
		end
		table.sort(scored, function(a, b) return a[2] > b[2] end)
		for i, v in ipairs(scored) do scored[i] = v[1] end
		return scored
	end)
	D("ForEachElement", "ForEachElement(fn(el), filter?)", "", function(fn, f)
		for _, el in ipairs(List(f)) do SafeCall(fn, el) end
	end)
	D("SetElementsEnabled", "SetElementsEnabled(enabled, filter?)", "", function(b, f)
		for _, el in ipairs(List(f)) do el.SetEnabled(b) end
	end)
	D("LockElements", "LockElements(reason?, filter?)", "", function(reason, f)
		for _, el in ipairs(List(f)) do if el.Lock then el.Lock(reason) end end
	end)
	D("UnlockElements", "UnlockElements(filter?)", "", function(f)
		for _, el in ipairs(List(f)) do if el.Unlock then el.Unlock() end end
	end)
	D("ResetAll", "ResetAll()", "Every element back to its default (callbacks fire).", function() W.ResetElements() end)
	D("CountElements", "CountElements(filter?) -> number", "", function(f) return #List(f) end)

	-- Config as text.
	D("ExportConfig", "ExportConfig(pretty?) -> json", "Current config as a JSON string.", function(pretty) return X.Encode(Window.GetConfig(), pretty) end)
	D("ImportConfig", "ImportConfig(json) -> bool", "Applies a config from ExportConfig.", function(s)
		local data = type(s) == "table" and s or X.Decode(s)
		if type(data) ~= "table" then return false end
		local ok = pcall(Window.ApplyConfig, data)
		return ok
	end)
	D("CopyConfig", "CopyConfig() -> bool", "ExportConfig to the clipboard.", function() return X.Clipboard(Window.ExportConfig(false)) end)
	D("PasteConfig", "PasteConfig(callback?)", "Prompts for a config string and imports it.", function(cb)
		Window.Prompt({Title = "Import config", Placeholder = "Paste config JSON"}, function(text)
			if not text then return end
			local ok = Window.ImportConfig(text)
			if ok then Window.Success("Config imported") else Window.Error("Invalid config") end
			SafeCall(cb, ok)
		end)
	end)

	-- Lifetime-bound helpers (cleaned when the window is destroyed).
	D("Every", "Every(interval, fn(tick, loop), name?) -> Loop", "Loop owned by the window.", function(interval, fn, name)
		return X.NewLoop({Name = name or ("__win_" .. HttpService:GenerateGUID(false)), Interval = interval, Callback = fn}, W.Maid)
	end)
	Window.Loop = Window.Every
	D("OnHeartbeat", "OnHeartbeat(fn(dt)) -> Connection", "", function(fn) return W.Maid:Give(RunService.Heartbeat:Connect(function(dt) SafeCall(fn, dt) end)) end)
	D("OnRenderStep", "OnRenderStep(fn(dt)) -> Connection", "", function(fn) return W.Maid:Give(RunService.RenderStepped:Connect(function(dt) SafeCall(fn, dt) end)) end)
	D("Delay", "Delay(seconds, fn, ...) -> thread", "", function(t, fn, ...) return W.Maid:Delay(t, fn, ...) end)
	D("Spawn", "Spawn(fn, ...) -> thread", "", function(fn, ...) return W.Maid:Spawn(fn, ...) end)
	D("BindKey", "BindKey(key, fn, options?) -> Hotkey", "Hotkey removed with the window.", function(key, fn, o) return X.BindKey(key, fn, o, W.Maid) end)
	D("Emit", "Emit(event, ...)", "Fires a (custom) window event for Window.On listeners.", function(name, ...) W.Emit(W.EventName(name), ...) end)

	-- Visual effects.
	D("Shake", "Shake(intensity?, duration?)", "Shakes the window (wrong key, errors ...).", function(intensity, duration)
		if W._shaking then return end
		W._shaking = true
		local base = W.Holder.Position
		local px = tonumber(intensity) or 6
		local stop = os.clock() + (tonumber(duration) or 0.35)
		W.Maid:Spawn(function()
			while os.clock() < stop and W.Alive do
				W.Holder.Position = base + UDim2.fromOffset(math.random(-px, px), math.random(-px, px) / 2)
				task.wait(0.03)
			end
			if W.Alive then W.Holder.Position = base end
			W._shaking = false
		end)
	end)
	D("SetRainbowAccent", "SetRainbowAccent(enabled, speed?)", "Cycles the accent through the hue wheel.", function(b, speed)
		W.Maid.Rainbow = nil
		if b == false then return end
		speed = tonumber(speed) or 0.08
		local last = 0
		W.Maid.Rainbow = RunService.Heartbeat:Connect(function()
			local now = os.clock()
			if now - last < 0.1 then return end
			last = now
			W.SetAccent(Color3.fromHSV((now * speed) % 1, 0.62, 1), W.AccentAlpha)
		end)
	end)
	D("Flash", "Flash(color?, duration?)", "Brief accent flash over the window.", function(color, duration)
		local f = Create("Frame", {
			Size = UDim2.fromScale(1, 1), BackgroundColor3 = ToColor(color) or W.Accent, BackgroundTransparency = 0.8,
			BorderSizePixel = 0, ZIndex = 59, Active = false, Parent = W.Holder,
		})
		Corner(f, 6)
		local t = Tween(f, TweenInfo.new(tonumber(duration) or 0.5, Enum.EasingStyle.Quad), {BackgroundTransparency = 1})
		t.Completed:Connect(function() f:Destroy() end)
	end)

	-- Declarative builder.
	D("Build", "Build{Tabs = {{Name, Icon, Sections = {{Name, Side, Collapsible, Elements = {{Type, ...}}}}, SubTabs = {...}}}} -> refs",
		"Creates tabs, sections and elements from a table. refs = {Tabs, Sections, Elements} keyed by name / flag.", function(spec)
			local refs = {Tabs = {}, Sections = {}, Elements = {}}
			local function Sections(target, list)
				for _, so in ipairs(list or {}) do
					local S = target.AddSection(so)
					refs.Sections[so.Name or so.Title or (#refs.Sections + 1)] = S
					for _, el in ipairs(S.AddElements(so.Elements or so.Items or {})) do
						local key = el.Flag or el.Name
						if key then refs.Elements[key] = el end
					end
				end
			end
			for _, to in ipairs(spec.Tabs or {}) do
				local tab = Window.AddTab(to)
				refs.Tabs[to.Name or to.Title or (#refs.Tabs + 1)] = tab
				Sections(tab, to.Sections)
				for _, so in ipairs(to.SubTabs or to.Pages or {}) do
					local sub = tab.AddSubTab(so)
					refs.Tabs[(to.Name or "") .. "/" .. (so.Name or so.Title or "")] = sub
					Sections(sub, so.Sections)
				end
			end
			if spec.Notify then Window.Notify(spec.Notify) end
			return refs
		end)

	X.WindowDocsDone = true
	X.Emit("WindowCreated", Window)
end

-- Tab / sub-tab API: section helpers.
function X.ExtendTab(W, api)
	local sections = {}
	local add = api.AddSection
	Method(api, "AddSection", function(o)
		local S = add(o)
		table.insert(sections, S)
		return S
	end)
	api.Section, api.CreateSection = api.AddSection, api.AddSection
	Method(api, "AddLeftSection", function(o)
		o = X.Copy(Opts(o))
		o.Side = "Left"
		return api.AddSection(o)
	end)
	Method(api, "AddRightSection", function(o)
		o = X.Copy(Opts(o))
		o.Side = "Right"
		return api.AddSection(o)
	end)
	Method(api, "GetSections", function()
		local out = {}
		for _, S in ipairs(sections) do
			if S.Card and S.Card.Parent then table.insert(out, S) end
		end
		return out
	end)
	Method(api, "GetSection", function(name)
		for _, S in ipairs(api.GetSections()) do
			if S.Name == name or S.Title == name then return S end
		end
		return nil
	end)
	Method(api, "AddSections", function(list)
		local out = {}
		for _, so in ipairs(list or {}) do
			local S = api.AddSection(so)
			S.Name = so.Name or so.Title
			if so.Elements then S.AddElements(so.Elements) end
			table.insert(out, S)
		end
		return out
	end)
	Method(api, "GetElements", function()
		local out = {}
		for _, S in ipairs(api.GetSections()) do
			for _, el in ipairs(S.GetElements()) do table.insert(out, el) end
		end
		return out
	end)
end

function X.Install()
	-- Element base: every element gets the shared element API.
	local baseNewElement = NewElement
	NewElement = function(W, S, kind, o, height)
		local el, row = baseNewElement(W, S, kind, o, height)
		local ok, err = pcall(X.ExtendElement, W, S, el, row, o or {})
		if not ok then warn("[Zenin] element extension failed: " .. tostring(err)) end
		return el, row
	end
	-- Sections: new element constructors (also on settings panels).
	local NEW = {
		"Spacer", "Header", "Image", "Stat", "KeyValue", "Status", "Alert", "Callout", "Notice", "Code", "ButtonRow",
		"ConfirmButton", "Link", "Radio", "CheckboxGroup", "Checkbox", "Log", "Console", "List", "Table", "Graph",
		"Chart", "Timer", "Countdown", "Stopwatch", "PlayerDropdown", "TeamDropdown", "ColorPalette", "Search",
		"SearchBox", "Rating", "TextArea", "MultilineInput", "Chips", "Tags",
	}
	local baseElementApi = ElementApi
	ElementApi = function(W, S)
		baseElementApi(W, S)
		for _, k in ipairs(NEW) do
			local ctor = X.El[k]
			Method(S, "Add" .. k, function(x) return ctor(W, S, x) end)
			S["Create" .. k] = S["Add" .. k]
		end
		return S
	end
	local baseNewSection = NewSection
	NewSection = function(W, page, o)
		local S = baseNewSection(W, page, o)
		local so = Opts(o)
		S.Name = so.Name or so.Title
		local ok, err = pcall(X.ExtendSection, W, S, so)
		if not ok then warn("[Zenin] section extension failed: " .. tostring(err)) end
		return S
	end
	local baseAttach = AttachSections
	AttachSections = function(W, api, page)
		baseAttach(W, api, page)
		local ok, err = pcall(X.ExtendTab, W, api)
		if not ok then warn("[Zenin] tab extension failed: " .. tostring(err)) end
		return api
	end
	table.insert(Library._WindowHooks, function(Window, W)
		local ok, err = pcall(X.ExtendWindow, Window, W)
		if not ok then warn("[Zenin] window extension failed: " .. tostring(err)) end
	end)
	for _, d in ipairs(X.ElementDocs) do X.Doc("New elements", d[2], d[3]) end
	X.Doc("Tab methods", "Tab.AddLeftSection(o) / AddRightSection(o)", "Section on a fixed side.")
	X.Doc("Tab methods", "Tab.AddSections{{Name, Side, Elements = {...}}, ...} -> {Section}", "Several sections at once.")
	X.Doc("Tab methods", "Tab.GetSections() / GetSection(name) / GetElements()", "")
end

function X.BuildLibraryMirrors()
	local G = "Library shortcuts (active window)"
	local function Active() return Library.ActiveWindow end
	for _, name in ipairs({"Success", "Info", "Warning", "Error", "Dialog", "Confirm", "Prompt", "Alert", "Choose", "Loading"}) do
		X.Def(Library, G, name, "Library." .. name .. "(...)", "Window." .. name .. " on the active window.", function(...)
			local w = Active()
			if w and w[name] then return w[name](...) end
			return nil
		end)
	end
	Library.Warn = Library.Warning
	local baseNotify = Library.Notify
	Method(Library, "Notify", function(...)
		local w = Active()
		if w and w._ext then return w.Notify(...) end
		return baseNotify(...)
	end)
	X.Def(Library, G, "Build", "Library.Build{Window = {...CreateWindow options}, Tabs = {...}} -> Window, refs", "Window + Window.Build in one call.", function(spec)
		spec = spec or {}
		local w = Library.CreateWindow(spec.Window or spec.Options or {Title = spec.Title})
		return w, w.Build(spec)
	end)
	X.Def(Library, G, "GetElements", "Library.GetElements(filter?) -> {element}", "Elements of the active window.", function(f)
		local w = Active()
		return w and w.GetElements and w.GetElements(f) or {}
	end)

	-- Unload also stops loops, hotkeys and every extended-API connection.
	local baseUnload = Library.Unload
	Method(Library, "Unload", function()
		X.Emit("Unload")
		pcall(Library.StopAllLoops)
		pcall(Library.Hotkeys.Clear)
		X.Maid:Clean()
		return baseUnload()
	end)
	Library.Destroy = Library.Unload

	-- Help / introspection.
	X.Def(Library, "Help", "Help", "Library.Help(filter?) -> string", "Prints (and returns) every extended API entry, optionally filtered by text.", function(filter)
		filter = filter and tostring(filter):lower()
		local out = {"Zenin+ API v" .. Library.ApiVersion}
		for _, g in ipairs(X.Groups) do
			local lines = {}
			for _, d in ipairs(X.Docs[g]) do
				local line = "  " .. d.Signature .. ((d.Description ~= "" and ("  -- " .. d.Description)) or "")
				if not filter or line:lower():find(filter, 1, true) or g:lower():find(filter, 1, true) then table.insert(lines, line) end
			end
			if #lines > 0 then
				table.insert(out, "")
				table.insert(out, "[" .. g .. "]")
				for _, l in ipairs(lines) do table.insert(out, l) end
			end
		end
		local text = table.concat(out, "\n")
		print(text)
		return text
	end)
	X.Def(Library, "Help", "GetApi", "Library.GetApi() -> {group = {{Signature, Description}}}", "Structured docs.", function()
		local out = {}
		for g, list in pairs(X.Docs) do
			out[g] = {}
			for i, d in ipairs(list) do out[g][i] = {Signature = d.Signature, Description = d.Description} end
		end
		return out
	end)
	X.Def(Library, "Help", "CountApi", "Library.CountApi() -> number", "Number of documented entries.", function()
		local n = 0
		for _, list in pairs(X.Docs) do n = n + #list end
		return n
	end)
	Library.Api = {Version = Library.ApiVersion, Docs = X.Docs, Groups = X.Groups, Help = Library.Help}
end

X.BuildSignal()
X.BuildUtil()
X.BuildGame()
X.BuildScheduler()
X.BuildHotkeys()
X.BuildStorage()
X.BuildFlags()
X.BuildThemes()
X.Install()
X.BuildLibraryMirrors()
end -- extended API

return Library
