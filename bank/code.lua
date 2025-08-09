-- title = Bank
-- saveid = bank
-- author = Chris Moore
-- description = Bank - collect all the money and get the key to escape!
-- disableMultiplayer = true
-- editTilemap.gridSpacing = 10
-- editTilemap.draw16Sprites = true

----------------------- BEGIN ext/range.lua-----------------------
local range=|a,b,c|do
	local t = table()
	if c then
		for x=a,b,c do t:insert(x) end
	elseif b then
		for x=a,b do t:insert(x) end
	else
		for x=1,a do t:insert(x) end
	end
	return t
end

----------------------- END ext/range.lua  -----------------------
----------------------- BEGIN ext/class.lua-----------------------
local isa=|cl,o|o.isaSet[cl]
local classmeta = {__call=|cl,...|do
	local o=setmetatable({},cl)
	return o, o?:init(...)
end}
local class
class=|...|do
	local t=table(...)
	t.super=...
	--t.supers=table{...}
	t.__index=t
	t.subclass=class
	t.isaSet=table(table{...}
		:mapi(|cl|cl.isaSet)
		:unpack()
	):setmetatable(nil)
	t.isaSet[t]=true
	t.isa=isa
	setmetatable(t,classmeta)
	return t
end

----------------------- END ext/class.lua  -----------------------
----------------------- BEGIN vec/vec2.lua-----------------------

local vec2_getvalue=|x, dim|do
	if type(x) == 'number' then return x end
	if type(x) == 'table' then
		if dim==1 then
			x=x.x
		elseif dim==2 then
			x=x.y
		else
			x=nil
		end
		if type(x)~='number' then
			error("expected a table of numbers, got a table with index "..dim.." of "..type(x))
		end
		return x
	end
	error("tried to vec2_getvalue from an unknown type "..type(x))
end

local vec2
vec2=class{
	fields = table{'x', 'y'},
	init=|v,x,y|do
		if x then
			if y then
				v:set(x,y)
			else
				v:set(x,x)
			end
		else
			v:set(0,0)
		end
	end,
	clone=|v| vec2(v),
	set=|v,x,y|do
		if type(x) == 'table' then
			v.x = x.x or x[1] or error("idk")
			v.y = x.y or x[2] or error("idk")
		else
			assert(x, "idk")
			v.x = x
			if y then
				v.y = y
			else
				v.y = x
			end
		end
	end,
	unpack=|v|(v.x, v.y),
	sum=|v| v.x + v.y,
	product=|v| v.x * v.y,
	clamp=|v,a,b|do
		local mins = a
		local maxs = b
		if type(a) == 'table' and a.min and a.max then
			mins = a.min
			maxs = a.max
		end
		v.x = math.clamp(v.x, vec2_getvalue(mins, 1), vec2_getvalue(maxs, 1))
		v.y = math.clamp(v.y, vec2_getvalue(mins, 2), vec2_getvalue(maxs, 2))
		return v
	end,
	map=|v,f|do
		v.x = f(v.x, 1)
		v.y = f(v.y, 2)
		return v
	end,
	floor=|v|v:map(math.floor),
	ceil=|v|v:map(math.ceil),
	l1Length=|v| math.abs(v.x) + math.abs(v.y),
	lInfLength=|v| math.max(math.abs(v.x), math.abs(v.y)),
	dot=|a,b| a.x * b.x + a.y * b.y,
	lenSq=|v| v:dot(v),
	len=|v| math.sqrt(v:lenSq()),
	distSq = |a,b| ((a.x-b.x)^2 + (a.y-b.y)^2),
	unit=|v| v / math.max(1e-15, v:len()),
	exp=|theta| vec2(math.cos(theta), math.sin(theta)),
	cross=|a,b| a.x * b.y - a.y * b.x,	-- or :det() maybe
	cplxmul = |a,b| vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x),
	__unm=|v| vec2(-v.x, -v.y),
	__add=|a,b| vec2(vec2_getvalue(a, 1) + vec2_getvalue(b, 1), vec2_getvalue(a, 2) + vec2_getvalue(b, 2)),
	__sub=|a,b| vec2(vec2_getvalue(a, 1) - vec2_getvalue(b, 1), vec2_getvalue(a, 2) - vec2_getvalue(b, 2)),
	__mul=|a,b| vec2(vec2_getvalue(a, 1) * vec2_getvalue(b, 1), vec2_getvalue(a, 2) * vec2_getvalue(b, 2)),
	__div=|a,b| vec2(vec2_getvalue(a, 1) / vec2_getvalue(b, 1), vec2_getvalue(a, 2) / vec2_getvalue(b, 2)),
	__eq=|a,b| a.x == b.x and a.y == b.y,
	__tostring=|v| v.x..','..v.y,
	__concat=string.concat,
}

-- TODO order this like buttons ... right down left up ... so it's related to bitflags and so it follows exp map angle ...
-- tempting to do right left down up, i.e. x+ x- y+ y-, because that extends dimensions better
-- but as it is this way, we are 1:1 with the exponential-map, so there.
local dirvecs = table{
	[0] = vec2(1,0),
	[1] = vec2(0,1),
	[2] = vec2(-1,0),
	[3] = vec2(0,-1),
}
local opposite = {[0]=2,3,0,1}	-- opposite = [x]x~2
local dirForName = {right=0, down=1, left=2, up=3}

----------------------- END vec/vec2.lua  -----------------------

videoModeIndex=0	screenSize=vec2(256, 256)	-- 256x256xRGB565
mode(videoModeIndex)
--cheat=true

_G=getfenv(1)	-- needed for :: operator

levelstr='level ?'

