local math = require 'ext.math'
local asserttype = require 'ext.assert'.type
local assertindex = require 'ext.assert'.index
local getTime = require 'ext.timer'.getTime
local sdl = require 'sdl'

local numo9_rom = require 'numo9.rom'
local fontWidth = numo9_rom.fontWidth
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize

local numo9_keys = require 'numo9.keys'
local maxLocalPlayers = numo9_keys.maxLocalPlayers
local keyCodeNames = numo9_keys.keyCodeNames
local getAsciiForKeyCode = numo9_keys.getAsciiForKeyCode
local buttonNames = numo9_keys.buttonNames
local buttonSingleCharLabels = numo9_keys.buttonSingleCharLabels

-- it's not an editor, but I put the gui functions in numo9.editor, so ...
-- strraigthen this out, either rename numo9.editor to numo9.gui, or use the gui project, or put the functions somewhere else like app or video, idk...
local Editor = require 'numo9.editor'

local Menu = Editor:subclass()

Menu.currentMenu = 'main'

function Menu:open()
	self.isOpen = true
	self:setCurrentMenu'main'
end

function Menu:setCurrentMenu(name)
	self.currentMenu = name
	self.menuTabIndex = 0
	self.connectStatus = nil
end

Menu.ystep = 9
Menu.ysepstep = 7

-- the ':menu...' prefix on all my menu gui cmds is to separate them from the :gui ones that don't read/write the Menu class' cursorX/cursorY

function Menu:menuLabel(str)
	self.app:drawText(str, self.cursorX, self.cursorY, 0xf7, 0xf0)
	self.cursorY = self.cursorY + self.ystep
end

function Menu:menuSection(str)
	-- TODO show a section divider
	self.cursorY = self.cursorY + self.ysepstep
	self.app:drawText(str, self.cursorX+16, self.cursorY, 0xf7, 0xf0)
	self.cursorY = self.cursorY + self.ystep
end

