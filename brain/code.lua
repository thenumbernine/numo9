local dirvec = {
	[0] = {0,-1},
	[1] = {0,1},
	[2] = {-1,0},
	[3] = {1,0},
}

youWon = nil
flagshift=table{
	'solid',	-- 1
	'push',		-- 2
	'btn',		-- is a button
	
	-- meh I'm not sure this is a good idea
	'pushdups',	-- push will duplicate the block
				--  pushdups | solid means if you push it then a new copy comes out in front and you stand still
				--  pushdups | ~solid means if you push it then you move and a new copy appears under you
}:mapi([k,i] (i-1,k)):setmetatable(nil)
flags=table(flagshift):map([v] 1<<v):setmetatable(nil)
trace(getfenv(0).require 'ext.tolua'(flagshift))
trace(getfenv(0).require 'ext.tolua'(flags))

mapTypes=table{
	[0]={name='empty'},				-- empty
	[1]={name='solid',flags=flags.solid},	-- solid
	[2]={name='push',flags=flags.solid|flags.push},	-- push
	[3]={name='idle',flags=flags.push |flags.solid},--|flags.pushdups},
	[4]={name='firing',flags=flags.push |flags.solid},--|flags.pushdups},
	[5]={name='waiting',flags=flags.push |flags.solid},--|flags.pushdups},
	[6]={name='btn0', flags=flags.btn|flags.solid|flags.push},
	[7]={name='btn1', flags=flags.btn|flags.solid|flags.push},
	[8]={name='btn2', flags=flags.btn|flags.solid|flags.push},
	[9]={name='btn3', flags=flags.btn|flags.solid|flags.push},
	[10]={name='btn4', flags=flags.btn|flags.solid|flags.push},
	[11]={name='btn5', flags=flags.btn|flags.solid|flags.push},
	[12]={name='btn6', flags=flags.btn|flags.solid|flags.push},
	[13]={name='btn7', flags=flags.btn|flags.solid|flags.push},
	[32]={name='trigger_player', flags=flags.solid|flags.push},
	[33]={name='trigger_reset', flags=flags.solid|flags.push},
	[34]={name='trigger_goal', flags=flags.solid|flags.push},
	
	-- clear tile command seems dumb
	[35]={name='trigger_clear', flags=flags.solid|flags.push},
}
for k,v in pairs(mapTypes) do 
	v.value = k 
	v.flags ??= 0 
end
mapTypeForName = mapTypes:map([v,k] (v, v.name))

--#include ext/class.lua

objs=table()

Object=class()
Object.init=[:,args]do
	for k,v in pairs(args) do self[k]=v end
	objs:insert(self)
end
Object.update=[:]do
	spr(self.sprite, self.x<<3, self.y<<3)
end

testMove=[x,y,dx,dy]do
	local nx,ny = x + dx, y + dy
	if nx < 0 or nx >= 32 or ny < 0 or ny >= 32 then return end
	local ti = mget(nx,ny)
	local t = mapTypes[ti]
	if t.flags & flags.push ~= 0 then	-- pushable
		-- test move in dir again ...
		local bx, by = testMove(nx, ny, dx, dy)
		if bx and by then
			local t2 = mget(bx, by)
			-- only push onto empty tiles for now
			if t2 == 0 then
				mset(bx, by, ti)
				-- if our pushable isn't flagged to duplicate
				if t.flags & flags.pushdups == 0 then
					mset(nx, ny, 0)	-- or whatever is underneath
				end
				t = mapTypes[mget(nx,ny)]	-- allow the previous thing to move onto this
			end
		end
	end
	if t.flags & flags.solid ~= 0 then
		return 	-- blocked
	end
	return nx, ny
end

Player=Object:subclass()
Player.sprite=1
Player.update=[:]do
	Player.super.update(self)

	local dx,dy = self.dx, self.dy
	if dx and dy and (dx ~= 0 or dy ~= 0) then
		local nx,ny = testMove(self.x, self.y, dx, dy)
		if nx and ny then
			self.x, self.y = nx, ny
		end
	end

	self.dx, self.dy = 0,0 

-- [[ hmm seems dumb
	if self.clear then
		mset(self.x, self.y, mapTypeForName.empty.value)
	end
	self.clear = nil
--]]
end

-- init backup
for y=0,31 do
	for x=0,31 do
		mset(32+x,32+y,mget(x,y))
	end
end
reset=[]do
	youWon = nil
	objs=table()
	player=Player{x=16,y=16}
	-- reset from backup
	for y=0,31 do
		for x=0,31 do
			mset(x,y,mget(32+x,32+y))
			mset(x,32+y,mget(32+x,32+y))
		end
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

	-- fire off the buttons
	local fire = 0
	for i=0,7 do
		if btnp(i,0,10,6) then fire |= 1 << i end
	end

	for y=0,31 do
		for x=0,31 do
			local ti = mget(x,y)
			mset(x,32+y,ti)
			local t = mapTypes[ti]
			if ti == mapTypeForName.idle.value 
			or ti == mapTypeForName.trigger_player.value
			or ti == mapTypeForName.trigger_reset.value
			or ti == mapTypeForName.trigger_goal.value
			or ti == mapTypeForName.trigger_clear.value
			then
				for side=0,3 do
					local dx,dy = table.unpack(dirvec[side])
					local nx = x + dx
					local ny = y + dy
					if nx >= 0 and nx < 32
					and ny >= 0 and ny < 32
					then
						local ti2 = mget(nx,ny)
						local t2 = mapTypes[ti2]
						if ti2 == mapTypeForName.firing.value 
						or (t2 
							and t2.flags 
							and t2.flags & flags.btn ~= 0
							and fire & (1 << (ti2 - mapTypeForName.btn0.value)) ~= 0
						)
						then
--trace(time()*60, nx, ny, 'idle -> firing')
							if ti == mapTypeForName.idle.value then
								mset(x,32+y,mapTypeForName.firing.value)
							elseif ti == mapTypeForName.trigger_player.value then
								player.dx, player.dy = dx, dy
							elseif ti == mapTypeForName.trigger_reset.value then
								-- reset level ... somehow ...
								reset()
							elseif ti == mapTypeForName.trigger_goal.value then
								youWon = true
							elseif ti == mapTypeForName.trigger_clear.value then
								player.clear = true
							end
						end
					end
				end
			end
			if ti == mapTypeForName.firing.value then
--trace(time()*60, x, y, 'firing -> waiting')
				mset(x,32+y,mapTypeForName.waiting.value)
			end
			if ti == mapTypeForName.waiting.value then
--trace(time()*60, x, y, 'waiting -> idle')
				mset(x,32+y,mapTypeForName.idle.value)
			end
		end
	end
	for y=0,31 do
		for x=0,31 do
			mset(x,y,mget(x,32+y))
		end
	end
end
reset()