sfxid={
	bomb_explode = 0,
	collect_money = 1,
	laser_shoot = 2,
	step = 3,	-- and drop bomb
	menuchange = 4,
	getkey = 5,
	death = 6,
}

EMPTY=0
TREE=2
BRICK=4
STONE=6
WATER=8
ARROW_RIGHT=20
ARROW_DOWN=22
ARROW_LEFT=24
ARROW_UP=26
MOVING_RIGHT=84
MOVING_DOWN=86
MOVING_LEFT=88
MOVING_UP=90
-- used for rendering but not for storage in map
-- TODO if someone does write this to a map, should the loadLevel() rewrite it as WATER?
WATER_BANK_ANIM_1 = 198
WATER_BANK_ANIM_2 = WATER_BANK_ANIM_1 + 2
WATER_ANIM_1 = WATER_BANK_ANIM_1 + 32*2
WATER_ANIM_2 = WATER_ANIM_1 + 2

mapTypes={
	[EMPTY] = {},
	[TREE] = {cannotPassThru=true, drawGroundUnder=true},
	[BRICK] = {cannotPassThru=true, blocksGunShot=true, blocksExplosion=true, bombable=true},
	[STONE] = {cannotPassThru=true, blocksGunShot=true, blocksExplosion=true},
	[WATER] = {cannotPassThru=true},
	[ARROW_RIGHT] = {},
	[ARROW_DOWN] = {},
	[ARROW_LEFT] = {},
	[ARROW_UP] = {},
	[MOVING_RIGHT] = {},
	[MOVING_DOWN] = {},
	[MOVING_LEFT] = {},
	[MOVING_UP] = {},
}

corners = table{
	UL = vec2(-1, -1),
	UR = vec2(1, -1),
	LL = vec2(-1, 1),
	LR = vec2(1, 1),
}

getCornerTypes = |where|
	corners:map(|ofs,name|
		(mapGet(where.x + ofs.x * .25, where.y + ofs.y * .25), name)
	)

dirForName.none = -1
seqs={
	cloud=128,
	brick=74,	-- irl? why not just the tilemap?
	spark=132,	-- TODO color this red or something
	bomb=64,
	bombLit=66,
	bombSunk=68,
	money=198,
	key=142,
	keyGrey=192,
	gun=194,
	gunMad=196,
	sentry=200,
	sentry=202,
	framer=136,
	playerStandDown=256,
	playerStandDown2=258,
	playerStandLeft=260,
	playerStandLeft2=262,
	playerStandRight=264,
	playerStandRight2=266,
	playerStandUp=268,
	playerStandUp2=270,
	playerDead=206,
}


dt=1/60

tilemapSize = vec2(256, 256)	-- tilemap size
levelSize = vec2(10, 10)
levelsPerSheet = (tilemapSize / levelSize):floor()
assert.eq(levelsPerSheet.x, 25)
assert.eq(levelsPerSheet.y, 25)
maxLevels = levelsPerSheet:product()

-- [[ dynamically drawing the border
-- TODO this is what the Brush menu is supposed to be.
-- TODO to finish the Brush menu you might as well switch the ROM file format to a FAT based one to have dynamic-sizes.
drawMapBorder=||do
	-- middle
	for x=1,levelSize.x+1 do
		for y=2,levelSize.y+1 do
			spr(1024, x*16, y*16, 2, 2)
		end
	end
	-- upper left
	spr(1024+192, 0, (levelSize.y-2), 4, 4)
	-- upper right
	spr(1024+192, (levelSize.x+2)*16, 8, 2, 4, nil, nil, nil, nil, -1, 1)
	-- upper
	for x=2,levelSize.x do
		spr(1024+196, x*16, 8, 2, 4)
	end
	-- left & right
	for y=2,levelSize.x+1 do
		spr(1024+256, 0, y*16, 2, 2)
		spr(1024+256, (levelSize.x+2)*16, y*16, 2, 2, nil, nil, nil, nil, -1, 1)
	end
	-- bottom left
	spr(1024+320, 0, (levelSize.y+2)*16, 2, 2)
	-- bottom right
	spr(1024+320, (levelSize.x+2)*16, (levelSize.y+2)*16, 2, 2, nil, nil, nil, nil, -1, 1)
	-- lower
	for x=1,levelSize.x do
		spr(1024+322, x*16, (levelSize.y+2)*16, 2, 2)
	end
end
--]]

--[[ using map() function, which doesnt support animiations yet ... TODO
drawMap=||
	map(levelTile.x,levelTile.y,levelSize.x,levelSize.y,0,0,0,true)
--]]
-- [[ manually for animation
drawMap=||do
	for y=0,levelSize.y-1 do
		for x=0,levelSize.x-1 do
			local tileIndex = mapGet(x,y)
			if tileIndex == WATER then
				local waterAbove = y > 0
					and mget(levelTile.x+x, levelTile.y+y-1) == WATER
				if waterAbove then
					tileIndex = WATER_ANIM_1
				else
					tileIndex = WATER_BANK_ANIM_1
				end
				if math.floor(time()) & 1 == 1 then tileIndex += 2 end
			end
			spr(1024|tileIndex, x*16, y*16, 2, 2)
		end
	end
end
--]]


objs=table()
addList=table()
addObj=|o|addList:insert(o)
removeObj=|o|do
	o:onRemove() -- set the removeMe flag
	removeRequest=true
end
removeAll=||do
	for _,o in ipairs(objs) do
		o:onRemove()
	end
	objs=table()
	addList=table()
end

classmeta.__index=_G	-- obj __index looks in its class, if not there then looks into global.  This line is needed for :: setfenv(1,self) use.

