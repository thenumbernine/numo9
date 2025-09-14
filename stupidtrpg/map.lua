MapTile=class{
	init=|:|nil,
	isRevealed=|:|do
		local visibleTime=-math.log(0)
		return self.lastSeen and (game.time - self.lastSeen) < visibleTime
	end,
	getChar=|:|do
		return self.char or self.type.char
	end,
	addEnt=|:,ent|do
		if not self.ents then
			self.ents=table()
		end
		self.ents:insert(ent)
	end,
	removeEnt=|:,ent|do
		assert(self.ents)
		self.ents:removeObject(ent)
		if #self.ents == 0 then
			self.ents=nil
		end
	end,
	draw=|:,x,y|do
		spr(self.type.sprite,x,y,2,2)
	end,
}

map={}
map.size=vec2(256,256)
map.bbox=box2(1, map.size)
map.tiles={}				-- TOOD switch to tilemap, but that means switching all positions from 1-based to 0-based
for i=1,map.size.x do
	map.tiles[i]={}
	for j=1,map.size.y do
		local tile=MapTile()
		tile.type=tiletypes.floor
		map.tiles[i][j]=tile
	end
end

local seeds=table()
for i=1,math.floor(map.size:product()/13) do
	local seed={
		pos=vec2(math.random(map.size.x), math.random(map.size.y)),
	}
	seed.mins=seed.pos:clone()
	seed.maxs=seed.pos:clone()
	seeds:insert(seed)
	map.tiles[seed.pos.x][seed.pos.y].seed=seed
end

local modified
repeat
	modified = false
	for _,seed in ipairs(seeds) do
		local mins = (seed.mins - 1):clamp(map.bbox)
		local maxs = (seed.maxs + 1):clamp(map.bbox)
		local seedcorners = {seed.mins, seed.maxs}
		local corners = {mins, maxs}
		for i,corner in ipairs(corners) do
			local found

			found = nil
			for y=seed.mins.y,seed.maxs.y do
				if map.tiles[corner.x][y].seed then
					found = true
					break
				end
			end
			if not found then
				for y=seed.mins.y,seed.maxs.y do
					map.tiles[corner.x][y].seed = seed
				end
				seedcorners[i].x = corner.x
				modified = true
			end

			found = nil
			for x=seed.mins.x,seed.maxs.x do
				if map.tiles[x][corner.y].seed then
					found = true
					break
				end
			end
			if not found then
				for x=seed.mins.x,seed.maxs.x do
					map.tiles[x][corner.y].seed = seed
				end
				seedcorners[i].y = corner.y
				modified = true
			end
		end
	end
until not modified

for _,seed in ipairs(seeds) do
	local size = seed.maxs - seed.mins - 1
	if size.x < 1 then size.x = 1 end
	if size.y < 1 then size.y = 1 end
	local wall = vec2(
		math.random(size.x) + seed.mins.x,
		math.random(size.y) + seed.mins.y)

	if seed.mins.y > 1 then
		for x=seed.mins.x,seed.maxs.x do
			if x ~= wall.x then
				map.tiles[x][seed.mins.y].type = tiletypes.wall
			end
		end
	end
	if seed.mins.x > 1 then
		for y=seed.mins.y,seed.maxs.y do
			if y ~= wall.y then
				map.tiles[seed.mins.x][y].type = tiletypes.wall
			end
		end
	end
end

for x=1,map.size.x do
	for y=1,map.size.y do
		map.tiles[x][y].seed = nil
	end
end
