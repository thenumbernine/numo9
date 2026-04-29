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
UIWidget.tag = 'widget' 

function UIWidget:init(args)
	args = args or {}

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
	self.pos = args.pos and vec2d(args.pos) or vec2d()
	self.size = args.size and vec2d(args.size) or vec2d()
	-- screen-space pos and size
	self.ssbbox = box2d()

	self.children = table()
	self.childrenInOrder = table()

	--[[
	events:
		click = callback for triggering this button with click
			or enter or space when tabstop-focused
		focus = when you click (or tab to) a focusable (key-enter-able) widget ... only triggers for that widget, no bubble
		blur = when you click off of (or tab away from) a widget " " "
		focusin = " " " but bubbles
		focusout = " " " but bubbles
		mouseenter = when you move mouse over a widget
		mouseleave = when you move mouse away from a widget
		mouseover = " " but bubbles
		mouseout = " " but bubbles
		mousedown
		mouseup
		mousemove
		click
		input = textfield on any key change
		change = textfield on 'enter' or blur
		keyup, keydown = yup
	--]]
	self.eventListeners = {}
	if args.events then
		for k,v in pairs(args.events) do
			self:addEventListener(k, v)
		end
	end

	self.modelMatPush = matArrType()
end

function UIWidget:addEventListener(eventName, callback, bubbleIn)
	bubbleIn = not not bubbleIn
	self.eventListeners[eventName] = self.eventListeners[eventName] or {}
	self.eventListeners[eventName][bubbleIn] = self.eventListeners[eventName][bubbleIn] or table()
	self.eventListeners[eventName][bubbleIn]:insert(callback)
end

-- DO NOT directly children:insert
-- instead use this
function UIWidget:addChild(...)
	for i=1,select('#', ...) do
		local ch = select(i, ...)
		if ch.parent then
			ch.parent.children:removeObject(ch)
		end
		ch.parent = self
		ch.root = self.root
		self.children:insertUnique(ch)
	end
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

function UIWidget:drawRecurse(root)
	-- store for later (onClick etc)
	self.root = assert(root)

	local owner = self.owner
	local app = owner.app

	-- track widgets in drawn order
	-- used for mouseenter/mouseleave detection
	root.allWidgetsInOrder:insert(self)

	self.modelMatPush:copy(app.ram.modelMat)
	app:mattrans(self.pos.x, self.pos.y, -1, 0)

	-- store screen-space pixel positions based on current matrix transforms
	self.ssbbox.min.x, self.ssbbox.min.y = app:transform(0, 0, 0, 1)
	self.ssbbox.max.x, self.ssbbox.max.y = app:transform(self.size.x, self.size.y, 0, 1)

	local cx, cy, cw, ch = app:getClipRect()
	if self.overflow == 'hidden' then
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
	for i,ch in ipairs(self.childrenInOrder) do
		ch:drawRecurse(root)
	end

	app.ram.modelMat:copy(self.modelMatPush)
	app:onModelMatChange()

	app:setClipRect(cx, cy, cw, ch)
end

-- a lot like draw except without the successive matrix transformations
function UIWidget:update()
	local owner = self.owner
	local app = owner.app

	-- keep track of which tab index this component is
	self.menuTabIndex = owner.menuTabCounter
	owner.menuTabCounter = owner.menuTabCounter + 1

	for _,ch in ipairs(self.childrenInOrder) do
		ch:update()
	end

	if (self.isMouseOver or self.selfOrChildHasFocus)
	and self.tooltip
	then
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

function UIWidget:triggerEvents(eventName, bubbleIn, ...)
	local listenersForEvent = self.eventListeners[eventName]
	if not listenersForEvent then return end

	bubbleIn = not not bubbleIn
	local listenersForBubblePhaseForEvent = listenersForEvent[bubbleIn]
	if not listenersForBubblePhaseForEvent then return end

	for _,l in ipairs(listenersForBubblePhaseForEvent) do
		-- return-true to stop propagation
		if l(self, ...) then return true end
	end
end


-- why don't I just implement these as events themselves?
-- atm because browsers don't let you removeEventHandler the default , only on additional callbacks
-- but this owuldn't be the first bad DOM design, 
-- so TODO maybe I'll just replace all these with events directly...

-- doesn't bubble, is called directly by root
function UIWidget:onMouseEnter(...)
	self:triggerEvents('mouseenter', false, ...)
end

-- doesn't bubble
function UIWidget:onMouseLeave(...)
	self:triggerEvents('mouseleave', false, ...)
end

function UIWidget:onMouseOver_bubbleIn(...)
	self.isMouseOver = true
	self:triggerEvents('mouseover', true, ...)
end

function UIWidget:onMouseOver(...)
	self:triggerEvents('mouseover', false, ...)
end

function UIWidget:onMouseOut_bubbleIn(...)
	self.isMouseOver = false
	self:triggerEvents('mouseout', true, ...)
end

function UIWidget:onMouseOut(...)
	self:triggerEvents('mouseout', false, ...)
end

function UIWidget:onMouseDown_bubbleIn(...)
	if self.isMouseOver then
		self.mouseDownOnThis = true
	end
	self:triggerEvents('mousedown', true, ...)
end
	
function UIWidget:onMouseDown(...)
	self:triggerEvents('mousedown', false, ...)
end

function UIWidget:onMouseUp_bubbleIn(...)
	self:triggerEvents('mouseup', true, ...)
end

function UIWidget:onMouseUp(...)
	self:triggerEvents('mouseup', false, ...)
	-- TODO what if propagation gets stopped?  
	-- I should clear the ancestry every time widgetUnderMouse changes...
	self.mouseDownOnThis = nil
end

function UIWidget:onClick_bubbleIn(...)
	self:triggerEvents('click', true, ...)
end

function UIWidget:onClick(...)
	self:triggerEvents('click', false, ...)
end

function UIWidget:onMouseMove_bubbleIn(...)
	self:triggerEvents('mousemove', true, ...)
end
function UIWidget:onMouseMove(...)
	self:triggerEvents('mousemove', false, ...)
end

-- doesn't bubble
function UIWidget:onFocus(e)
	-- if you mouse over an event thens witch to its tab index...
	-- ... TODO only do this when you click?
	self.owner.menuTabIndex = self.menuTabIndex

	self:triggerEvents('focus', e)
end

-- doesn't bubble
function UIWidget:onBlur(e)
	self:triggerEvents('blur', e)
end

-- like focus/blur but does bubble
function UIWidget:onFocusIn_bubbleIn(...)
	self.selfOrChildHasFocus = true
	self:triggerEvents('focusin', true, ...)
end
function UIWidget:onFocusIn(...)
	self:triggerEvents('focusin', false, ...)
end

function UIWidget:onFocusOut_bubbleIn(...)
	self.selfOrChildHasFocus = false
	self:triggerEvents('focusout', true, ...)
end
function UIWidget:onFocusOut(...)
	self:triggerEvents('focusout', false, ...)
end

function UIWidget:onKeyDown_bubbleIn(...)
	self:triggerEvents('keydown', true, ...)
end
function UIWidget:onKeyDown(...)
	self:triggerEvents('keydown', false, ...)
end

function UIWidget:onKeyUp_bubbleIn(...)
	self:triggerEvents('keyup', true, ...)
end
function UIWidget:onKeyUp(...)
	self:triggerEvents('keyup', false, ...)
end

-- returns true if captured an event
function UIWidget:event(sdlEvent)
	-- ui events:
	for _,ch in ipairs(self.childrenInOrder) do
		if ch:event(sdlEvent) then return true end
	end
end

return UIWidget
