local ffi = require 'ffi'
local table = require 'ext.table'
local path = require 'ext.path'
local Image = require 'image'
local gl = require 'gl'
local GLTex2D = require 'gl.tex2d'

local CartBrowser = require 'numo9.ui':subclass()

local UITextField = require 'numo9.ui.textfield'
local UIButton = require 'numo9.ui.button'


function CartBrowser:init(...)
	CartBrowser.super.init(self, ...)

	self:newUI_setup()
end

function CartBrowser:gainFocus(...)
	CartBrowser.super.gainFocus(self, ...)

	-- refresh UI
	local app = self.app
	local fs = app.fs

	-- cycle through vfs and find .n9 carts in this dir and ...
	-- ... make textures for their icons ...
	-- ... and then have buttons on :update()
	local x = 0
	local y = 0

	local fileNames = table.keys(fs.cwd.chs):sort()

	self:addChild(UITextField{
		owner = self,
		pos = {x, y},
		width = 32,
		value = fs.cwd:path(),
		events = {
			change = function(target, e)
				local result = target.value
				fs:cd(result)
			end,
		},
	})

	y = y + 8
	x = x + 8
	local selY
	local w = 128	-- how wide .. text length? or fixed button length?
	local h = 8
	for i,filename in ipairs(fileNames) do
		local fileObj = fs.cwd.chs[filename]

		if fileObj.isdir then 				-- dir
			self:addChild(UIButton{
				owner = self,
				pos = {x, y},
				text = '['..filename..']',
				--[[ TODO make it toggle-able?
				events = {
					click = function()
						-- TODO
					end,
				},
				--]]
			})
		elseif filename:match'%.n9$' then	-- cart file
			local focus = function()
--print('mouse focus', fileObj)
				-- if the selected file changes ...
				if fileObj == self.selectedFile then return end
				self.selectedFile = fileObj
--print('setting selectedFile', fileObj)
				self:refreshThumbTex()
			end

			self:addChild(UIButton{
				owner = self,
				pos = {x, y},
				text = '*'..filename,
				events = {
					focus = focus,
					-- TODO this on mouseover or on tab
					-- why isn't focus() getting called on mouseover?
					mouseenter = focus,

					-- TODO this on mouse click or enter
					click = function()
						local app = self.app
						-- then run the cart ...
						--app:setMenu(nil)
						-- numo9/ui's "load" says "do this from runFocus thread, not UI thread"
						-- but if I do that here then it seems to stall after the 2nd or 3rd time until i open and close the console again ...
						-- but if I don't do app:setFocus{...} to load the ROM then I get things like bad video mode and mvmat
						app:setFocus{
							thread = coroutine.create(function()
								-- filename, or path / filename ?  if path is cwd then we're fine right?
								-- TODO what if we're a server?  then we should do what's in numo9/app.lua's open() function, send RAM snapshot to all clients.
								app:net_openCart(filename)
								app:runCart()
							end),
						}
						app.isPaused = false	-- make sure the setFocus does run
					end,
				},
			})
		else							-- non-cart file
			self:addChild(UIButton{
				owner = self,
				pos = {x, y},
				text = ' '..filename,
			})
		end

		y = y + 8
	end
end

function CartBrowser:update()
	self:newUI_realignChildren()

--	CartBrowser.super.update(self)	-- clears screen, shows the current-editor tab etc

	self:initMenuTabs()

	local app = self.app
	app:clearScreen(0xf0, app.paletteMenuTex)

	if self.thumbTex then
		local w, h = 128, 128
		local ar = self.thumbTex.width / self.thumbTex.height
		if ar > 1 then
			h = h / ar
		else
			w = w * ar
		end

		local x, y = 127, 8
		app:drawSolidRect(
			x - 1, y - 1,
			w + 2, h + 2,
			15,		-- dark grey
			true,	-- border
			false,	-- ellipse
			app.paletteMenuTex
		)

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
			x, y, w, h,	-- x y w h
			0, 0, 1, 1	-- tx ty tw th
		)
	end

	self:newUI_update()
end

function CartBrowser:refreshThumbTex()
	local fileObj = self.selectedFile
--print('refreshing thumb of selectedFile', fileObj)

	-- legacy system, this screws up on errors now, fix it by fixing tabstop in new ui
	if not fileObj then return end

	-- ... then clear and reload the thumbnail texture
	self.thumbTex = nil

	xpcall(function()
		-- load splash tex or something
		local srcData = assert(fileObj.data)

		-- [[ this is also in numo9/archive.lua cartImageToBlobStr...
		local tmploc = ffi.os == 'Windows' and path'___tmp.png' or path'/tmp/__tmp.png'
		assert(path(tmploc):write(srcData))
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
		local selectedFilePath = fileObj:path()
		self.thumbTex = self.labelTexCache[selectedFilePath]
		if not self.thumbTex then
			--local internalFormat = gl.GL_RGBA8I
			local internalFormat = gl.GL_RGBA8UI
			--local internalFormat = gl.GL_RGBA8
			--local internalFormat = gl.GL_RGBA
			-- TODO don't cache the GPU buffer, just cache the CPU buffer and allocate one GPU buffer and re-upload it ...
			local tex = GLTex2D{
				image = romImage,
				internalFormat = internalFormat,
				format = GLTex2D.formatInfoForInternalFormat[internalFormat].format,
				type = GLTex2D.formatInfoForInternalFormat[internalFormat].types[1],
				wrap = {
					s = gl.GL_REPEAT,
					t = gl.GL_REPEAT,
				},
				minFilter = gl.GL_NEAREST,
				magFilter = gl.GL_NEAREST,
			}:unbind()
			self.labelTexCache[selectedFilePath] = tex
			self.thumbTex = tex
		end
	end, function(err)
		print(err..'\n'..debug.traceback())
		-- store 'false' in cache so we know not to try again
		self.thumbTex = false
	end)
end

function CartBrowser:event(e)
	-- probably needed from legacy system
	if not self.menuTabIndex then
--print'TODO - we lost menuTabIndex again...'
		self.menuTabIndex = 0
	end

	local lastMenuTabIndex = self.menuTabIndex

-- old way I guess? to-be-replaced with newUI_event ?
--	local result = CartBrowser.super.event(self, e)
	local result = self:newUI_event(e)

	if self.menuTabIndex ~= lastMenuTabIndex then
		self:refreshThumbTex()
	end

	return result
end

return CartBrowser
