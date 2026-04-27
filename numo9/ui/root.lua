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

function UIRoot:init(args)
	UIRoot.super.init(self, args)

	self.allWidgetsInOrder = table()
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
	for _,ch in ipairs(self.childrenInOrder) do
		ch:drawRecurse(self)
	end
	app:setClipRect(0, 0, clipMax, clipMax)

	for _,ch in ipairs(self.childrenInOrder) do
		ch:update()
	end
end

function UIRoot:rootEvent(sdlEvent, handleUIEvent)
	local app = self.owner.app

	app:matMenuReset()	-- so mouse coord transforms work

	if sdlEvent.type == sdl.SDL_EVENT_MOUSE_MOTION then
		if self.widgetUnderMouse then
			self:bubbleCallback(self.widgetUnderMouse, 'onMouseMove', sdlEvent)
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
				self:bubbleCallback(self.widgetUnderMouse, 'onMouseOut', sdlEvent)

				-- put this in onMouseLeave?
				self.widgetUnderMouse.isHovered = nil
				self.widgetUnderMouse:onMouseLeave{
					sdl = sdlEvent,
				}
			end
			self.widgetUnderMouse = newWidgetUnderMouse
			if self.widgetUnderMouse then
				self:bubbleCallback(self.widgetUnderMouse, 'onMouseOver', sdlEvent)

				self.widgetUnderMouse.isHovered = true
				self.widgetUnderMouse:onMouseEnter{
					sdl = sdlEvent,
				}

				-- extra movement into the new event
				self:bubbleCallback(self.widgetUnderMouse, 'onMouseMove', sdlEvent)
			end
		end
	end

	if sdlEvent.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN then
		self:bubbleCallback(self.widgetUnderMouse, 'onMouseDown', sdlEvent)
	elseif sdlEvent.type == sdl.SDL_EVENT_MOUSE_BUTTON_UP then
		self:bubbleCallback(self.widgetUnderMouse, 'onMouseUp', sdlEvent)
	end

	-- old ui system...
	if handleUIEvent 
	and handleUIEvent(self, sdlEvent)
	then
		return true
	end

	-- ui events:
	for _,ch in ipairs(self.childrenInOrder) do
		if ch:event(sdlEvent) then return true end
	end
end

local UIWidget = require 'numo9.ui.widget'
function UIRoot:bubbleCallback(o, field, sdlEvent, ...)
	local event = {
		sdl = sdlEvent,
	}

	-- TODO bubble-in first

	while o ~= nil do
		if o[field](o, event, ...) then return true end
		-- propagate this to parents
		o = o.parent
	end
end

return UIRoot 
