--[[
root-level, only should be one
--]]
local table = require 'ext.table'
local vec2d = require 'vec-ffi.vec2d'
local sdl = require 'sdl'

local numo9_rom = require 'numo9.rom'
local clipMax = numo9_rom.clipMax

local UIWidget = require 'numo9.ui.widget'


local UIRoot = UIWidget:subclass()
UIRoot.tag = 'root'	-- or should I call it 'body' or something more dom-like?

function UIRoot:init(args)
	UIRoot.super.init(self, args)

	self.allWidgetsInOrder = table()

	-- who gets keyboard by default?
	-- javascript model, focused objects get keyboard
	-- or if nothing is in focus, then the root
	self:setFocusWidget(self)
end

function UIRoot:rootUpdateAndDraw()
	local owner = self.owner
	local app = owner.app

	app:matMenuReset()

	for i,ch in ipairs(self.children) do
		self.childrenInOrder[i] = ch

-- TODO this is going to become invalid very quickly
-- i'm only using it for sorting
-- and I want it for sorting for preserving original order for when zIndexes equal...
ch.childIndexInParent = i

	end
	for i=#self.children+1,#self.childrenInOrder do
		self.childrenInOrder[i] = nil
	end
	self.childrenInOrder:sort(function(a,b)
		if a.zIndex == b.zIndex then return a.childIndexInParent < b.childIndexInParent end
		return a.zIndex < b.zIndex
	end)
	for i=#self.allWidgetsInOrder,1,-1 do
		self.allWidgetsInOrder[i] = nil
	end

	-- ui draw:
	app:setClipRect(0, 0, clipMax, clipMax)

	self.modelMatPush:copy(app.ram.modelMat)
	app:mattrans(self.pos.x, self.pos.y, 0, 0)

	self.root = self

	for _,ch in ipairs(self.childrenInOrder) do
		ch:drawRecurse(self)
	end

	app.ram.modelMat:copy(self.modelMatPush)
	app:onModelMatChange()

	app:setClipRect(0, 0, clipMax, clipMax)
	app:matMenuReset()


	--[[
	hmm...
	if we mouseover then we want tooltip to appear...
	if we tab to a widget then we want its tooltip to appear ...
	... at least until we move the mouse again,
		then we want the mouse to take precedence ...
	maybe I need a 'tooltipWidget' field for owner, that is assigned upon mouseover / focus ...
	but I would need to only set it if it has a valid tooltip property ...

	if we had hovered over this then clear it
	also if we had changed tooltipSrc via tabindex then we'd want to clear it
	but we won't want to clear tooltipSrc if we had just assigned it via mousemove this update ...
	... hmm ...
	maybe we should just clear it every frame? or nah?

	focusin will trigger on setfocus with bubble
	 (but not on mouseover)
	--]]
	owner.tooltipSrc = nil

	self:update()

	local tooltipSrc = owner.tooltipSrc
	if tooltipSrc then
		-- ram mousePos is relative to matMenuReset()'s matrices
		-- this will be the root-level modelMatPush
		-- so handle this outside of draw
		-- ... or pass mousePos down through draw and constantly inverse-apply matrix transforms to it it as you go ...
		local mousePixelX, mousePixelY = app.ram.mousePos:unpack()
		local mouseX, mouseY = app:invTransform(mousePixelX, mousePixelY)

		local tooltip
		if type(tooltipSrc.tooltip) == 'string' then
			tooltip = tooltipSrc.tooltip
		elseif type(tooltipSrc.tooltip) == 'function' then
			tooltip = tooltipSrc:tooltip()
		elseif tooltip ~= nil then
			error("idk how to handle tooltip")
		end

		if tooltip then
			owner:setTooltip(tooltip, mouseX - 12, mouseY - 12, 12, 6)
		end
	end
end


--[[
this will call all hierarchy with a member functions
	args are (self, bubbleIn=true/bubbleOut=false, event-wrapping-sdlEvent, ...)
--]]
function UIRoot:bubbleCallback(o, fieldBubbleIn, fieldBubbleOut, ...)
	local ancestry = table()
	while o do
		ancestry:insert(1, o)
		o = o.parent
	end

	-- bubble-in
	for i,o in ipairs(ancestry) do
		local f = o[fieldBubbleIn]
		if f then
			-- return 'true' to stop propagation
			if f(o, ...) then return true end
		end
	end

	-- bubble-out
	for i=#ancestry,1,-1 do
		local o = ancestry[i]
		local f = o[fieldBubbleOut]
		if f then
			-- return 'true' to stop propagation
			if f(o, ...) then return true end
		end
	end
