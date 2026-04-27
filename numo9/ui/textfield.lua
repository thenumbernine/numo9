local assert = require 'ext.assert'
local getTime = require 'ext.timer'.getTime

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local menuFontWidth = numo9_rom.menuFontWidth

local numo9_keys = require 'numo9.keys'
local sdlSymToKeyCode = numo9_keys.sdlSymToKeyCode
local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode
local keyCodeForName = numo9_keys.keyCodeForName

local UIWidget = require 'numo9.ui.widget'


local UITextField = UIWidget:subclass()

function UITextField:init(args)
	UITextField.super.init(self, args)

	-- captured in parent but optional
	self.value = self.value or ''

	self.textFieldCursorLoc = #self.value

	-- max cols to display in text edit
	self.size.x = assert.index(args, 'width')
	self.size.y = spriteSize.y

	-- colors
	-- TODO standardize colors better
	self.fgDesel = args.fgDesel or 0xd
	self.bgDesel = args.bgDesel or 8
	self.fgSel = args.fgSel or 0xd
	self.bgSel = args.bgSel or 9
end

function UITextField:onKeyDown(e)
	local sdlkey = e.sdl.key.key

	-- if prevent default then bail, right?
	-- or should I use return status? like I did elsewhere?
	-- hmm...
	UITextField.super.onKeyDown(self, e)

	local keycode = sdlSymToKeyCode[sdlkey]
	if not keycode then return end

	local ch = getAsciiForKeyCode(keycode, shift)
	if not ch then return end

	-- TODO lots in common with editcode ... hmmm ...
	local app = self.owner.app
	local shift = app:key'lshift' or app:key'rshift'

	if keycode == keyCodeForName.backspace then
		self.value = self.value:sub(1, self.textFieldCursorLoc - 1) .. self.value:sub(self.textFieldCursorLoc+1)
		self.textFieldCursorLoc = math.max(0, self.textFieldCursorLoc - 1)

		if self.events.input then self.events.input(e, self) end
	elseif keycode == keyCodeForName['return'] then
		-- change is on 'commit', i.e. key 'enter' or blur
		if self.events.change then self.events.change(self, e) end
	elseif ch then
		self.value = self.value:sub(1, self.textFieldCursorLoc) .. string.char(ch) .. self.value:sub(self.textFieldCursorLoc+1)
		self.textFieldCursorLoc = math.min(#self.value, self.textFieldCursorLoc + 1)

		if self.events.input then self.events.input(self, e) end
	end
end

function UITextField:onFocus(e)
	UITextField.super.onFocus(self, e)

	-- ok when you click a textbox ...
	-- when does it set the text cursor position?
	-- i'm doing it here so focus can change the contents before i determine .value length
	self.textFieldCursorLoc = #self.value
end

function UITextField:onBlur(e)
	UITextField.super.onBlur(self, e)
	if self.events.change then self.events.change(self, e) end
end

function UITextField:draw(...)
	local owner = self.owner
	local app = owner.app

	UITextField.super.draw(self, ...)

	local fg, bg
	if self.isHovered or self:hasFocus() then
		fg, bg = self.fgSel, self.bgSel
	else
		fg, bg = self.fgDesel, self.bgDesel
	end

	app:drawSolidRect(
		0, 0,
		self.size.x, self.size.y,
		bg,
		false,	-- borderOnly
		false,	-- round
		app.paletteMenuTex)
	app:drawMenuText(self.value, 0, 0, fg, bg)

	if self:hasFocus()
	and getTime() % 1 < .5
	then
		app:drawSolidRect(
			self.textFieldCursorLoc * menuFontWidth,
			0,
			menuFontWidth,
			spriteSize.y,
			0xc,
			nil,
			nil,
			app.paletteMenuTex
		)
	end
end

return UITextField