BaseObj=class{
	init=|::,args|do
		scale=vec2(1,1)
		removeMe=false
		pos=vec2()
		srcPos=vec2()
		destPos=vec2()
		moveCmd=-1
		isBlocking=true
		isBlockingPushers=true
		blocksExplosion=true
	end,
	-- in AnimatedObj in fact ...
	update=|::|nil,
	setPos=|::,p|do
		if not pos then pos = vec2() end
		pos:set(p)
		if not srcPos then srcPos = vec2() end
		srcPos:set(p)
		if not destPos then destPos = vec2() end
		destPos:set(p)
	end,
	drawSprite=|::|do
		-- pos is tile-centered so ...
		local x = pos.x * 16 - 8 * scale.x
		local y = pos.y * 16 - 8 * scale.y
		if blendMode then
			blend(blendMode)
		end
		spr(
			seq,		--spriteIndex,
			x,			--screenX,
			y,			--screenY,
			2,			--spritesWide,
			2,			--spritesHigh,
			nil,		--paletteIndex,
			nil,		--transparentIndex,
			nil,		--spriteBit,
			nil,		--spriteMask,
			scale.x,
			scale.y)
		if blendMode then
			blend()
		end
	end,
	isBlockingSentry=|::|isBlocking,
	hitEdge=|::, where|true,
	cannotPassThru=|::,mapTypeIndex|mapTypes[mapTypeIndex]?.cannotPassThru,
	hitWorld=|::, cmd, where, cornerTypes| do
		if cmd == dirForName.left
		and where.x % 1 == 0
		and (cornerTypes.UL == ARROW_RIGHT or cornerTypes.LL == ARROW_RIGHT) 
		then
			return true
		end
		if cmd == dirForName.up 
		and where.y % 1 == 0 
		and (cornerTypes.UL == ARROW_DOWN or cornerTypes.UR == ARROW_DOWN) 
		then
			return true
		end
		if cmd == dirForName.right 
		and where.x % 1 == 0 
		and (cornerTypes.UR == ARROW_LEFT or cornerTypes.LR == ARROW_LEFT) 
		then
			return true
		end
		if cmd == dirForName.down 
		and where.y % 1 == 0 
		and (cornerTypes.LL == ARROW_UP or cornerTypes.LR == ARROW_UP) 
		then
			return true
		end
		return self:cannotPassThru(cornerTypes.UL)
			or self:cannotPassThru(cornerTypes.UR)
			or self:cannotPassThru(cornerTypes.LL)
			or self:cannotPassThru(cornerTypes.LR)
	end,
	hitObject=|::, what, pushDest, side| 'test object',
	startPush=|::, pusher, pushDest, side| isBlocking,
	endPush=|::, who, pushDest| nil,
	onKeyTouch=|::|nil,
	onTouchFlames=|::|nil,
	onGroundSunk=|::|removeObj(self),
	onRemove=|::|do self.removeMe=true end,
}

do
	local super=BaseObj
	MovableObj=BaseObj:subclass{
		init=|:,args|do
			super.init(self,args)
			self.lastMoveResponse='no move'
			self.moveCmd=dirForName.none
			self.speed=10
			self.moveFracMoving=false
			self.moveFrac=0
		end,
		moveIsBlocked_CheckHitWorld=|:, cmd, where| do
			local cornerTypes = getCornerTypes(where)
			return self:hitWorld(cmd, where, cornerTypes)
		end,
		hitWorld=|:, cmd, where, cornerTypes| do
			local cornerTypes = table(cornerTypes)
			for _,o in ipairs(objs) do
				if not o.removeMe
				and o~=self
				and Bomb:isa(o)
				and o.state=='sinking'
				then
					for key, corner in pairs(corners) do
						if cornerTypes[key] == WATER and (where + corner * .25 - o.destPos):lInfLength() <.5 then
							cornerTypes[key] = EMPTY
						end
					end
				end
			end
			return super.hitWorld(self, cmd, where, cornerTypes)
		end,
		moveIsBlocked_CheckEdge=|:,newDest|do
			if newDest.x < .25
			or newDest.y < .25
			or newDest.x > levelSize.x - .25
			or newDest.y > levelSize.y - .25
			then
				return self:hitEdge(newDest)
			end
			return false
		end,
		moveIsBlocked_CheckHitObject=|:, o, cmd, newDest|do
			if (o.destPos - newDest):lInfLength() > .75 then return false end
			local response=self:hitObject(o, newDest, cmd)
			if response=='stop' then return true end
			if response=='test object' then
				if o:startPush(self, newDest, cmd) then return true end
			end
			return false
		end,
		moveIsBlocked_CheckHitObjects=|:, cmd, newDest|do
			for _,o in ipairs(objs) do
				if not o.removeMe
				and o ~= self
				and self:moveIsBlocked_CheckHitObject(o, cmd, newDest) then
					return true
				end
			end
		end,
		moveIsBlocked=|:,cmd,newDest|do
			return self:moveIsBlocked_CheckEdge(newDest)
			or self:moveIsBlocked_CheckHitWorld(cmd, newDest)
			or self:moveIsBlocked_CheckHitObjects(cmd, newDest)
		end,
		doMove=|:,cmd|do
			if cmd==dirForName.none then return 'no move' end
			local newDest = self.pos:clone()
			if cmd >= 0 and cmd < 4 then
				newDest += dirvecs[cmd] * .5
			else
				return 'no move'
			end
			if self:moveIsBlocked(cmd, newDest) then
				self.moveFracMoving=false
				return 'was blocked'
			end
			self.destPos:set(newDest)
			self.moveFrac=0
			self.moveFracMoving=true
			self.srcPos:set(self.pos)
			return 'did move'
		end,
		update=|:|do
			if not self.dead then
				if (time() * 60) % 30 == 0 then
					local cornerTypes = getCornerTypes(self.destPos)
					-- TODO merge this move and btn move so we dont double move in one update ... or not?
					-- TODO :move but withotu changing animation direction ...
					if cornerTypes.UL == MOVING_RIGHT and cornerTypes.LL == MOVING_RIGHT then
						self:checkMoveCmd(dirForName.right)
					elseif cornerTypes.UL == MOVING_DOWN and cornerTypes.UR == MOVING_DOWN then
						self:checkMoveCmd(dirForName.down)
					elseif cornerTypes.UR == MOVING_LEFT and cornerTypes.LR == MOVING_LEFT then
						self:checkMoveCmd(dirForName.left)
					elseif cornerTypes.LL == MOVING_UP and cornerTypes.LR == MOVING_UP then
						self:checkMoveCmd(dirForName.up)
					end
				end
			end

			super.update(self)
			if self.moveFracMoving then
				self.moveFrac+=dt*self.speed
				if self.moveFrac>=1 then
					self.moveFracMoving=false
					self.pos:set(self.destPos)
					for _,o in ipairs(objs) do
						if not o.removeMe
						and o ~= self
						and (o.destPos - self.destPos):lInfLength() <= .75
						then
							o:endPush(self, self.destPos)
						end
					end
				else
					local oneMinusMoveFrac=1 - self.moveFrac
					self.pos = self.destPos * self.moveFrac + self.srcPos * oneMinusMoveFrac
				end
			end

			self:checkMoveCmd(self.moveCmd)
		end,
		checkMoveCmd=|:,moveCmd|do
			if not self.moveFracMoving then
				self.lastMoveResponse=self:doMove(moveCmd)
			else
				self.lastMoveResponse='no move'
			end
		end,
	}
