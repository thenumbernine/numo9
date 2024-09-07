local sdl = require 'sdl'
local class = require 'ext.class'

-- TODO make the editor a rom itself
-- TODO make roms that hold all the necessary stuff

local Editor = class()

function Editor:init(args)
	local app = assert(args.app)
	self.app = app

	-- TODO when you initialize the editor ...
	self.active = true
	app:clearScreen()
	app:print(app.title)
	app:write'> '
end

-- runs at 60hz
function Editor:update()
end

local shiftFor = {
	-- letters handled separate
	[('`'):byte()] = ('~'):byte(),
	[('1'):byte()] = ('!'):byte(),
	[('2'):byte()] = ('@'):byte(),
	[('3'):byte()] = ('#'):byte(),
	[('4'):byte()] = ('$'):byte(),
	[('5'):byte()] = ('%'):byte(),
	[('6'):byte()] = ('^'):byte(),
	[('7'):byte()] = ('&'):byte(),
	[('8'):byte()] = ('*'):byte(),
	[('9'):byte()] = ('('):byte(),
	[('0'):byte()] = (')'):byte(),
	[('-'):byte()] = ('_'):byte(),
	[('='):byte()] = ('+'):byte(),
	[('['):byte()] = ('{'):byte(),
	[(']'):byte()] = ('}'):byte(),
	[('\\'):byte()] = ('|'):byte(),
	[(';'):byte()] = (':'):byte(),
	[("'"):byte()] = ('"'):byte(),
	[(','):byte()] = (','):byte(),
	[('<'):byte()] = ('>'):byte(),
	[('/'):byte()] = ('?'):byte(),
}


-- TODO if 'editor' is a console then how to handle events in limited memory ...
-- keydown = xor test of key bits ... if i'm using a bitvector for the keyboard state ...
-- this all involves *another* set of key remappings which seems tedious ...
function Editor:event(e)
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
			if sym >= sdl.SDLK_a and sym <= sdl.SDLK_z then
				if shift then
					sym = sym - 32
				end
				app:addCharToCmd(sym)
			-- add with non-standard shift capitalizing
			elseif sym >= sdl.SDLK_0 and sym <= sdl.SDLK_9
			or sym == sdl.SDLK_BACKQUOTE
			or sym == sdl.SDLK_MINUS
			or sym == sdl.SDLK_EQUALS
			or sym == sdl.SDLK_LEFTBRACKET
			or sym == sdl.SDLK_RIGHTBRACKET
			or sym == sdl.SDLK_BACKSLASH
			or sym == sdl.SDLK_QUOTE
			or sym == sdl.SDLK_SEMICOLON
			or sym == sdl.SDLK_COMMA
			or sym == sdl.SDLK_PERIOD
			or sym == sdl.SDLK_SLASH
			then
				if shift then 
					sym = assert(shiftFor[sym])
				end
				app:addCharToCmd(sym)
			elseif sym == sdl.SDLK_SPACE
			or sym == sdl.SDLK_BACKSPACE 
			then
				app:addCharToCmd(sym)
			elseif sym == sdl.SDLK_RETURN then
				app:runCmd()
			end
		end
	end

end

return Editor
