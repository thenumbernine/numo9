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
	local app = self.owner.app

	app:matMenuReset()

	for i,ch in ipairs(self.children) do
		self.childrenInOrder[i] = ch
	end
	for i=#self.children+1,#self.childrenInOrder do
		self.childrenInOrder[i] = nil
	end
	self.childrenInOrder:sort(function(a,b)
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

	self:update()
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