end

do
	local super=MovableObj
	PushableObj=MovableObj:subclass{
		init=|:,args|do
			super.init(self, args)
		end,
		startPush=|:, pusher, pushDest, side|do
			local superResult = super.startPush(self, pusher, pushDest, side)
			if not self.isBlocking then return false end

			local delta=0
			if side==dirForName.left or side==dirForName.right then
				delta=self.destPos.y - pusher.destPos.y
			elseif side==dirForName.up or side==dirForName.down then
				delta=self.destPos.x - pusher.destPos.x
			end
			delta=math.abs(delta)
			local align=delta<.25

			if align and not self.moveFracMoving then
				local moveResponse=self:doMove(side)
				if moveResponse=='did move' then return false end
				if moveResponse=='was blocked' then return true end
			end
			return superResult
		end,
		hitObject=|:, what, pushDest, side|do
			if what.isBlockingPushers then return 'stop' end
			return super.hitObject(self, what, pushDest, side)
		end,
	}
end

do
	local super=BaseObj
	Cloud=BaseObj:subclass{
		init=|:,args|do
			super.init(self,args)
			self.isBlocking=false
			self.isBlockingPushers=false
			self.blocksExplosion=false
			self.blendMode=1
			self.vel = vec2(args.vel)
			self.life=args.life
			self.scale:set(args.scale)
			self:setPos(args.pos)
			self.startTime=time()
			self.seq=seqs.cloud
		end,
		update=|:|do
			super.update(self)
			self:setPos(self.pos + dt * self.vel)
			local frac=math.min(1,(time()-self.startTime)/self.life)
			if frac==1 then
				removeObj(self)
				return
			end
		end,
	}
end

do
	local super=BaseObj
	Particle=BaseObj:subclass{
		init=|:,args|do
			self.isBlocking=false
			self.isBlockingPushers=false
			self.blocksExplosion=false
			self.vel = vec2(args.vel)
			self.life=args.life
			self.scale = vec2(args.radius*2)
			self:setPos(args!.pos)
			self.startTime=time()
			self.seq=args.seq or seqs.spark
			self.blendMode=args.blendMode or 0
		end,
		update=|:|do
			super.update(self)
			self:setPos(self.pos + dt * self.vel)
			local frac=math.max(0,1-(time()-self.startTime)/self.life)
			if frac==0 then
				removeObj(self)
				return
			end
		end,
	}
end

