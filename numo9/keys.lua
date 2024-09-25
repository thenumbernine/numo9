-- keycode stuff
local ffi = require 'ffi'
local sdl = require 'sdl'
local table = require 'ext.table'
local asserteq = require 'ext.assert'.eq

-- key code list, 1-baesd, sequential
local keyCodeNames = table{
	'a',
	'b',
	'c',
	'd',
	'e',
	'f',
	'g',
	'h',
	'i',
	'j',
	'k',
	'l',
	'm',
	'n',
	'o',
	'p',
	'q',
	'r',
	's',
	't',
	'u',
	'v',
	'w',
	'x',
	'y',
	'z',
	'0',
	'1',
	'2',
	'3',
	'4',
	'5',
	'6',
	'7',
	'8',
	'9',
	'minus',			-- -
	'equals',			-- =
	'leftbracket',		-- [
	'rightbracket',		-- ]
	'backslash',		-- \
	'semicolon',		-- ;
	'quote',			-- '
	'backquote',		-- `
	'comma',			-- ,
	'period',			-- .
	'slash',			-- /
	'space',
	'tab',
	'return',
	'backspace',

	'up',
	'down',
	'left',
	'right',
	'capslock',
	'lctrl',
	'rctrl',
	'lshift',
	'rshift',
	'lalt',
	'ralt',
	'lgui',
	'rgui',

	'delete',
	'insert',
	'pageup',
	'pagedown',
	'home',
	'end',
}
-- keypad too...
-- NOTICE these would be virtual, and wouldn't map to the SDLK_whatever like everything above this line does
-- so let's keep track of the keyboard ending ...
local lastKeyboardKeyCode = #keyCodeNames
--print('lastKeyboardKeyCode', lastKeyboardKeyCode)
-- TODO instead of doing this, do handlers like in gamepad/sand-attack
keyCodeNames:append{
	'padding0',
	'padding1',
}
asserteq(#keyCodeNames % 8, 0)

local firstJoypadKeyCode = #keyCodeNames

keyCodeNames:append{
	-- joypad 0 thru 3
	-- buttons: up down left right a b x y
	'jp0_up',
	'jp0_down',
	'jp0_left',
	'jp0_right',
	'jp0_a',
	'jp0_b',
	'jp0_x',
	'jp0_y',
	'jp1_up',
	'jp1_down',
	'jp1_left',
	'jp1_right',
	'jp1_a',
	'jp1_b',
	'jp1_x',
	'jp1_y',
	'jp2_up',
	'jp2_down',
	'jp2_left',
	'jp2_right',
	'jp2_a',
	'jp2_b',
	'jp2_x',
	'jp2_y',
	'jp3_up',
	'jp3_down',
	'jp3_left',
	'jp3_right',
	'jp3_a',
	'jp3_b',
	'jp3_x',
	'jp3_y',

	'mouse_left',
	'mouse_middle',
	'mouse_right',
}

--DEBUG:print'keyCodeNames'
--DEBUG:print(require'ext.tolua'(keyCodeNames))

--[[ print out the table for the readme
local colsize = 4 + keyCodeNames:mapi(function(name) return #name end):sup()
for keyCodePlusOne,name in ipairs(keyCodeNames) do
	local title = name..'='..(keyCodePlusOne-1)
	io.write('|'..title..(' '):rep(colsize-#title))
	if keyCodePlusOne % 8 == 0 then print'|' end
end
if #keyCodeNames % 8 ~= 0 then print() end
--]]

-- map from the keycode name to its 0-based index
local keyCodeForName = keyCodeNames:mapi(function(name, indexPlusOne)
	return indexPlusOne-1, name
end):setmetatable(nil)
--DEBUG:print'keyCodeForName'
--DEBUG:print(require'ext.tolua'(keyCodeForName))

-- map from sdl keycode value to our keycode value
--[[ not working
local sdlSymToKeyCode = keyCodeNames:mapi(function(name, indexPlusOne)
--]]
-- [[
local sdlSymToKeyCode = {}
for indexPlusOne, name in ipairs(keyCodeNames) do
--]]
	--if indexPlusOne > lastKeyboardKeyCode then return end
	if #name > 1 then name = name:upper() end	-- weird SDLK_ naming convention
	local sdlkey = 'SDLK_'..name
	--local sdlsym = sdl[sdlkey]
	local sdlsym = require 'ext.op'.safeindex(sdl, sdlkey)
	if not sdlsym then
--DEBUG:print('...failed to get sdlsym for '..sdlkey)
	else
--DEBUG:print('mapping from sdlsym '..sdlsym..' to index '..(indexPlusOne-1)..' for name '..name)
--[[ not working
		return indexPlusOne-1, tonumber(sdlsym)
end):setmetatable(nil)
--]]
-- [[
		sdlSymToKeyCode[tonumber(sdlsym)] = indexPlusOne-1
	end
end
--]]
--DEBUG:print'sdlSymToKeyCode'
--DEBUG:print(require'ext.tolua'(sdlSymToKeyCode))

local keyCodeNameToAscii = {
	a = ('a'):byte(),
	b = ('b'):byte(),
	c = ('c'):byte(),
	d = ('d'):byte(),
	e = ('e'):byte(),
	f = ('f'):byte(),
	g = ('g'):byte(),
	h = ('h'):byte(),
	i = ('i'):byte(),
	j = ('j'):byte(),
	k = ('k'):byte(),
	l = ('l'):byte(),
	m = ('m'):byte(),
	n = ('n'):byte(),
	o = ('o'):byte(),
	p = ('p'):byte(),
	q = ('q'):byte(),
	r = ('r'):byte(),
	s = ('s'):byte(),
	t = ('t'):byte(),
	u = ('u'):byte(),
	v = ('v'):byte(),
	w = ('w'):byte(),
	x = ('x'):byte(),
	y = ('y'):byte(),
	z = ('z'):byte(),
	['0'] = ('0'):byte(),
	['1'] = ('1'):byte(),
	['2'] = ('2'):byte(),
	['3'] = ('3'):byte(),
	['4'] = ('4'):byte(),
	['5'] = ('5'):byte(),
	['6'] = ('6'):byte(),
	['7'] = ('7'):byte(),
	['8'] = ('8'):byte(),
	['9'] = ('9'):byte(),
	minus = ('-'):byte(),
	equals = ('='):byte(),
	leftbracket = ('['):byte(),
	rightbracket = (']'):byte(),
	backslash = ('\\'):byte(),
	semicolon = (';'):byte(),
	quote = ("'"):byte(),
	backquote = ('`'):byte(),
	comma = (','):byte(),
	period = ('.'):byte(),
	slash = ('/'):byte(),
	space = (' '):byte(),
	tab = ('\t'):byte(),
	['return'] = ('\r'):byte(),	-- idk why I picked 13 as my ascii associated
	backspace = 8,
}

