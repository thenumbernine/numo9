-- slowly turning the GUI into a proper scenegraph...
local class = require 'ext.class'
local assert = require 'ext.assert'
local table = require 'ext.table'
local vec2d = require 'vec-ffi.vec2d'
local box2d = require 'vec-ffi.box2d'
local sdl = require 'sdl'


local numo9_rom = require 'numo9.rom'
local matArrType = numo9_rom.matArrType
local clipMax = numo9_rom.clipMax


local UIWidget = class()

UIWidget.zIndex = 0

function UIWidget:init(args)
	-- this is the root-level numo9/ui.lua component
	-- which currently holds things like tabindex
	-- TODO turn it into the root UI component
	self.owner = assert.index(args, 'owner')

	-- common in lots of child clases, but not required
	self.text = args.text	-- for labels, buttons, etc
	self.value = args.value	-- for input values
	self.fgColorIndex = args.fgColorIndex
	self.bgColorIndex = args.bgColorIndex

	self.tooltip = args.tooltip

	-- menu-space pos and size
	self.pos = vec2d((assert.index(args, 'pos')))
	self.size = args.size and vec2d(args.size) or vec2d()
	-- screen-space pos and size
	self.ssbbox = box2d()

	self.children = table()
	self.childrenInOrder = table()

	--[[
	events:
		click = callback for triggering this button with click
			or enter or space when tabstop-focused
		focus = when you click (or tab to) a widget
		blur = when you click off of (or tab away from) a widget
		mouseenter = when you move mouse over a widget
		mouseleave = when you move mouse away from a widget
		input = textfield on any key change
		change = textfield on 'enter' or blur
		keyup, keydown = yup
	--]]
	self.events = table(args.events):setmetatable(nil)

	self.modelMatPush = matArrType()
end

function UIWidget:event(e) end

function UIWidget:draw()
	local owner = self.owner
	local app = owner.app
	
	-- draw background
	app:drawSolidRect(0, 0, self.size.x, self.size.y, 0xf, nil, nil, app.paletteMenuTex)
	
	-- draw border
	app:drawBorderRect(0, 0, self.size.x-1, self.size.y-1, 0xc, nil, app.paletteMenuTex)
end

function UIWidget:drawRecurse(dz)
	dz = dz or 0
	local owner = self.owner
	local app = owner.app

	-- keep track of which tab index this component is
	self.menuTabIndex = owner.menuTabCounter
	owner.menuTabCounter = owner.menuTabCounter + 1

	self.modelMatPush:copy(app.ram.modelMat)
	app:mattrans(self.pos.x, self.pos.y, dz, 0)

	-- store screen-space pixel positions based on current matrix transforms
	self.ssbbox.min.x, self.ssbbox.min.y = app:transform(0, 0, 0, 1)
	self.ssbbox.max.x, self.ssbbox.max.y = app:transform(self.size.x, self.size.y, 0, 1)

	local cx, cy, cw, ch = app:getClipRect()
	do
		--[[ set clip rect
		owner:guiSetClipRect(0, 0, self.size.x, self.size.y)
		--]]
		-- [[ reduce
		local oldx1, oldy1, oldw, oldh = app:getClipRect() 
		local oldx2 = oldx1 + oldw
		local oldy2 = oldy1 + oldh

		local sx1, sy1 = app:transform(0, 0)
		local sx2, sy2 = app:transform(self.size.x, self.size.y)
		-- flip y
		sy1, sy2 =
			app.ram.screenHeight - 1 - sy2,
			app.ram.screenHeight - 1 - sy1

		sx1 = math.max(sx1, oldx1)
		sy1 = math.max(sy1, oldy1)
		sx2 = math.min(sx2, oldx2)
		sy2 = math.min(sy2, oldy2)

		app:setClipRect(sx1, sy1, sx2 - sx1, sy2 - sy1)	
		--]]
	end

	self:draw()

	for i,ch in ipairs(self.children) do
		self.childrenInOrder[i] = ch
	end
	for i=#self.children+1,#self.childrenInOrder do
		self.childrenInOrder[i] = nil
	end
	self.childrenInOrder:sort(function(a,b)
		return a.zIndex < b.zIndex
	end)

	-- TODO how to get widgets with higher zIndex to draw over other widgets 
	local dz = 0
	local lastZ = 0
	for i,ch in ipairs(self.childrenInOrder) do
		dz = ch.zIndex - lastZ
		ch:drawRecurse(dz)
	end

	app.ram.modelMat:copy(self.modelMatPush)
	app:onModelMatChange()
	
	app:setClipRect(cx, cy, cw, ch)
