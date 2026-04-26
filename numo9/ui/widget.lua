-- slowly turning the GUI into a proper scenegraph...
local class = require 'ext.class'
local assert = require 'ext.assert'
local table = require 'ext.table'
local vec2d = require 'vec-ffi.vec2d'
local box2d = require 'vec-ffi.box2d'
local sdl = require 'sdl'


local UIWidget = class()

function UIWidget:init(args)
	-- this is the root-level numo9/ui.lua component
	-- which currently holds things like tabindex
	-- TODO turn it into the root UI component
	self.owner = assert.index(args, 'owner')

	-- menu-space pos and size
	self.pos = vec2d((assert.index(args, 'pos')))
	self.size = args.size and vec2d(args.size) or vec2d()
	-- screen-space pos and size
	self.ssbbox = box2d()

	self.children = table()

	--[[
	events:
		click
			callback for triggering this button with click 
			or enter or space when tabstop-focused
		focus
		blur
	--]]
	self.events = table(args.events):setmetatable(nil)
end

function UIWidget:event(e) end

function UIWidget:draw()
	local owner = self.owner
	local app = owner.app

	-- keep track of which tab index this component is
	self.menuTabIndex = owner.menuTabCounter
	owner.menuTabCounter = owner.menuTabCounter + 1

	-- keep track of tab-focus
	self.onThisMenuItem = owner.menuTabIndex == owner.menuTabCounter

	-- store screen-space pixel positions based on current matrix transforms
	self.ssbbox.min.x, self.ssbbox.min.y = app:transform(self.pos.x, self.pos.y, 0, 1)
	self.ssbbox.max.x, self.ssbbox.max.y = app:transform(self.pos.x + self.size.x, self.pos.y + self.size.y, 0, 1)
end

function UIWidget:onFocus(e)
	-- if you mouse over an event thens witch to its tab index...
	-- ... TODO only do this when you click?
	self.owner.menuTabIndex = self.menuTabIndex

	if self.events.focus then self.events.focus(self) end
end

function UIWidget:onBlur(e)
	if self.events.blur then self.events.blur(self) end
end

-- returns true if captured an event
function UIWidget:event(e)
	local didCapture

	-- TODO this in widget
	if e.type == sdl.SDL_EVENT_MOUSE_MOTION then
		local mx, my = e.motion.x, e.motion.y
		-- TODO separate box2d 'contains' functions for contains-numbers, contains-vec, contains-box ...
		local oldHasFocus = self.hasFocus
		self.hasFocus = self.ssbbox:contains(vec2d(mx, my)) 
		if self.hasFocus and not oldHasFocus then
			self:onFocus(e)
		elseif not self.hasFocus and oldHasFocus then
			self:onBlur(e)
		end
	end

	if e.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN then
		if self.hasFocus then
--DEBUG:print('press on widget', self)			
			self.mouseDownOnThis = true
		end
	elseif e.type == sdl.SDL_EVENT_MOUSE_BUTTON_UP then
		if self.hasFocus
		and self.mouseDownOnThis 
		then
--DEBUG:print('press and release on widget', self)			
			if self.events.click then
--DEBUG:print'...clicking'				
				self.events.click(self)
				didCapture = true
			end
		end
		self.mouseDownOnThis = nil
	end

	return didCapture
end

return UIWidget
