objs=table()

--#include ext/class.lua
--#include vec/vec2.lua

Object=class()
Object.spriteSize = vec2(1,1)	-- tile size, override for 16x16
Object.tileSize = vec2(1,1)		-- tile size, override for 16x16
Object.pos = vec2()
Object.vel = vec2()
Object.gravity = vec2(0,1)
Object.bbox = {min=vec2(-.3), max=vec2(.3)}
Object.init=|:,args|do
	for k,v in pairs(args) do self[k]=v end
	self.pos = self.pos:clone()
	self.vel = self.vel:clone()
	self.health = self.maxHealth
	self.hitSides = 0	-- bitflags of dirvecs
	objs:insert(self)
end
Object.draw=|:|do
	spr(
		self.sprite,		-- spriteIndex
		self.pos.x * self.tileSize.x * 8 - .5 * self.tileSize.x * self.spriteSize.x * 8,-- screenX
		self.pos.y * self.tileSize.y * 8 - .5 * self.tileSize.y * self.spriteSize.y * 8,-- screenY
		self.tileSize.x,	-- tilesWide
		self.tileSize.y,	-- tilesHigh
		0,					-- orientation2D
		self.spriteSize.x,	-- scaleX
		self.spriteSize.y 	-- scaleY
	)
end
Object.remove=|:|do	-- the OOP bloat begins...
	self.removeMe=true
end
Object.update=|:|do

	-- move

	self.hitSides = 0
	for bi=0,1 do	-- move vert then horz, so we can slide on walls or something
		local dx,dy = 0, 0
		if bi == 0 then
			dy = self.vel.y
		elseif bi == 1 then
			dx = self.vel.x
		end
		if dx ~= 0 or dy ~= 0 then
			local nx = self.pos.x + dx
			local ny = self.pos.y + dy
			-- old bbox
			local oxmin = self.pos.x + self.bbox.min.x
			local oymin = self.pos.y + self.bbox.min.y
			local oxmax = self.pos.x + self.bbox.max.x
			local oymax = self.pos.y + self.bbox.max.y
			-- new bbox
			local pxmin = nx + self.bbox.min.x
			local pymin = ny + self.bbox.min.y
			local pxmax = nx + self.bbox.max.x
			local pymax = ny + self.bbox.max.y
			local hit
			for bymin=math.clamp(math.floor(pymin), 0, mapheight-1), math.clamp(math.ceil(pymax), 0, mapheight-1) do
				for bxmin=math.clamp(math.floor(pxmin), 0, mapwidth-1), math.clamp(math.ceil(pxmax), 0, mapwidth-1) do
					local bxmax, bymax = bxmin + 1, bymin + 1
					local ti = tget(0, bxmin, bymin)
					local t = mapTypes[ti]
					if ti ~= 0	-- just skip 'empty' ... right ... ?
					and t
					then
						-- if we're moving up/down and our left-right bounds touches and our up-down crosses the boundary
						-- or if vice versa
						if (bi == 0 and pxmax >= bxmin and pxmin <= bxmax
							and (
								dy < 0
								and (oymin >= bymax and bymax >= pymin)
								or (oymax <= bymin and bymin <= pymax)
							)
						)
						or (bi == 1 and pymax >= bymin and pymin <= bymax
							and (
								dx < 0
								and (oxmin >= bxmax and bxmax >= pxmin)
								or (oxmax <= bxmin and bxmin <= pxmax)
							)
						)
						then
							local side = bi == 0 and (
								dy < 0 and dirForName.down or dirForName.up
							) or (
								dx < 0 and dirForName.right or dirForName.left
							)

							-- do world hit
							local hitThis = true
							if t.touch 
							and t:touch(self, bxmin, bymin, side) == false 
							then 
								hitThis = false 
							end
							if self.touchMap 
							and self:touchMap(bxmin, bymin, t, ti) == false 
							then 
								hitThis = false 
							end
							-- so block solid is based on solid flag and touch result ...

							local targetFlag
							if bi == 0 then	-- moving up/down
								if dy < 0 then
									targetFlag = flags.solid_down
								elseif dy > 0 then
									targetFlag = flags.solid_up
								end
							elseif bi == 1 then 	-- moving left/right
								if dx < 0 then
									targetFlag = flags.solid_left
								elseif dx > 0 then
									targetFlag = flags.solid_right
								end
							end
							if targetFlag and t.flags & targetFlag ~= 0 then
								hit = hit or hitThis
							end
						end
					end
				end
			end
			for _,o in ipairs(objs) do
				if o ~= self then
					local bxmin, bymin = o.pos.x + o.bbox.min.x, o.pos.y + o.bbox.min.y
					local bxmax, bymax = o.pos.x + o.bbox.max.x, o.pos.y + o.bbox.max.y
					if pxmax >= bxmin and pxmin <= bxmax
					and pymax >= bymin and pymin <= bymax
					then
						-- if not solid then
						-- TODO side solid flags like with map blocks, so we can have things like moving platforms
						local hitThis = true
						if self.touch and self:touch(o) == false then 
							hitThis = false 
						end
						if o.touch and o:touch(self) == false then 
							hitThis = false 
						end
						hit = hit or hitThis
					end
				end
			end
			if not hit then
				self.pos:set(nx, ny)
				-- TODO bomberman slide ... if you push down at a corner then push player left/right to go around it ...
			else
				if bi == 0 then
					if self.vel.y > 0 then
						self.hitSides |= 1 << dirForName.down
					else
						self.hitSides |= 1 << dirForName.up
					end
					self.vel.y = 0
				else
					if self.vel.x > 0 then
						self.hitSides |= 1 << dirForName.right
					else
						self.hitSides |= 1 << dirForName.left
					end
					self.vel.x = 0
				end
			end
		end
	end

	if self.useGravity then
		self.vel.x += dt * self.gravity.x
		self.vel.y += dt * self.gravity.y
	end
end