end

-- a lot like draw except without the successive matrix transformations
function UIWidget:update()
	for _,ch in ipairs(self.childrenInOrder) do
		ch:update()
	end

	if (self.isHovered or self:hasFocus())
	and self.tooltip
	then
		local owner = self.owner
		local app = owner.app
		-- ram mousePos is relative to matMenuReset()'s matrices
		-- this will be the root-level modelMatPush
		-- so handle this outside of draw
		-- ... or pass mousePos down through draw and constantly inverse-apply matrix transforms to it it as you go ...
		local mousePixelX, mousePixelY = app.ram.mousePos:unpack()
		local mouseX, mouseY = app:invTransform(mousePixelX, mousePixelY)

		local tooltip
		if type(self.tooltip) == 'string' then
			tooltip = self.tooltip
		elseif type(self.tooltip) == 'function' then
			tooltip = self:tooltip()
		elseif tooltip ~= nil then
			error("idk how to handle tooltip")
		end

		owner:setTooltip(tooltip, mouseX - 12, mouseY - 12, 12, 6)
	end
end

function UIWidget:hasFocus()
	if self.owner.activeElement == self then return true end
	for _,ch in ipairs(self.childrenInOrder) do
		if ch:hasFocus() then return true end
	end
	return false
end

function UIWidget:onMouseEnter(e)
	if self.events.mouseenter then self.events.mouseenter(self, e) end
end

function UIWidget:onMouseLeave(e)
	if self.events.mouseleave then self.events.mouseleave(self, e) end
end

function UIWidget:onFocus(e)
	-- if you mouse over an event thens witch to its tab index...
	-- ... TODO only do this when you click?
	self.owner.menuTabIndex = self.menuTabIndex

	if self.events.focus then self.events.focus(self, e) end
end

function UIWidget:onBlur(e)
	if self.events.blur then self.events.blur(self, e) end
end

function UIWidget:onClick(e)
	self.owner:setFocusWidget(self, e)

	if self.events.click then
		self.events.click(self, e)

		-- hmm return true always?
		-- only if events.click returns true?
		-- always unless events.click returns false?
		return true
	end
end

function UIWidget:onKeyDown(e)
	if self.events.keydown then self.events.keydown(self, e) end
end

function UIWidget:onKeyUp(e)
	if self.events.keyup then self.events.keyup(self, e) end
end

-- returns true if captured an event
function UIWidget:event(e)
	local didCapture

	-- ui events:
	for _,ch in ipairs(self.childrenInOrder) do
		if ch:event(e) then return true end
	end

	-- TODO this in widget
	if e.type == sdl.SDL_EVENT_MOUSE_MOTION then
		local mx, my = e.motion.x, e.motion.y

		local oldIsHovered = self.isHovered
		self.isHovered = self.ssbbox:contains(vec2d(mx, my))
		if self.isHovered and not oldIsHovered then
			self:onMouseEnter(e)
		elseif not self.isHovered and oldIsHovered then
			self:onMouseLeave(e)
		end

		--[[ when to not capture?
		if self.isHovered then
			didCapture = true
		end
		--]]
	elseif e.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN then
		if self.isHovered then
			self.mouseDownOnThis = true
		end
	
		-- [[ when to not capture?
		if self.isHovered then
			didCapture = true
		end
		--]]
	elseif e.type == sdl.SDL_EVENT_MOUSE_BUTTON_UP then
		if self.isHovered
		and self.mouseDownOnThis
		then
			didCapture = self:onClick()
		end
		
		self.mouseDownOnThis = nil
	
		-- [[ when to not capture?
		if self.isHovered then
			didCapture = true
		end
		--]]
	elseif e.type == sdl.SDL_EVENT_KEY_DOWN then
		if self:hasFocus() then
			self:onKeyDown(e)
		end
	elseif e.type == sdl.SDL_EVENT_KEY_UP then
		if self:hasFocus() then
			self:onKeyUp(e)
		end
	end

	return didCapture
end

return UIWidget