end



function UIRoot:rootEvent(sdlEvent, handleUIEvent)
	local app = self.owner.app
	local event = {sdl=sdlEvent}

	app:matMenuReset()	-- so mouse coord transforms work

	if sdlEvent.type == sdl.SDL_EVENT_MOUSE_MOTION then
		if self.widgetUnderMouse then
			self:bubbleCallback(self.widgetUnderMouse, 'onMouseMove_bubbleIn', 'onMouseMove', event)
		end

		local newWidgetUnderMouse
		local mx, my = sdlEvent.motion.x, sdlEvent.motion.y
		local mousepos = vec2d(mx, my)
		for i=#self.allWidgetsInOrder,1,-1 do
			local ch = self.allWidgetsInOrder[i]
			if ch.ssbbox:contains(mousepos) then
				newWidgetUnderMouse = ch
				break
			end
		end

		-- mouseenter and mouseleave do not bubble
		if newWidgetUnderMouse ~= self.widgetUnderMouse then
			if self.widgetUnderMouse then
				self:bubbleCallback(self.widgetUnderMouse, 'onMouseOut_bubbleIn', 'onMouseOut', event)

				-- put this in onMouseLeave?
				self.widgetUnderMouse.isHovered = nil
				self.widgetUnderMouse:onMouseLeave{
					sdl = sdlEvent,
				}
			end
			self.widgetUnderMouse = newWidgetUnderMouse
			if self.widgetUnderMouse then
				self:bubbleCallback(self.widgetUnderMouse, 'onMouseOver_bubbleIn', 'onMouseOver', event)

				self.widgetUnderMouse.isHovered = true
				self.widgetUnderMouse:onMouseEnter{
					sdl = sdlEvent,
				}

				-- extra movement into the new event
				self:bubbleCallback(self.widgetUnderMouse, 'onMouseMove_bubbleIn', 'onMouseMove', event)
			end
		end
	end

	if sdlEvent.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN then
		self:bubbleCallback(self.widgetUnderMouse, 'onMouseDown_bubbleIn', 'onMouseDown', event)
	elseif sdlEvent.type == sdl.SDL_EVENT_MOUSE_BUTTON_UP then

		if self.widgetUnderMouse
		and self.widgetUnderMouse.mouseDownOnThis
		then
			self:bubbleCallback(self.widgetUnderMouse, 'onClick_bubbleIn', 'onClick', event)

			-- focus doesn't bubble
			self:setFocusWidget(self.widgetUnderMouse, {sdl=sdlEvent})
		end

		-- clears .mouseDownOnThis
		self:bubbleCallback(self.widgetUnderMouse, 'onMouseUp_bubbleIn', 'onMouseUp', event)
	end

	if self.activeElement then
		if sdlEvent.type == sdl.SDL_EVENT_KEY_DOWN then
			self:bubbleCallback(self.activeElement, 'onKeyDown_bubbleIn', 'onKeyDown', event)
		elseif sdlEvent.type == sdl.SDL_EVENT_KEY_UP  then
			self:bubbleCallback(self.activeElement, 'onKeyUp_bubbleIn', 'onKeyUp', event)
		end
	end

	-- old ui system...
	if handleUIEvent
	and handleUIEvent(self, sdlEvent)
	then
		return true
	end

	-- ui events:
	return self:event(sdlEvent)
end

-- works with the new UI scenegraph:
-- should go in whatever root-level for the final ui design
function UIRoot:setFocusWidget(widget, ...)
	-- can you re-focus the same widget?
	if self.activeElement == widget then return end

	if self.activeElement then
		self:bubbleCallback(self.activeElement, 'onFocusOut_bubbleIn', 'onFocusOut', ...)
		self.activeElement:onBlur(...)
	end

	self.activeElement = widget

	if self.activeElement then
		self:bubbleCallback(self.activeElement, 'onFocusIn_bubbleIn', 'onFocusIn', ...)
		self.activeElement:onFocus(...)
	end
end


return UIRoot
