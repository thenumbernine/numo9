local table = require 'ext.table'

local CartBrowser = require 'numo9.ui':subclass()

function CartBrowser:update()
--	CartBrowser.super.update(self)	-- clears screen, shows the current-editor tab etc
	self:initMenuTabs()
	local app = self.app

	app:setVideoMode(0)
	app:clearScreen(0xf0, app.paletteMenuTex)

	local fs = app.fs

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()
	-- cycle through vfs and find .n9 carts in this dir and ...
	-- ... make textures for their icons ...
	-- ... and then have buttons on :update()
	local x = 0
	local y = 0
	local fgColor = 13
	local defaultBgColor = 8
	local selBgColor = 4

	local fileNames = table.keys(fs.cwd.chs):sort()

	self:guiTextField(x, y, 32,
		fs.cwd:path(),
		nil,
		function(result) fs:cd(result) end
	)

	y = y + 8
	x = x + 8
	local w = 128	-- how wide .. text length? or fixed button length?
	local h = 8
	local mouseOverSel
	local selname
	for i,name in ipairs(fileNames) do
		local f = fs.cwd.chs[name]

		local sel = self.menuTabIndex == self.menuTabCounter
		if sel then
			mouseOverSel = true
			selname = name
		end

		if f.isdir then 				-- dir
			self:guiButton('['..name..']', x, y)
		elseif name:match'%.n9$' then	-- cart file
			if self:guiButton('*'..name, x, y) then
				-- clicked it ...
			end
		else							-- non-cart file
			self:guiButton(' '..name, x, y)
		end

		y = y + 8
	end

	local selfile = selname and fs.cwd.chs[selname]
	if self.thumbTex == nil
	and selname
	and selname:match'%.n9$'
	and selfile
	then
		xpcall(function()
			-- load splash tex or something
			local srcData = assert(selfile.data)
			local ffi = require 'ffi'
			local path = require 'ext.path'

			-- [[ this is also in numo9/archive.lua fromCartImage ...
			local tmploc = ffi.os == 'Windows' and path'___tmp.png' or path'/tmp/__tmp.png'
			assert(path(tmploc):write(srcData))
			local Image = require 'image'
			local romImage = assert(Image(tmploc.path))
			tmploc:remove()
			--]]
			--[[
			local romImage = require 'image.luajit.png':loadMem(srcData)
			--]]

			-- load the splash tex here
			-- I could just create these as I need them and trust gc cleanup to dealloc them
			-- or if dealloc isn't trustworthy (esp for GPU ram) then I could cache them here (and maybe clear the cache when the folder changes?)
			self.labelTexCache = self.labelTexCache or {}
			local selfilecwd = selfile:path()
			self.thumbTex = self.labelTexCache[selfilecwd]
			if not self.thumbTex then
				local GLTex2D = require 'gl.tex2d'
				local gl = require 'gl'
				--local internalFormat = gl.GL_RGBA8I
				local internalFormat = gl.GL_RGBA8UI
				--local internalFormat = gl.GL_RGBA8
				--local internalFormat = gl.GL_RGBA
				local tex = GLTex2D{
					image = romImage,
					internalFormat = internalFormat,
					format = GLTex2D.formatInfoForInternalFormat[internalFormat].format,
					type = GLTex2D.formatInfoForInternalFormat[internalFormat].types[1],
					wrap = {
						s = gl.GL_CLAMP_TO_EDGE,
						t = gl.GL_CLAMP_TO_EDGE,
					},
					minFilter = gl.GL_NEAREST,
					magFilter = gl.GL_NEAREST,
				}:unbind()
				self.labelTexCache[selfilecwd] = tex
				self.thumbTex = tex
			end
		end, function(err)
			print(err..'\n'..debug.traceback())
			-- store 'false' in cache so we know not to try again
			self.thumbTex = false
		end)
	end

	if self.thumbTex then
		local w, h = 128, 128
		local ar = self.thumbTex.width / self.thumbTex.height
		if ar > 1 then
			h = h / ar
		else
			w = w * ar
		end
		--[[
		TODO this is going to draw the textures as if its contents are r8 palette indexed
		however
		the contents are rgb
		so it's just going to use red channel -> palette index
		so
		how to fix this?
		1) force save label images as paletted to the menu palette
		2) save them rgb and add a new ubershader render pathway for rgb textures
		3) flush and use a separate shader for just this menu system
		--]]
		app:drawQuadTexRGB(
			app.paletteMenuTex,
			self.thumbTex,
			128, 8,
			w, h,
			0, 0,
			1, 1
		)
	end

	-- TODO needs scrolling for when there's more files than screen rows

	if app:keyp'return'
	or (leftButtonPress and mouseOverSel)
	or app:btnp'y'
	then
		-- then run the cart ... is it a cart?
		if selname:match'%.n9$' then
			--app:setMenu(nil)
			-- numo9/ui's "load" says "do this from runFocus thread, not UI thread"
			-- but if I do that here then it seems to stall after the 2nd or 3rd time until i open and close the console again ...
			-- but if I don't do app:setFocus{...} to load the ROM then I get things like bad video mode and mvmat
			app:setFocus{
				thread = coroutine.create(function()
					-- name, or path / name ?  if path is cwd then we're fine right?
					-- TODO what if we're a server?  then we should do what's in numo9/app.lua's open() function, send RAM snapshot to all clients.
					app:net_openROM(selname)
					app:runROM()
				end),
			}
			app.isPaused = false	-- make sure the setFocus does run
		end
	end
end

function CartBrowser:event(e)
	local lastMenuTabIndex = self.menuTabIndex

	local result = CartBrowser.super.event(self, e)

	if self.menuTabIndex ~= lastMenuTabIndex then
		self.thumbTex = nil	-- clear it and try to regen cache next update
	end

	return result
end

return CartBrowser