do
	local super=PushableObj
	Bomb=PushableObj:subclass{
		init=|:,owner|do
			super.init(self,{})
			-- class constants / defaults:
			self.boomTime = 0
			self.blastRadius = 1
			self.explodingDone = 0
			self.sinkDone = 0
			self.fuseDuration = 5
			self.chainDuration = .2
			self.explodingDuration = .2
			self.sinkDuration = 5
			self.throwDuration = 1
			--
			self.owner=nil
			self.ownerStandingOn=false
			self.state='idle'
			self.owner=owner
			if owner then self.ownerStandingOn=true end
			self.seq=seqs.bomb
		end,
		hitObject=|:, whatWasHit, pushDest, side|do
			if whatWasHit==self.owner
			and self.owner
			and self.ownerStandingOn
			then
				return 'move thru'
			end
			return super.hitObject(self, whatWasHit, pushDest, side)
		end,
		startPush=|:, pusher, pushDest, side|do
			if pusher==self.owner
			and self.owner
			and self.ownerStandingOn
			then
				return false
			end
			return super.startPush(self, pusher, pushDest, side)
		end,
		setFuse=|:,fuseTime|do
			if self.state=='exploding'
			or self.state=='sinking'
			then
				return
			end
			self.seq=seqs.bombLit
			self.state='live'
			self.boomTime=time()+fuseTime
		end,
		cannotPassThru=|:,mapTypeIndex|do
			local res=super.cannotPassThru(self,mapTypeIndex)
			if not res then return false end
			return mapTypeIndex~=WATER
		end,
		drawSprite=|:,c,rect|do
			super.drawSprite(self,c,rect)
			if self.state=='idle'
			or self.state=='live'
			then
				if self.blendMode then blend(self.blendMode) end
				spr(384+self.blastRadius,
					16*self.pos.x-4,
					16*self.pos.y-4,
					1,
					1,
					nil,
					nil,
					nil,
					nil
				)
				if self.blendMode then blend() end
			end
		end,
		onKeyTouch=|:|removeObj(self),
		update=|:|do
			super.update(self)
			if self.owner
			and self.ownerStandingOn
			then
				if (self.destPos - self.owner.destPos):lInfLength() > .75
				then
					self.ownerStandingOn=false
				end
			end

			if self.state=='idle'
			or self.state=='live'
			then
				if not self.moveFracMoving then
					local cornerTypes = getCornerTypes(self.destPos)

					for _,o in ipairs(objs)do
						if not removeMe
						and Bomb:isa(o)
						and o.state=='sinking'
						then
							if cornerTypes.UL==WATER and (self.destPos + vec2(-.25,-.25) - o.destPos):lInfLength() < .5 then cornerTypes.UL=EMPTY end
							if cornerTypes.UR==WATER and (self.destPos + vec2( .25,-.25) - o.destPos):lInfLength() < .5 then cornerTypes.UR=EMPTY end
							if cornerTypes.LL==WATER and (self.destPos + vec2(-.25, .25) - o.destPos):lInfLength() < .5 then cornerTypes.LL=EMPTY end
							if cornerTypes.LR==WATER and (self.destPos + vec2( .25, .25) - o.destPos):lInfLength() < .5 then cornerTypes.LR=EMPTY end
						end
					end

					if cornerTypes.UL==WATER
					and cornerTypes.UR==WATER
					and cornerTypes.LL==WATER
					and cornerTypes.LR==WATER
					then
						self.seq=seqs.bombSunk
						self.state='sinking'
						self.isBlocking=false
						self.isBlockingPushers=false
						self.sinkDone=time() + self.sinkDuration
					end
				end
			end

			if self.state=='live' then
				local t=time()-self.boomTime
				local s=math.cos(2*t*math.pi)*.2+.9
				self.scale:set(s)
				if t>=0 then
					self:explode()
				end
			elseif self.state=='exploding' then
				local t=time()-self.explodingDone
				if t>=0 then
					removeObj(self)
				end
			elseif self.state=='sinking' then
				local t=time()-self.sinkDone
				if t>=0 then
					removeObj(self)
					for _,o in ipairs(objs)do
						if not o.removeMe
						and (o.destPos - self.destPos):lInfLength() < .75
						then
							local cornerTypes = getCornerTypes(o.destPos)

							for _,o2 in ipairs(objs)do
								if not o2.removeMe
								and Bomb:isa(o2)
								and o2.state=='sinking'
								then
									if cornerTypes.UL==WATER and (o.destPos + vec2(-.25,-.25) - o2.destPos):lInfLength() < .5 then cornerTypes.UL=EMPTY end
									if cornerTypes.UR==WATER and (o.destPos + vec2( .25,-.25) - o2.destPos):lInfLength() < .5 then cornerTypes.UR=EMPTY end
									if cornerTypes.LL==WATER and (o.destPos + vec2(-.25, .25) - o2.destPos):lInfLength() < .5 then cornerTypes.LL=EMPTY end
									if cornerTypes.LR==WATER and (o.destPos + vec2( .25, .25) - o2.destPos):lInfLength() < .5 then cornerTypes.LR=EMPTY end
								end
							end

							if cornerTypes.UL==WATER
							and cornerTypes.UR==WATER
							and cornerTypes.LL==WATER
							and cornerTypes.LR==WATER
							then
								o:onGroundSunk()
							end
						end
					end
				end
			end
		end,
		onGroundSunk=|:|nil,
		onTouchFlames=|:|self:setFuse(self.chainDuration),
		explode=|:|do
			for i=0,9 do
				local scale=math.random()*2
				addObj(Cloud{
					pos=self.pos,
					vel = vec2(math.random(), math.random())*2-1,
					scale = scale + 1,
					-- TODO blending ...
					--life=5-scale,
					-- until then ...
					life=(5-scale)/5,
				})
			end

			local cantHitWorld=false
			local fpart=self.destPos - self.destPos:clone():floor()
			if fpart.x<.25 or fpart.x>.75
			or fpart.y<.25 or fpart.y>.75
			then
				cantHitWorld=true
			end

			for side=0,3 do
				local checkPos = self.destPos:clone()
				local len=0
				while true do
					local hit=false
					for _,o in ipairs(objs)do
						if not o.removeMe
						and o~=self
						then
							local dist = (o.destPos - checkPos):lInfLength()
							local safeDist = Player:isa(o) and .75 or .25
							if dist <= safeDist then
								o:onTouchFlames()
								if o.blocksExplosion then
									hit=true
									break
								end
							end
						end
					end

					self:makeSpark(checkPos.x, checkPos.y)

					if hit then break end
					len+=1
					if len>self.blastRadius then
						len=self.blastRadius
						break
					end

					checkPos += dirvecs[side]

					if checkPos.x < 0
					or checkPos.y < 0
					or checkPos.x >= levelSize.x
					or checkPos.y >= levelSize.y
					then break end

					local wallStopped=false
					for ofx=0,1 do
						for ofy=0,1 do
							local cf = (checkPos + vec2(ofx, ofy) * .5 - .25):floor()
							local mt=mapTypes[mapGet(cf.x, cf.y)]
							if mt and mt.blocksExplosion then
								if not cantHitWorld
								and mt.bombable
								then
									local divs=1
									for u=0,divs-1 do
										for v=0,divs-1 do
											local speed=0
											addObj(Particle{
												vel = (vec2(math.random(), math.random()) * 2 - 1) * speed,
												pos = cf + (vec2(u,v)+.5)/divs,
												life=math.random()*.5+.5,
												radius=.5,
												seq=seqs.brick,
												blendMode=0,
											})
										end
									end
									mapSet(cf.x, cf.y, EMPTY)
								end
								wallStopped=true
							end
						end
					end
					if wallStopped then break end
				end
			end

			sfx(sfxid.bomb_explode)
			self.state='exploding'
			self.explodingDone=time()+self.explodingDuration
		end,
		makeSpark=|:,x,y|do
			for i=0,2 do
				local c=math.random()
				addObj(Particle{
					vel = vec2(math.random(), math.random())*2-1,
					pos = vec2(x,y),
					life=.5 * (math.random() * .5 + .5),
					radius=.25 * (math.random() + .5),
					blendMode=0,
				})
			end
		end,
	}
