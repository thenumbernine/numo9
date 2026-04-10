--#include ext/class.lua
--#include vec/vec2.lua
--#include vec/vec3.lua
--#include numo9/matstack.lua	-- modelMatrixIndex etc


-- light system object
Lights = {}
do
	-- how many lights to use
	-- must be less than max lights,
	--  which is hard coded to the ram size ...
	-- tell user somehow ... offsetof struct after lights?
	--  or make it a 'light' blob?
	Lights.numLightsAddr = ramaddr'numLights'
	Lights.count = 0

	-- TODO this is in numo9/rom.lua
	-- gotta think of a way of how to provide it to ramaddr / ramsize
	Lights.lightStructSize = 0xc8
	Lights.lightEnabledOffset = 0x00 -- size=0x01 type=unsigned char
	Lights.lightRegionOffset = 0x02 -- size=0x08 type=unsigned short [4]
	Lights.lightAmbientColorOffset = 0x0c -- size=0x0c type=float [3]
	Lights.lightDiffuseColorOffset = 0x18 -- size=0x0c type=float [3]
	Lights.lightSpecularColorOffset = 0x24 -- size=0x10 type=float [4]
	Lights.lightDistAttenOffset = 0x34 -- size=0x0c type=float [3]
	Lights.lightCosAngleRangeOffset = 0x40 -- size=0x08 type=float [2]
	Lights.lightViewMatOffset = 0x48 -- size=0x40 type=float [16]
	Lights.lightProjMatOffset = 0x88 -- size=0x40 type=float [16]


	-- TODO rect allocator
	-- do everything in 128x128 blocks?
	-- allocate by this:
	Lights.lightmapWidth = peekw(ramaddr'lightmapWidth')
	Lights.lightmapHeight = peekw(ramaddr'lightmapHeight')

	Lights.lightsAddr = ramaddr'lights'
	Lights.lightAddrEnd = Lights.lightsAddr + ramsize'lights'
	Lights.maxLights = (Lights.lightAddrEnd - Lights.lightsAddr) / Lights.lightStructSize	-- TODO match RAM somehow, or use blobs'light' size TODO
	assert.eq((Lights.lightAddrEnd - Lights.lightsAddr) % Lights.lightStructSize, 0, 'lightsAddr block not aligned to light size')
	assert.eq(Lights.lightsAddr + Lights.maxLights * Lights.lightStructSize, Lights.lightAddrEnd)

	Lights.lightSubSize = 128	-- 128 x 128 subregions in our uber-lightmap
	Lights.lightmapWidthInSubRegions = math.floor(Lights.lightmapWidth / Lights.lightSubSize)
	Lights.lightmapHeightInSubRegions = math.floor(Lights.lightmapHeight / Lights.lightSubSize)

	-- make sure we use no more than we have subregion room for
	do
		local maxLightSubRegions = Lights.lightmapWidthInSubRegions * Lights.lightmapHeightInSubRegions
		if Lights.maxLights > maxLightSubRegions then
			trace('!!! mem maxLights is '..Lights.maxLights..' but subregion only has room for '..maxLightSubRegions)
			Lights.maxLights = maxLightSubRegions
		end
	end

	-- w,h = width and height in our subregion units (128x128)
	-- current allocation scheme is intentionally poor.
	-- it's made for 1x1 unit subregions.
	--  it'll just inc by x, then if it overflows it'll increment y
	-- so if you do this on w,h > 1 (like the skylight) then don't expect it to work for any more lights than this.
	Lights.new = |:,w,h|do
		if self.count >= self.maxLights then
			trace'!!! light overflow'
			return
		end

		w = w or 1
		h = h or 1
		local lightAddr = self.lightsAddr + self.count * self.lightStructSize
		self.count += 1
		local x = self.lightmapRegionCurX
		local y = self.lightmapRegionCurY
		self.lightmapRegionCurX += w
		if self.lightmapRegionCurX >= self.lightmapWidthInSubRegions then
			self.lightmapRegionCurX = 0
			self.lightmapRegionCurY += h
		end
		return lightAddr,
			x * self.lightSubSize,
			y * self.lightSubSize,
			w * self.lightSubSize,
			h * self.lightSubSize
	end

	-- for now, one giant map
	-- TODO eventually make it use a bunch of 128x128 blocks like point lights below do
	-- for now this will overwrite any dir lights (or vice versa)
	Lights.makeSunLight = |:,stagesize|do
		local lightAddr, lx, ly, lw, lh = Lights:new(self.lightmapWidthInSubRegions, self.lightmapHeightInSubRegions)

		-- TODO using mat for our light math causes tri buf flushes and mat dirty bit flags ... meh?
		matpush(projMatrixIndex)
		matpush(viewMatrixIndex)	-- push the view mat

		matident(projMatrixIndex)
		local orthoSize = .5 * stagesize:len()	-- max diagonal
		local znear, zfar = -4, 2 * orthoSize
		matortho(-orthoSize, orthoSize, -orthoSize, orthoSize, znear, zfar)	-- projMatrixIndex by default

		matident(viewMatrixIndex)
		-- negative rotation because inverse for view transform
		-- angle starts looking down i.e. towards z- (cuz opengl)
		-- tilting up 45 degrees means its still tilted at a pitch down of 45 degrees.
		matrot(-math.rad(45), 1, 0, 0, viewMatrixIndex)	-- initial view angle is straight down ...
		-- cam starts looking along y+ so 45 to the right
		matrot(-math.rad(-45), 0, 0, 1, viewMatrixIndex)
		local fwdx = -peekf(ramaddr'viewMat' + 2*4)	 -- -.5
		local fwdy = -peekf(ramaddr'viewMat' + 6*4)	-- .5
		local fwdz = -peekf(ramaddr'viewMat' + 10*4)	-- -math.sqrt(2)
		-- position the light a way from the center.
		-- ortho can do +- z ranges, but the light calcs still look at light view mat pos
		-- a TODO could be using a lightpos vec4 instead of calculating it from the light view matrix
		-- this would provide better directional lights (set w=0)
		--  but would mean more redundant variables for the cart programmer to correlate.
		mattrans(
			-(.5 * stagesize.x - orthoSize * fwdx),
			-(.5 * stagesize.y - orthoSize * fwdy),
			-(.5 * stagesize.z - orthoSize * fwdz),
			viewMatrixIndex)

		poke(lightAddr + self.lightEnabledOffset, 0xff)	-- light is enabled for depth-write and for surface-calculations

		memcpy(lightAddr + self.lightViewMatOffset, ramaddr'viewMat', 64)	-- matrix #1
		memcpy(lightAddr + self.lightProjMatOffset, ramaddr'projMat', 64)	-- matrix #2

		matpop(viewMatrixIndex)
		matpop(projMatrixIndex)

		-- is per-light ambient color dumb?
		pokef(lightAddr + self.lightAmbientColorOffset, 0)
		pokef(lightAddr + self.lightAmbientColorOffset+4, 0)
		pokef(lightAddr + self.lightAmbientColorOffset+8, 0)
		pokef(lightAddr + self.lightDiffuseColorOffset, 1)
		pokef(lightAddr + self.lightDiffuseColorOffset+4, 1)
		pokef(lightAddr + self.lightDiffuseColorOffset+8, 1)
		pokef(lightAddr + self.lightSpecularColorOffset, .3)
		pokef(lightAddr + self.lightSpecularColorOffset+4, .2)
		pokef(lightAddr + self.lightSpecularColorOffset+8, .1)
		pokef(lightAddr + self.lightSpecularColorOffset+12, 30)
		pokef(lightAddr + self.lightDistAttenOffset, 1)	-- constant / global attenuation
		pokef(lightAddr + self.lightDistAttenOffset+4, 0)
		pokef(lightAddr + self.lightDistAttenOffset+8, 0)
		pokef(lightAddr + self.lightCosAngleRangeOffset, -2)	-- set cos angle range to [-2,-1] so all values map to 1
		pokef(lightAddr + self.lightCosAngleRangeOffset+4, -1)

		-- subimage/viewport on the lightmap
		pokew(lightAddr + self.lightRegionOffset, lx)
		pokew(lightAddr + self.lightRegionOffset+2, ly)
		pokew(lightAddr + self.lightRegionOffset+4, lw)
		pokew(lightAddr + self.lightRegionOffset+6, lh)
	end


	-- static, singleton, class for object
	local MakeLight = class()
	Lights.MakeLight = MakeLight
	MakeLight.znear = .01
	MakeLight.zfar = 10
	MakeLight.ambient = vec3(.4, .3, .2)
	MakeLight.diffuse = vec3(1, 1, 1)
	MakeLight.specular = vec3(.6, .5, .4)
	MakeLight.shininess = 30
	MakeLight.distAtten = vec3(.7, 0, .01)	-- quadratic attenuation
	MakeLight.cosAngleRange = vec2(-2, -1)		-- don't set equal so we don't get divide-by-zero
	MakeLight.tanHalfFOV = 1 -- math.tan(math.rad(.5 * 90))	-- used for 90 degrees
	MakeLight.go = |:, x,y,z| do
		local znear, zfar, tanHalfFOV = self.znear, self.zfar, self.tanHalfFOV
		matpush(projMatrixIndex)	-- push proj mat
		matpush(viewMatrixIndex)	-- push view mat
		-- set up a torch point light at the player
		-- TODO lightmap block allocation system ...
		for lightIndex=0,self.numSides-1 do
			local lightAddr, lx, ly, lw, lh = Lights:new()
			-- TODO using mat for our light math causes tri buf flushes and mat dirty bit flags ... meh?

			poke(lightAddr + Lights.lightEnabledOffset, 0xff)
			-- subimage/viewport on the lightmap
			pokew(lightAddr + Lights.lightRegionOffset, lx)
			pokew(lightAddr + Lights.lightRegionOffset+2, ly)
			pokew(lightAddr + Lights.lightRegionOffset+4, lw)
			pokew(lightAddr + Lights.lightRegionOffset+6, lh)

			matident(projMatrixIndex)
			matfrustum(
				-tanHalfFOV * znear,
				tanHalfFOV * znear,
				-tanHalfFOV * znear,
				tanHalfFOV * znear,
				znear,
				zfar)	-- matfrustum sets projMatrixIndex by default

			matident(viewMatrixIndex)
			self:sideTransform(lightIndex)
			mattrans(-x, -y, -z, viewMatrixIndex)

			memcpy(lightAddr + Lights.lightViewMatOffset, ramaddr'viewMat', 64)	-- matrix #1
			memcpy(lightAddr + Lights.lightProjMatOffset, ramaddr'projMat', 64)	-- matrix #2

			pokef(lightAddr + Lights.lightAmbientColorOffset, self.ambient.x)
			pokef(lightAddr + Lights.lightAmbientColorOffset+4, self.ambient.y)
			pokef(lightAddr + Lights.lightAmbientColorOffset+8, self.ambient.z)
			pokef(lightAddr + Lights.lightDiffuseColorOffset, self.diffuse.x)
			pokef(lightAddr + Lights.lightDiffuseColorOffset+4, self.diffuse.y)
			pokef(lightAddr + Lights.lightDiffuseColorOffset+8, self.diffuse.z)
			pokef(lightAddr + Lights.lightSpecularColorOffset, self.specular.x)
			pokef(lightAddr + Lights.lightSpecularColorOffset+4, self.specular.y)
			pokef(lightAddr + Lights.lightSpecularColorOffset+8, self.specular.z)
			pokef(lightAddr + Lights.lightSpecularColorOffset+12, self.shininess)
			pokef(lightAddr + Lights.lightDistAttenOffset, self.distAtten.x)
			pokef(lightAddr + Lights.lightDistAttenOffset+4, self.distAtten.y)
			pokef(lightAddr + Lights.lightDistAttenOffset+8, self.distAtten.z)
			pokef(lightAddr + Lights.lightCosAngleRangeOffset, self.cosAngleRange.x)
			pokef(lightAddr + Lights.lightCosAngleRangeOffset+4, self.cosAngleRange.y)
		end
		matpop(viewMatrixIndex)	-- pop view mat
		matpop(projMatrixIndex)	-- pop proj mat
	end

	-- cube point light
	local MakePointCubeLight = MakeLight:subclass()
	Lights.MakePointCubeLight = MakePointCubeLight
	MakePointCubeLight.numSides = 6
	MakePointCubeLight.sideTransform = |:, lightIndex| do
		if lightIndex < 4 then
			matrot(-math.rad(90), 1, 0, 0, viewMatrixIndex)	-- initial view angle is straight down ...
			matrot(-math.rad(lightIndex * 90), 0, 0, 1, viewMatrixIndex)
		elseif lightIndex == 4 then	-- down
			-- init dir is down
		elseif lightIndex == 5 then	-- up
			matrot(-math.rad(180), 1, 0, 0, viewMatrixIndex)
		end
	end
	Lights.makePointLight = |...|do
		MakePointCubeLight:go(...)
	end


	-- point light but with 4 sides
	-- this has overlap, but I could batch light depth test calcs and skip on testing redundant lights (i.e. 1 in 6 of a cube light, or 1 in 4 of a tetrad light)
	local MakePointTetrahedronLight = MakeLight:subclass()
	Lights.MakePointTetrahedronLight = MakePointTetrahedronLight
	MakePointTetrahedronLight.numSides = 4
	--MakePointTetrahedronLight.tanHalfFOV = math.tan(.5 * math.acos(-1/3))	-- -1/3 is the dot product of normalized tetrahedron vertices ... still just gives me sqrt(2)
	MakePointTetrahedronLight.tanHalfFOV = 3	-- oops but that wasnt enough so I just set it to 3
	MakePointTetrahedronLight.sideTransform = |:, lightIndex| do
		if lightIndex == 3 then
			-- identity
		else	-- 0-2, rotate down acos(-1/3) = 1.910633236249 radians, then rotate around by 120 each 
			matrot(-math.rad(109), 1, 0, 0, viewMatrixIndex)	-- rotate up by 109 degrees
			matrot(-math.rad(lightIndex * 120), 0, 0, 1, viewMatrixIndex)	-- rotate around by 120 degrees
		end
	end
	Lights.makePointLightTetrahedron = |...| do
		MakePointTetrahedronLight:go(...)
	end



	-- TODO spotlight angle attenuation (min/max angle)
	local MakeSpotLight = class()
	Lights.MakeSpotLight = MakeSpotLight
	MakeSpotLight.ambient = vec3(.4, .3, .2)
	MakeSpotLight.diffuse = vec3(1, 1, 1)
	MakeSpotLight.specular = vec3(.6, .5, .4)
	MakeSpotLight.shininess = 30
	-- [[ quadratic distance attenuation
	MakeSpotLight.distAtten = vec3(.7, 0, .1)
	--]]
	--[[ no distance attenuation
	MakeSpotLight.distAtten = vec3(1, 0, 0)
	--]]
	MakeSpotLight.go = |:, x,y,z, yawAngle, pitchAngle, spotOuterAngle, spotInnerAngle|do
		-- set up a torch point light at the player
		-- TODO lightmap block allocation system ...
		local lightAddr, lx, ly, lw, lh = Lights:new()

		-- TODO using mat for our light math causes tri buf flushes and mat dirty bit flags ... meh?
		matpush(projMatrixIndex)
		matpush(viewMatrixIndex)	-- push the view mat

		matident(projMatrixIndex)
		local tanHalfFOV = math.tan(math.rad(spotOuterAngle))
		local znear, zfar = .01, 10	-- light znear/zfar
		matfrustum(
			-tanHalfFOV * znear,
			tanHalfFOV * znear,
			-tanHalfFOV * znear,
			tanHalfFOV * znear,
			znear, zfar)	-- projMatrixIndex by default

		matident(viewMatrixIndex)
		matrot(-math.rad(90 + pitchAngle), 1, 0, 0, viewMatrixIndex)	-- initial view angle is straight down ...
		matrot(-math.rad(yawAngle), 0, 0, 1, viewMatrixIndex)

		mattrans(-x, -y, -z, viewMatrixIndex)

		poke(lightAddr + Lights.lightEnabledOffset, 0xff)		-- light is enabled for depth-write and for surface-calculations

		memcpy(lightAddr + Lights.lightViewMatOffset, ramaddr'viewMat', 64)	-- matrix #1
		memcpy(lightAddr + Lights.lightProjMatOffset, ramaddr'projMat', 64)	-- matrix #2

		matpop(viewMatrixIndex)
		matpop(projMatrixIndex)

		pokef(lightAddr + Lights.lightAmbientColorOffset, self.ambient.x)
		pokef(lightAddr + Lights.lightAmbientColorOffset+4, self.ambient.y)
		pokef(lightAddr + Lights.lightAmbientColorOffset+8, self.ambient.z)
		pokef(lightAddr + Lights.lightDiffuseColorOffset, self.diffuse.x)
		pokef(lightAddr + Lights.lightDiffuseColorOffset+4, self.diffuse.y)
		pokef(lightAddr + Lights.lightDiffuseColorOffset+8, self.diffuse.z)
		pokef(lightAddr + Lights.lightSpecularColorOffset, self.specular.x)
		pokef(lightAddr + Lights.lightSpecularColorOffset+4, self.specular.y)
		pokef(lightAddr + Lights.lightSpecularColorOffset+8, self.specular.z)
		pokef(lightAddr + Lights.lightSpecularColorOffset+12, self.shininess)
		pokef(lightAddr + Lights.lightDistAttenOffset, self.distAtten.x)
		pokef(lightAddr + Lights.lightDistAttenOffset+4, self.distAtten.y)
		pokef(lightAddr + Lights.lightDistAttenOffset+8, self.distAtten.z)
		pokef(lightAddr + Lights.lightCosAngleRangeOffset, math.cos(math.rad(spotOuterAngle)))
		pokef(lightAddr + Lights.lightCosAngleRangeOffset+4, math.cos(math.rad(spotInnerAngle)))

		-- subimage/viewport on the lightmap
		pokew(lightAddr + Lights.lightRegionOffset, lx)
		pokew(lightAddr + Lights.lightRegionOffset+2, ly)
		pokew(lightAddr + Lights.lightRegionOffset+4, lw)
		pokew(lightAddr + Lights.lightRegionOffset+6, lh)
	end
	Lights.makeSpotLight = |...| MakeSpotLight:go(...)

	Lights.beginFrame = |:|do
		-- reset light counters
		self.count = 0
		Lights.lightmapRegionCurX = 0
		Lights.lightmapRegionCurY = 0
	end

	Lights.endFrame = |:|do
		pokew(self.numLightsAddr, self.count)
	end
end