Menu.cursorLoc = 0
function Menu:menuTextField(label, t, k)
	-- TODO here ... only if we have tab-focus ... read our input.
	-- TODO color by tab-focus or not
	-- TODO can i share any code with editcode.lua ?  or nah, too much for editing a single field?
	asserttype(assertindex(t, k), 'string')
	local app = self.app

	local onThisMenuItem = self.menuTabIndex == self.menuTabCounter
	if self.menuTabIndex ~= self.cursorMenuTabIndex then
		-- if we just switched to this tabitem then reset the cursor position
		self.cursorLoc = #t[k]
	end
	self.menuTabCounter = self.menuTabCounter + 1

	local fg, bg
	if onThisMenuItem then
		fg, bg = 0xfd, 0xf9
	else
		fg, bg = 0xfd, 0xf8
	end

	app:drawText(label, self.cursorX, self.cursorY, 0xf7, 0xf0)
	local editX = self.cursorX + 40
	app:drawText(t[k], editX, self.cursorY, fg, bg)

	-- TODO like some UIs, push enter to enable/disable editing? or nah
	if onThisMenuItem then
		if getTime() % 1 < .5 then
			app:drawSolidRect(
				editX + self.cursorLoc * fontWidth,
				self.cursorY,
				fontWidth,
				spriteSize.y,
				0xfc
			)
		end

		-- TODO lots in common with editcode ... hmmm ...
		local shift = app:key'lshift' or app:key'rshift'
		local function addCharToText(ch)
			if ch == 8 then
				t[k] = t[k]:sub(1, self.cursorLoc - 1) .. t[k]:sub(self.cursorLoc+1)
				self.cursorLoc = math.max(0, self.cursorLoc - 1)
			elseif ch then
				t[k] = t[k]:sub(1, self.cursorLoc) .. string.char(ch) .. t[k]:sub(self.cursorLoc+1)
				self.cursorLoc = math.min(#t[k], self.cursorLoc + 1)
			end
		end

		-- handle input here ...
		for keycode=0,#keyCodeNames-1 do
			if app:keyp(keycode,30,5) then
				local ch = getAsciiForKeyCode(keycode, shift)
				if ch then
					addCharToText(ch)
				end
			end
		end
	end

	self.cursorY = self.cursorY + self.ystep
end

function Menu:menuButton(str)
	local result = self:guiButton(str, self.cursorX, self.cursorY)
	self.cursorY = self.cursorY + self.ystep
	return result
end

function Menu:update()
	if not self.isOpen then return end
	local app = self.app

	-- init the tab-order for editor controls
	self:initMenuTabs()

	-- clear screen
	app:setBlendMode(3)
	app:drawSolidRect(0, 0, frameBufferSize.x, frameBufferSize.y, 0xf0)
	app:setBlendMode(0xff)

	-- init the menu cursor position
	self.cursorX = 80
	self.cursorY = 8

	-- draw our menu and handle ui input
	if self.currentMenu == 'multiplayer' then
		self:updateMenuMultiplayer()
	elseif self.currentMenu == 'input' then
		self:updateMenuInput()
	else	-- main and default
		self:updateMenuMain()
	end

	-- handle keyboard input / tab-index stuff
	-- TODO move this into all editors,since the tab-index stuff is in the gui functions that they all use anyways
	if not app.waitingForEvent then
		if app:keyp'up' then
			self.menuTabIndex = self.menuTabIndex - 1
		end
		if app:keyp'down' then
			self.menuTabIndex = self.menuTabIndex + 1
		end
		if app:keyp('return', 15, 2) then
			self.execMenuTab = true
		end
		if self.menuTabMax and self.menuTabMax > 0 then
			self.menuTabIndex = self.menuTabIndex % self.menuTabMax
		end
	end
end

function Menu:updateMenuMain()
	local app = self.app

	self:menuSection'NuMo9'

	self:menuSection'game'

	if self:menuButton'resume' then
		self.isOpen = false
		app.isPaused = false
		return
	end

	if self:menuButton'new game' then
		self.isOpen = false
		app:runROM()
		return
	end

	if self:menuButton'multiplayer' then
		self:setCurrentMenu'multiplayer'
		return
	end

	if self:menuButton'input' then
		self:setCurrentMenu'input'
	end

	-- configure
	self:menuSection'sound'

	app:drawText('volume', self.cursorX, self.cursorY, 0xf7, 0xf0)
	self:guiSpinner(self.cursorX + 32, self.cursorY, function(dx)
		app.cfg.volume = math.clamp(app.cfg.volume + 10 * dx, 0, 255)
	end, 'volume')	-- TODO where's the tooltip?
	app:drawText(tostring(app.cfg.volume), self.cursorX + 56, self.cursorY, 0xf7, 0xf0)
	self.cursorY = self.cursorY + self.ystep

	self:menuSection'system'

	if self:menuButton'to console' then
		self.isOpen = false
		app.con.isOpen = true
		return
	end

	if self:menuButton'to editor' then
		self.isOpen = false
		app.con.isOpen = false
		app:setEditor(app.server and app.editNet or app.editCode)
		return
	end

	if self:menuButton'quit' then
		app:requestExit()
		return
	end
end

function Menu:updateMenuMultiplayer()
	local app = self.app
	-- multiplayer ... TODO menu sub-screen

	self:menuSection'multiplayer'
	self.cursorY = self.cursorY + self.ysepstep

	if app.server then
		if self:menuButton'close server' then
			app:disconnect()
		end
	elseif app.remoteClient then
		if self:menuButton'disconnect' then
			app:disconnect()
		end
	else
		self:menuSection'connect'
		self:menuTextField('addr', app.cfg, 'lastConnectAddr')
		self:menuTextField('port', app.cfg, 'lastConnectPort')
		-- TODO so tempting to implement a sameline() function ...
		if self.connectStatus then
			app:drawText(self.connectStatus, self.cursorX+40, self.cursorY, 0xfc, 0xf0)
			-- TODO timeout? clear upon new menu? idk?
		end
		if self:menuButton'go' then
			local success, msg = app:connect(
				app.cfg.lastConnectAddr,
				app.cfg.lastConnectPort
			)
			if not success then
				self.connectStatus = msg
			else
				-- TODO report connection failed if it failed
				-- and go back to the game ...
				self.isOpen = false
				app.isPaused = false
				return
			end
		end

		self:menuSection'listen'
		self:menuTextField('addr', app.cfg, 'serverListenAddr')
		self:menuTextField('port', app.cfg, 'serverListenPort')
		if self:menuButton'go' then
			app:listen()
			-- if we're listening then ... close the menu I guess
			self.isOpen = false
			app.isPaused = false
			return
		end
	end

	self:menuSection'player names'

	for i=1,maxLocalPlayers do
		-- TODO checkbox for whether the player is active or not during netplay ...
		-- TODO TODO how to allow #-local-players-active to change during a game ...
		self:menuTextField('name', app.cfg.playerInfos[i], 'name')
	end

	self.cursorY = self.cursorY + self.ysepstep
	if self:menuButton'back' then
		self:setCurrentMenu'main'
		return
	end

	-- you can redirect connected players to game players ...
	-- then have buttons for auto-assign-first-players or not
end

function Menu:updateMenuInput()
	local app = self.app

	self:menuSection'input'

	local pushCursorX, pushCursorY = self.cursorX, self.cursorY
	for playerIndexPlusOne=1,maxLocalPlayers do
		local playerIndex = playerIndexPlusOne-1
		self.cursorX = bit.band(playerIndex, 1) * 128 + 8
		self.cursorY = pushCursorY + bit.band(bit.rshift(playerIndex, 1), 1) * (#buttonSingleCharLabels + 3) * 9

		self:menuLabel('player '..playerIndexPlusOne)
		local playerInfo = app.cfg.playerInfos[playerIndexPlusOne]
		self:menuLabel(playerInfo.name)
		for buttonIndexPlusOne,buttonName in ipairs(buttonSingleCharLabels) do
			local buttonIndex = buttonIndexPlusOne - 1	-- atm playerInfo.buttonBinds is 0-based
			-- TODO instead of name use some of our extra codes ...
			app:drawText(buttonName, self.cursorX-8, self.cursorY, 0xfc, 0xf0)
			local buttonBind = playerInfo.buttonBinds[buttonIndex]
			local label = app.waitingForEvent and self.menuTabIndex == self.menuTabCounter
				and 'Press...'
				or tostring(buttonBind and buttonBind.name or '...')
			if self:menuButton(label) then
				-- if we're waiting then call it 'press a key'
				-- otherwise show the key desc
				-- capture it
				app.waitingForEvent = {
					callback = function(e)
--print('got event', require 'ext.tolua'(e))
						-- [[ let esc clear the binding
						if e[1] == sdl.SDL_KEYDOWN and e[2] == sdl.SDLK_ESCAPE then
							playerInfo.buttonBinds[buttonIndex] = {}
							return
						end
						--]]

						playerInfo.buttonBinds[buttonIndex] = e
					end,
				}
			end
		end
	end
	self.cursorX = pushCursorX
	self.cursorY = self.cursorY + 9

	if self:menuButton'back' then
		self:setCurrentMenu'main'
		return
	end
end

return Menu