end

do
	local super=MovableObj
	GunShot=MovableObj:subclass{
		init=|:,owner|do
			self.owner=owner
			self:setPos(owner.pos)
			self.seq=-1	--invis
			sfx(sfxid.laser_shoot)
		end,
		cannotPassThru=|:,mapTypeIndex|mapTypes![mapTypeIndex].blocksGunShot,
		hitObject=|:, what, pushDest, side|do
			if what==self.owner then return 'move thru' end
			if Player:isa(what) then
				what:die()
				return 'stop'
			end
			if what.isBlocking or Money:isa(what) then return 'stop' end
			return 'move thru'
		end,
	}
end

do
	local super=BaseObj
	Gun=BaseObj:subclass{
		MAD_DIST=.75,
		FIRE_DIST=.25,
		init=|:|do
			super.init(self,{})
			self.seq=seqs.gun
		end,
		update=|:|do
			super.update(self)

			self.seq=seqs.gun

			if player and not player.dead then
				local diff = player.pos - self.pos
				local absDiff = diff:clone():map(math.abs)
				local dist = math.min(absDiff:unpack())

				if dist < self.MAD_DIST then
					self.seq=seqs.gunMad
				end

				if dist<self.FIRE_DIST then
					local dir = dirForName.none
					if diff.x < diff.y then	-- left or down
						if diff.x < -diff.y then
							dir = dirForName.left
						else
							dir = dirForName.down
						end
					else	-- up or right
						if diff.x < -diff.y then
							dir = dirForName.up
						else
							dir = dirForName.right
						end
					end

					local shot = GunShot(self)
					local response = -1
					repeat
						response = shot:doMove(dir)
						shot:setPos(shot.destPos)
					until response=='was blocked'
					--delete ... but it's not attached, so we're safe
				end
			end
		end,
		onKeyTouch=|:|do	--puff
			removeObj(self)
		end,
	}
end

do
	local super=MovableObj
	Sentry=MovableObj:subclass{
		init=|:|do
			super.init(self,{})
			self.dir = dirForName.left
			self.seq=seqs.sentry
		end,
		update=|:|do
			self.scale.x = (math.floor((time() * 4) & 1) << 1) - 1
			--if the player moved onto us ...
			--TODO - put self inside 'endPush' instead! no need to call it each frame
			if (self.destPos - player.destPos):lInfLength() < .75 then
				player:die()
			end
			self.moveCmd = self.dir
			super.update(self)
			if self.lastMoveResponse=='was blocked' then
				if self.dir==dirForName.up then
					self.dir=dirForName.left
				elseif self.dir==dirForName.left then
					self.dir=dirForName.down
				elseif self.dir==dirForName.down then
					self.dir=dirForName.right
				elseif self.dir==dirForName.right then
					self.dir=dirForName.up
				end
			end
		end,

		--the sentry tried to move and hit an object...
		hitObject=|:, what, pushDest, side|do
			if Player:isa(what) then
				return 'move thru'	--wait for the update() test to pick up hitting the player
			end
			return what:isBlockingSentry() and 'stop' or 'test object'
			--return superHitObject(self, what, pushDest, side)
		end,

		onKeyTouch=|:|do
			--puff
			removeObj(self)
		end,
	}
end

do
	local super=PushableObj
	Framer=PushableObj:subclass{
		init=|:|do
			super.init(self,{})
			self.seq=seqs.framer
		end,
	}
end

