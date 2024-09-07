--[[
This will be the code editor
--]]
local sdl = require 'sdl'
local class = require 'ext.class'

-- TODO make the editor a rom itself
-- TODO make roms that hold all the necessary stuff

local EditCode = class()

function EditCode:init(args)
	self.app = assert(args.app)
	self.text = [[
print'hi'
do return end
]]
	
	-- starting point of where to render text, preferrably at a newline or beginning
	self.start = 1
	self.cursorLoc = 1	-- TODO cursor xy? or just index offset?
end

function EditCode:update(t)
	local app = self.app
	app:clearScreen()
	app:drawText(0,0,'CESM code editor', 1)

	local cursorX, cursorY
	local i = self.start
	for y=1,app.spritesPerFrameBuffer.y-2 do
		local newline
		local j = self.text:find('\n', i, true) 
		if j then
			newline = true
			j = j - 1 
		else
			j = #self.text+1
		end
		app:drawText(
			app.spriteSize.x,
			y * app.spriteSize.y,
			self.text:sub(i, j),
			0
		)
		-- store cursor xy
		if i <= self.cursorLoc and self.cursorLoc <= j then
			cursorY = y
			cursorX = self.cursorLoc - i
		end
		i = j + 1
		if newline then i = i + 1 end	-- skip past newline
		if i > #self.text then break end
		y = y + 1
	end
	
	if cursorX and cursorY and t % 1 < .5 then
		app:drawSolidRect(
			(cursorX + 1) * app.spriteSize.x,
			cursorY * app.spriteSize.y,
			app.spriteSize.x,
			app.spriteSize.y,
			15)
	end
end

function EditCode:addCharToText(ch)
	if ch == 13 then ch = 10 end	-- store \n's instead of \r's
	if ch == 8 then
		self.text = self.text:sub(1, self.cursorLoc-1) .. self.text:sub(self.cursorLoc+1)
		self.cursorLoc = math.max(1, self.cursorLoc - 1)
	else
		self.text = self.text:sub(1, self.cursorLoc-1) .. string.char(ch) .. self.text:sub(self.cursorLoc)
		self.cursorLoc = math.min(#self.text+1, self.cursorLoc + 1)
	end
end

function EditCode:event(e)
	local app = self.app
	if e[0].type == sdl.SDL_KEYDOWN 
	or e[0].type == sdl.SDL_KEYUP
	then
		-- TODO store the press state of all as bitflags in 'ram' somewhere
		-- and let the 'cartridge' read/write it?
		-- and move this code into the 'console' 'cartridge' do the following?

		local press = e[0].type == sdl.SDL_KEYDOWN
		local keysym = e[0].key.keysym
		local sym = keysym.sym
		local mod = keysym.mod
		if press then
			local shift = bit.band(mod, sdl.SDLK_LSHIFT) ~= 0
			local charsym = app:getKeySymForShift(sym, shift)
			if charsym then
				self:addCharToText(charsym)	
			elseif sym == sdl.SDLK_RETURN then
				self:addCharToText(sym)	
			elseif sym == sdl.SDLK_UP then
				--self:selectHistory(-1)
			elseif sym == sdl.SDLK_DOWN then 
				--self:selectHistory(1)
			-- TODO left right to move the cursor
			elseif sym == sdl.SDLK_ESCAPE then
				app.runFocus = app.con
				app.con:reset()	-- or save the screen
			end
		end
	end
end

return EditCode