local keyCodeToAscii = keyCodeNames:mapi(function(name, keyCodePlusOne)
	return keyCodeNameToAscii[name], keyCodePlusOne-1
end):setmetatable(nil)

-- maps sdlk to shifted ascii
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
	[(','):byte()] = ('<'):byte(),
	[('.'):byte()] = ('>'):byte(),
	[('/'):byte()] = ('?'):byte(),
}

local function getAsciiForKeyCode(keyCode, shift)
	local ascii = keyCodeToAscii[keyCode]
	if ascii
	and ascii >= ('a'):byte()
	and ascii <= ('z'):byte()
	then
		if shift then
			ascii = ascii - 32
		end
		return ascii
	-- keys to add to buffers
	elseif ascii == 8 -- backspace
	or ascii == 10 	-- newline
	or ascii == 9	-- tab
	or ascii == 32	-- space
	then
		return ascii
	elseif ascii then
		local shiftAscii = shiftFor[ascii]
		if shiftAscii then
			return shift and shiftAscii or ascii
		end
	end
	-- return nil = not a char-producing key
	-- keys like esc shift ctrl alt gui
end

local buttonCodeForName = {
	up = 0,
	down = 1,
	left = 2,
	right = 3,
	a = 4,
	b = 5,
	x = 6,
	y = 7,
}

-- TODO make this configurable
-- let's use tic80's standard for button codes
-- but ofc I gotta tweak it to my own mapping
-- https://gamefaqs.gamespot.com/snes/916396-super-nintendo/faqs/5395
-- fun fact, SNES's keys in-order are:
-- B Y Sel Start Up Down Left Right A X L R
local keyCodeForButtonIndex = {
	-- player 1
	[0] = keyCodeForName.up,		-- UP
	[1] = keyCodeForName.down,		-- DOWN
	[2] = keyCodeForName.left,		-- LEFT
	[3] = keyCodeForName.right,		-- RIGHT
	[4] = keyCodeForName.s,			-- A
	[5] = keyCodeForName.x,			-- B
	[6] = keyCodeForName.a,			-- X
	[7] = keyCodeForName.z,			-- Y
	-- TODO player 2 player 3 player 4 ...
	-- L R? start select?  or nah? or just one global menu button?
}
local buttonIndexForKeyCode = table.map(keyCodeForButtonIndex, function(keyCode, buttonIndex)
	return buttonIndex, keyCode
end):setmetatable(nil)

return {
	keyCodeNames = keyCodeNames,
	keyCodeForName = keyCodeForName,
	sdlSymToKeyCode = sdlSymToKeyCode,
	getAsciiForKeyCode = getAsciiForKeyCode,
	firstJoypadKeyCode = firstJoypadKeyCode,
	buttonCodeForName = buttonCodeForName,
	keyCodeForButtonIndex = keyCodeForButtonIndex,
	buttonIndexForKeyCode = buttonIndexForKeyCode,
}