do
	local super=MovableObj
	Player=MovableObj:subclass{
		init=|:,args|do
			super.init(self,args)
			self.dead=false
			self.deadTime=0
			self.dir=dirForName.down
			self.bombs=0
			self.bombBlastRadius=1
			self.seq=seqs.playerStandDown
		end,
		move=|:,dir|do
			if self.dead then return end
			self.moveCmd=dir
		end,
		dropBomb=|:|do
			if self.dead then return end
			if self.bombs <= 0 then return end
			sfx(sfxid.step)
			local bomb=Bomb(self)
			bomb:setPos(self.destPos)
			if bomb:moveIsBlocked_CheckEdge(self.destPos)
			or bomb:moveIsBlocked_CheckHitWorld(dirForName.none, self.destPos)
			then return end
			for _,o in ipairs(objs) do
				if not o.removeMe
				and Bomb:isa(o)
				and o.owner==self
				and (self.destPos - o.destPos):lInfLength() < .25
				and (o.state=='idle' or o.state=='live')
				then
					return
				end
			end
			self:setBombs(self.bombs-1)
			bomb.blastRadius=self.bombBlastRadius
			bomb:setFuse(bomb.fuseDuration)
			addObj(bomb)
		end,
		stopMoving=|:|do
			self.moveCmd=dirForName.none
		end,
		update=|:|do
			if self.moveCmd~=dirForName.none then self.dir=self.moveCmd end
			super.update(self)
			if not self.dead then
				--if self.moveFracMoving then
				local animstep = self.moveCmd~=dirForName.none and time() % .5 > .25
				if animstep ~= self.lastAnimStep then
					sfx(sfxid.step)
				end
				self.lastAnimStep = animstep
				if self.dir==dirForName.up then
					self.seq = animstep and seqs.playerStandUp2 or seqs.playerStandUp
				elseif self.dir==dirForName.left then
					self.seq = animstep and seqs.playerStandLeft2 or seqs.playerStandLeft
				elseif self.dir==dirForName.right then
					self.seq = animstep and seqs.playerStandRight2 or seqs.playerStandRight
				else
					self.seq = animstep and seqs.playerStandDown2 or seqs.playerStandDown
				end
			end
		end,
		getMoney=|:,money|do
			self:setBombs(self.bombs+money.bombs)
		end,
		onTouchFlames=|:|do self:die()end,
		die=|:|do
			if self.dead then return end
			sfx(sfxid.death)
			self.seq=seqs.playerDead
			self.dead=true
			self.deadTime=time()+2
			self.isBlocking=false
			self.isBlockingPushers=false
			self.blockExplosion=false
			self.moveCmd=dirForName.none
		end,
		onGroundSunk=|:|do self:die()end,
		setBombs=|:,bombs|do
			self.bombs=bombs
		end,
	}
end

do
	local super=BaseObj
	Money=BaseObj:subclass{
		init=|:,args|do
			super.init(self,args)
			self.items=0
			self.bombs=0
			self.isBlocking=false
			self.seq=seqs.money
		end,
		isBlockingSentry=|:|true,
		drawSprite=|:|do
			super.drawSprite(self)

			if self.bombs>0 then
				if self.blendMode then blend(self.blendMode) end
				spr(384+self.bombs,
					16*self.pos.x-4,
					16*self.pos.y-4,
					1,
					1,
					nil,
					nil,
					nil,
					nil
				)
				if self.blendMode then blend() end
			end
		end,

		endPush=|:, who, pushDest|do
			if not Player:isa(who)
			or (pushDest - self.destPos):lInfLength() >= .5
			then return end

			sfx(sfxid.collect_money)
			who:getMoney(self)
			removeObj(self)
			for _,o in ipairs(objs) do
				if Key:isa(o) then o:checkMoney() end
			end
		end,
	}
end

do
	local super=BaseObj
	Key=BaseObj:subclass{
		init=|:,args|do
			super.init(self,args)
			self.changeLevelTime=0
			self.touchToEndLevelDuration=dt
			self.inactive=true
			self.isBlocking=false
			self.blocksExplosion=false
			self.seq=seqs.keyGrey
			self.doFirstCheck=true
		end,
		show=|:|do
			self.inactive=false
			self.seq=seqs.key
		end,

		endPush=|:, who, pushDest|do
			if not Player:isa(who)
			or self.inactive
			or self.changeLevelTime > 0
			or (pushDest - self.destPos):lInfLength() >= .5
			then return end
			self.changeLevelTime = time() + self.touchToEndLevelDuration

			sfx(sfxid.getkey)
			for _,o in ipairs(objs) do
				if not o.removeMe then o:onKeyTouch() end
			end

			if player then
				player:setBombs(0)
			end
		end,

		update=|:|do
			super.update(self)

			if self.changeLevelTime > 0
			and self.changeLevelTime < time()
			then
				if not player.dead then
					nextLevel()
				end
			end

			if self.doFirstCheck then
				self.doFirstCheck = false
				self:checkMoney()
			end
		end,

		checkMoney=|:|do
			local moneyleft = 0
			for _,o in ipairs(objs) do
				if not o.removeMe
				and Money:isa(o)
				then
					moneyleft+=1
				end
			end
			if moneyleft==0 then
				self:show()
			end
		end,
	}
end

nextLevel=|dontComplete|do
	--TODO if not dontComplete then set the local storage flag for this level
	-- use -1 as our custom-level flag for builtin editor (coming soon)
	if level>-1 then setLevel(level+1) end
	loadLevelRequest=true
end

levelTile = vec2()
setLevel=|level_|do
	level=level_
	saveinfos[saveSlot].level = level
	saveState()
	levelTile.x=level%25
	levelTile.y=(level-levelTile.x)/25*10
	levelTile.x*=10
	if level>-1 then
		--TODO if level >= 0 then set the local storage current-level value to 'level'
		levelstr='level '..tostring(level)
	else
		--level%=maxLevels
		levelstr='level ?'
	end
end

mapGet=|x,y|mget(x+levelTile.x,y+levelTile.y)&0x3ff	-- drop the hv flip and pal-hi
mapSet=|x,y,value|mset(x+levelTile.x,y+levelTile.y,value)

