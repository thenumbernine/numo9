local dirvec = {
	[0] = {0,-1},
	[1] = {0,1},
	[2] = {-1,0},
	[3] = {1,0},
}

youWon = false
flagshift=table{
	'solid',	-- 1
}:mapi([k,i] (i-1,k)):setmetatable(nil)
flags=table(flagshift):map([v] 1<<v):setmetatable(nil)
trace(getfenv(0).require 'ext.tolua'(flagshift))
trace(getfenv(0).require 'ext.tolua'(flags))

mapTypes=table{
	[0]={name='empty'},				-- empty
	[1]={name='solid',flags=flags.solid},	-- solid
	[2]={name='chest',flags=flags.solid},
	[3]={name='chest_open',flags=flags.solid},
	[32]={name='spawn_player'},
}
for k,v in pairs(mapTypes) do 
	v.index = k 
	v.flags ??= 0 
end
mapTypeForName = mapTypes:map([v,k] (v, v.name))

new=[cl,...]do
	local o=setmetatable({},cl)
	return o, o?:init(...)
end
isa=[cl,o]o.isaSet[cl]
classmeta = {__call=new}
class=[...]do
	local t=table(...)
	t.super=...
	t.__index=t
	t.subclass=class
	t.isaSet=table(table{...}:mapi([cl]cl.isaSet):unpack()):setmetatable(nil)
	t.isaSet[t]=true
	t.isa=isa
	setmetatable(t,classmeta)
	return t
end

objs=table()

Object=class()
Object.bbox = {min={x=-.3, y=-.3}, max={x=.3, y=.3}}
Object.init=[:,args]do
	for k,v in pairs(args) do self[k]=v end
	objs:insert(self)
end
Object.update=[:]do
	spr(self.sprite, (self.x + self.bbox.min.x)*8, (self.y + self.bbox.min.y)*8)
end

local mapwidth = 256
local mapheight = 256

Player=Object:subclass()
Player.sprite=0
Player.update=[:]do
	Player.super.update(self)

	local speed = .1
	for bi=0,1 do	-- move horz then vert, so we can slide on walls or something
		local dx,dy = 0, 0
		if bi == 0 then
			if btn(0) then dy -= speed end
			if btn(1) then dy += speed end
		elseif bi == 1 then
			if btn(2) then dx -= speed end
			if btn(3) then dx += speed end
		end
		if dx ~= 0 or dy ~= 0 then
			local nx = self.x + dx
			local ny = self.y + dy
			local px1 = nx + self.bbox.min.x
			local py1 = ny + self.bbox.min.y
			local px2 = nx + self.bbox.max.x
			local py2 = ny + self.bbox.max.y
			local hit
			for by1=math.clamp(math.floor(py1), 0, mapheight-1), math.clamp(math.ceil(py2), 0, mapheight-1) do
				for bx1=math.clamp(math.floor(px1), 0, mapwidth-1), math.clamp(math.ceil(px2), 0, mapwidth-1) do
					local bx2, by2 = bx1 + 1, by1 + 1
					local ti = mget(bx1, by1)
					local t = mapTypes[ti]
					if t
					and px2 >= bx1 and px1 <= bx2
					and py2 >= by1 and py1 <= by2
					then
						-- do map hit
						if t.flags & flags.solid ~= 0 then
							hit = true
						end
						-- TODO per mapType
						if ti == mapTypeForName.chest.index then
							mset(bx1, by1, mapTypeForName.chest_open.index)
						end
					end
				end
			end
::doneTestingBoxes::
			if not hit then
				self.x, self.y = nx, ny
				-- TODO bomberman slide ... if you push down at a corner then push player left/right to go around it ...
			end
		end
	end
end

init=[]do
	reset()	-- reset rom
	youWon = false
	objs=table()
	player = nil
	for y=0,255 do
		for x=0,255 do
			if mget(x,y) == mapTypeForName.spawn_player.index then
				player = Player{x=x+.5, y=y+.5}
				mset(x,y,0)
			end
		end
	end
	if not player then
		trace"WARNING! dind't spawn player"
	end
end

update=[]do
	cls()
	map(0,0,32,32,0,0)
	
	if youWon then
		text('you won!', 16,16)
		return
	end

	for _,o in ipairs(objs) do
		o:update()
	end

end
init()

