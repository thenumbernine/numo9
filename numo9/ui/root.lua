--[[
root-level, only should be one
--]]
local table = require 'ext.table'
local vec2d = require 'vec-ffi.vec2d'
local sdl = require 'sdl'

local numo9_rom = require 'numo9.rom'
local clipMax = numo9_rom.clipMax

local UIWidget = require 'numo9.ui.widget'
local UIEvent = require 'numo9.ui.event'


local UIRoot = UIWidget:subclass()
UIRoot.tag = 'root'	-- or should I call it 'body' or something more dom-like?

function UIRoot:init(args)
	UIRoot.super.init(self, args)

	-- extra for my mess of resize-realignment and tab-scroll-to-view(only in mainmenu)
	-- note that textarea also has .scroll
	self.scroll = vec2d()

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

-- hmm should I move all this into UI:event()?
function UIRoot:rootEvent(sdlEvent, handleUIEvent)
	local owner = self.owner
	local app = owner.app
	local event = UIEvent{
		sdl = sdlEvent,
	}

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

	--[[
	preventDefault() prevents default behavior, i.e.
	- stops tabbing
	it doesn't prevent propagation of bubbling of events
	so there is a line drawn between "default behavior" and "default events"
	--]]
	if not event.preventDefaultValue then

		--[[ is it just my controllers that register dpad as axis motion?
		-- or do they all?
		if (sdlEvent.type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN
			and sdlEvent.gbutton.button == sdl.SDL_GAMEPAD_BUTTON_DPAD_UP)
		--]]
		-- [[
		if (sdlEvent.type == sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION
			and sdlEvent.gaxis.axis == 1
			and sdlEvent.gaxis.value < -10000)
		--]]
		or (sdlEvent.type == sdl.SDL_EVENT_KEY_DOWN
		and sdlEvent.key.key == sdl.SDLK_UP)
		--or app:btnp'up'	-- should I use the user-configured up/down here too? meh?
		then
			owner.menuTabIndex = owner.menuTabIndex - 1
			if owner.menuTabCounter and owner.menuTabCounter > 0 then
				owner.menuTabIndex = owner.menuTabIndex % owner.menuTabCounter
			else
				owner.menuTabIndex = 0
			end
			local w = owner.widgetForTabIndex[owner.menuTabIndex]
			if w then owner.uiRoot:setFocusWidget(w) end
			return true
		end

		--[[
		if (sdlEvent.type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN
			and sdlEvent.gbutton.button == sdl.SDL_GAMEPAD_BUTTON_DPAD_DOWN)
		--]]
		-- [[
		if (sdlEvent.type == sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION
			and sdlEvent.gaxis.axis == 1
			and sdlEvent.gaxis.value > 10000)
		--]]
		or (sdlEvent.type == sdl.SDL_EVENT_KEY_DOWN
		and sdlEvent.key.key == sdl.SDLK_DOWN)
		then
			owner.menuTabIndex = owner.menuTabIndex + 1
			if owner.menuTabCounter and owner.menuTabCounter > 0 then
				owner.menuTabIndex = owner.menuTabIndex % owner.menuTabCounter
			else
				owner.menuTabIndex = 0
			end
			local w = owner.widgetForTabIndex[owner.menuTabIndex]
			if w then owner.uiRoot:setFocusWidget(w) end
			return true
		end

		-- I'm switching to a gui scenegraph
		-- so now tabbing is broken
		-- so convert everything to the gui scenegraph to fix it.
		-- [[
		-- TODO this is blocking 'return's in the text editors in the menu ...
		-- tempting to switch all ui controls over to :event()'s
		-- tempting to just use a tree based ui ... and give them event-capturing and bubble in and out and everything
		if (sdlEvent.type == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN and sdlEvent.gbutton.button == sdl.SDL_GAMEPAD_BUTTON_SOUTH)
		or (sdlEvent.type == sdl.SDL_EVENT_KEY_DOWN and sdlEvent.key.key == sdl.SDLK_RETURN)
		then
			local w = owner.widgetForTabIndex[owner.menuTabIndex]
			-- TODO some day this will need to be an event object like in UIRoot:rootEvent
			if w then w:onClick(UIEvent()) end
			return true
		end
		--]]

	end

	-- TODO check this more often?
	-- TODO TODO stopPropagation proly only cancels bubbling right?
	if event.stopPropagationValue then return end

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

	-- see if widget's screen-space is out of bounds
	-- if so, scroll parent so it is in bounds
	-- TODO consider scale?
	local viewPadding = 10
	local app = self.owner.app
	-- which to use ...
	local container = self	-- has .scroll
	--local container = widget.parent
	if widget.ssbbox.max.x < 0 then
		container.scroll.x = container.scroll.x + viewPadding - widget.ssbbox.max.x
	end
	if widget.ssbbox.max.y < 0 then
		container.scroll.y = container.scroll.y + viewPadding - widget.ssbbox.max.y
	end
	if widget.ssbbox.min.x >= app.width then
		container.scroll.x = container.scroll.x - widget.ssbbox.max.x - app.width + viewPadding
	end
	if widget.ssbbox.min.y >= app.height then
		container.scroll.y = container.scroll.y - widget.ssbbox.max.y - app.height + viewPadding
	end

	if self.activeElement then
		self:bubbleCallback(self.activeElement, 'onFocusIn_bubbleIn', 'onFocusIn', ...)
		self.activeElement:onFocus(...)
	end
end

return UIRoot