loadLevel=||do
	reset()		-- reload our tilemap? or not?
	removeAll()
	for y=0,levelSize.y-1 do
		for x=0,levelSize.x-1 do
			local pos = vec2(x+.5, y+.5)
			local m = mapGet(x,y)
			if m==EMPTY
			or m==TREE
			or m==BRICK
			or m==STONE
			or m==WATER
			or m==ARROW_RIGHT
			or m==ARROW_DOWN
			or m==ARROW_LEFT
			or m==ARROW_UP
			or m==MOVING_RIGHT
			or m==MOVING_DOWN
			or m==MOVING_LEFT
			or m==MOVING_UP
			then
				-- map type
			else
				mapSet(x,y,EMPTY)
				if m==10 then
					player=Player{}
					player:setPos(pos)
					objs:insert(player)
				elseif m==12 then
					local key=Key{}
					key:setPos(pos)
					objs:insert(key)
				elseif m==14 then
					local framer=Framer{}
					framer:setPos(pos)
					objs:insert(framer)
				elseif m==16 then
					local gun=Gun{}
					gun:setPos(pos)
					objs:insert(gun)
				elseif m==18 then
					local sentry=Sentry{}
					sentry:setPos(pos)
					objs:insert(sentry)
				elseif m>=64 and m<84 then
					local money=Money{}
					money.bombs=(m-64)>>1
					money:setPos(pos)
					objs:insert(money)
				elseif m>=128 and m<148 then
					local bomb=Bomb()
					bomb.blastRadius=(m-128)>>1
					bomb:setPos(pos)
					objs:insert(bomb)
				else
					trace('unknown spawn', x,y,m)
				end
			end
		end
	end
end

local numSaveFiles = 10
-- read save info
savefields = table{'level'}	-- saves byte values of these in 'saveinfos[saveSlot]'
saveinfos = range(numSaveFiles):mapi(|i|do
	return savefields:mapi(|name,fieldOFs|do
		return peek(ramaddr'persistentCartridgeData' + #savefields * (i-1) + (fieldOFs-1)), name
	end):setmetatable(nil)
end)

--local saveSlot	-- 1-based index corresponding to saveinfos[] index
saveState=||do
	for fieldOfs,name in ipairs(savefields) do
		poke(ramaddr'persistentCartridgeData' + #savefields * (saveSlot-1) + (fieldOfs-1), saveinfos[saveSlot]![name])
	end
end

inSplash=true
splashMenuY=0


update=||do
	if inSplash then
		cls(0xf0)

		matident()
		mattrans(32, 32)
		drawMapBorder()
		mattrans(16, 32)
		drawMap()

		matident()
		pokew(ramaddr'blendColor', 0x8000)
		blend(5)
		rect(0,0,256,256,0)
		blend(-1)
		-- splash screen
		local s = 2
		local sx, sy = s*5, s*8
		local x0,y0 = 128-30*s, 64
		local x,y= x0,y0
		local txt=|t|do
			text(t, x, y, nil, nil, s, s)
			y += sy
		end

		splashSpriteX = (((splashSpriteX or 0) + 1) % (256+32))
		spr(seqs.playerStandLeft + (math.floor(time() * 4) & 1) * 2, splashSpriteX - 16, 24, 2, 2, nil, nil, nil, nil, -1, 1)
		spr(seqs.bombLit, splashSpriteX - 16, 24, 2, 2)

		lastTitleWidth = text('BANK', 128-.5*(lastTitleWidth or 0), 24, nil, 0, 4, 4)

		for _,saveinfo in ipairs(saveinfos) do
			txt('  '..(saveinfo.level==0 and 'New Game' or 'Level '..saveinfo.level))
		end
		if btnp'up' then
			splashMenuY -= 1
			sfx(sfxid.menuchange)
		elseif btnp'down' then
			splashMenuY += 1
			sfx(sfxid.menuchange)
		end
		splashMenuY %= #saveinfos
		text('>', x0, splashMenuY*sy + y0, nil, nil, s, s)
		if btnp(4)
		or btnp(5)
		or btnp(6)
		or btnp(7)
		then
			sfx(sfxid.getkey)
			saveSlot = splashMenuY+1
			local saveinfo = saveinfos[saveSlot]
			level = math.max(0, saveinfo.level)
			saveinfo.level = level
			inSplash = false

			setLevel(level)	-- will save state
			removeAll()
			loadLevel()
		end
		return
	end
	if player then
		if btn'up' then
			player:move(dirForName.up)
		elseif btn'down' then
			player:move(dirForName.down)
		elseif btn'left' then
			player:move(dirForName.left)
		elseif btn'right' then
			player:move(dirForName.right)
		else
			player:stopMoving()
		end
		if btnp'y' then
			player:dropBomb()
		end
		if btnp'x' then
			player:die()
		end
	end

	if cheat then
		if btn'a' then
			if btnp'left' then
				setLevel(level-1) removeAll() loadLevel() return
				--player.blendMode=((player.blendMode or 0)-1)%9
			end
			if btnp'right' then
				setLevel(level+1) removeAll() loadLevel() return
				--pokew(0x080a46, 0x801f)	-- set blend color to white
				--player.blendMode=((player.blendMode or 0)+1)%9
			end
		end
	end

	for _,o in ipairs(objs) do
		if not o.removeMe then o:update() end
	end
	if player and player.dead and player.deadTime < time() then
		loadLevel()
	end

	if removeRequest then
		for i=#objs,1,-1 do
			if objs[i].removeMe then objs:remove(i) end
		end
	end

	if #addList > 0 then
		objs:append(addList)
		for i=1,#addList do addList[i]=nil end
	end

	if loadLevelRequest then
		loadLevelRequest=false
		loadLevel()
	end

	-- draw

	cls(0xf0)
	matident()

	if player then
		text(tostring(player.bombs)..' bombs',0,0,22,-1)
		lastLevelStrWidth = lastLevelStrWidth or 5*7
		lastLevelStrWidth = text(levelstr,(256-lastLevelStrWidth)/2,0,22,-1)
		--text('blendMode='..tostring(player.blendMode),0,8,22,-1)
	end

	-- draw the map border
	mattrans(32, 32)
	drawMapBorder()

	mattrans(16, 32)

	-- draw map
	drawMap()

	for _,o in ipairs(objs) do
		o:drawSprite()
	end
end

--setLevel(0)
--removeAll()
--if level > -1 then loadLevel() end
