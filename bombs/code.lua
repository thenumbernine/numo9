linfDist=[ax,ay,bx,by]do
	return math.max(math.abs(ax-bx), math.abs(ay-by))
end

dt=1/60
mapw,maph=13,11
maxLevels=31
levelstr='?'

EMPTY=0
TREE=2
BRICK=4
STONE=6
WATER=8

mapType={
	[EMPTY]={},
	[TREE]={cannotPassThru=true,drawGroundUnder=true},
	[BRICK]={cannotPassThru=true,blocksExplosion=true,bombable=true},
	[STONE]={cannotPassThru=true,blocksExplosion=true},
	[WATER]={cannotPassThru=true},
}
mapGet=[x,y]do
	if x<0 or y<0 or x>=mapw or y>=maph then return STONE end
	return mget(math.floor(x)+levelTileX,math.floor(y)+levelTileY)&0x3ff	-- drop the hv flip and pal-hi
end
mapSet=[x,y,value]do
	if x<0 or y<0 or x>=mapw or y>=maph then return end
	mset(x+levelTileX,y+levelTileY,value)
end
mapGetType=[x,y]mapType[mapGet(x,y)]

dirs={none=-1,down=0,left=1,right=2,up=3}
vecs={[0]={0,1},{-1,0},{1,0},{0,-1}}
seqs={
	cloud=128,
	brick=74,	-- irl? why not just the tilemap?
	spark=134,
	bomb=64,
	bombLit=66,
	redbomb=68,
	redbombLit=70,
	playerStandDown=384,
	playerStandDown2=386,
	playerStandLeft=388,
	playerStandLeft2=390,
	playerStandUp=392,
	playerStandUp2=394,
	playerDead=206,

	bombItem=324,
	flameItem=326,
	incineratorItem=328,
	redBombItem=330,
}

-- keep track of items to place
hiddenItems={}
for i=0,mapw-1 do hiddenItems[i]={} end

objs=table()
addList=table()
addObj=[o]addList:insert(o)
removeObj=[o]do
	o:onRemove() -- set the removeMe flag
	removeRequest=true
end
removeAll=[]do
	for _,o in ipairs(objs) do
		o:onRemove()
	end
	objs=table()
	addList=table()
end
players=table()
maxPlayers=4
startPos={
	[0]={0,0},
	{mapw-1,maph-1},
	{mapw-1,0},
	{0,maph-1},
}

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

BaseObj=class{
	bbox={-.4,-.4,.4,.4},
	palOfs=0,
	init=[:,args]do
		self.scaleX,self.scaleY=1,1
		self.removeMe=false
		self.posX=0
		self.posY=0
		self.velX=0
		self.velY=0
		self.moveCmd=dirs.none
		self.isBlocking=true	-- stops 'doesBlock'
		self.doesBlock=true	-- stopped by blocking/solid objs/walls
		self.blocksExplosion=true
	end,
	-- in AnimatedObj in fact ...
	update=[:]do
		if self.noPhysics then return end
		if self.wasTouching then
			local xmin=self.posX+self.bbox[1]
			local ymin=self.posY+self.bbox[2]
			local xmax=self.posX+self.bbox[3]
			local ymax=self.posY+self.bbox[4]
			local o = self.wasTouching
			local oxmin=o.posX+o.bbox[1]
			local oymin=o.posY+o.bbox[2]
			local oxmax=o.posX+o.bbox[3]
			local oymax=o.posY+o.bbox[4]
			if not (oxmax>=xmin
			and oxmin<=xmax
			and oymax>=ymin
			and oymin<=ymax)
			then
				self.wasTouching=nil
			end
		end

		if self.doesBlock then
			-- check bbox of new pos against walls and against objs
			self.contactTileX=nil
			self.contactTileY=nil
			local vx=self.velX*dt
			local vy=self.velY*dt
::retry::
			local newPosX=self.posX+vx
			local newPosY=self.posY+vy
			local xmin=newPosX+self.bbox[1]
			local ymin=newPosY+self.bbox[2]
			local xmax=newPosX+self.bbox[3]
			local ymax=newPosY+self.bbox[4]
			local checkBox=[o,oxmin,oymin,oxmax,oymax]do
				local dxr = oxmin - xmax
				local dxl = xmin - oxmax
				local dyr = oymin - ymax
				local dyl = ymin - oymax
				local adx = math.max(dxl,dxr)
				local ady = math.max(dyl,dyr)
				if 0<=adx or 0<=ady then return end	-- separating plane - didn't touch
				local result
				if self:touch(o) then
					result = true
				end
				if o and not self.removeMe and not o.removeMe then
					if o:touch(self) then
						result = true
					end
				end
				if result then
					if adx < ady and math.abs(vx) > 0 then
						vx = 0
--						self.velX = 0
						result = 'retry'
					elseif ady < adx and math.abs(vy) > 0 then
						vy = 0
--						self.velY = 0
						result = 'retry'
					end
				end
				return result
			end
			local checkMap=[x,y]do
				if not mapGetType(x,y).cannotPassThru then return end
				self.contactTileX=x
				self.contactTileY=y
				return checkBox(nil,x,y,x+1,y+1)
			end
			for x=math.floor(math.min(self.posX,newPosX)+self.bbox[1]),
				math.ceil(math.max(self.posX,newPosX)+self.bbox[3])
			do
				for y=math.floor(math.min(self.posY,newPosY)+self.bbox[2]),
					math.ceil(math.max(self.posY,newPosY)+self.bbox[4])
				do
					local response = checkMap(x,y)
					if response then
						if response == 'retry' then
							goto retry
						end
						return
					end
				end
			end
			for _,o in ipairs(objs) do
				if not o.removeMe
				and not o.noPhysics
				and o~=self
				then
					local oxmin=o.posX+o.bbox[1]
					local oymin=o.posY+o.bbox[2]
					local oxmax=o.posX+o.bbox[3]
					local oymax=o.posY+o.bbox[4]
					local response = checkBox(o,oxmin,oymin,oxmax,oymax)
					if response then
						if response == 'retry' then goto retry end
						return
					end
				end
			end
			self.posX=newPosX
			self.posY=newPosY
		end
	end,
	touch=[:,other]do
		if not other then return true end
		if other==self.wasTouching
		or self==other.wasTouching
		then return end
		return self.isBlocking and other.doesBlock
		or other.isBlocking and self.doesBlock
	end,
	setPos=[:,x,y]do
		self.posX=x
		self.posY=y
	end,
	drawSprite=[:]do
		-- posX posY are tile-centered so ...
		local x = self.posX * 16 - 8 * self.scaleX
		local y = self.posY * 16 - 8 * self.scaleY
		if self.blend then blend(self.blend) end
		spr(self.seq,	--spriteIndex,
			x,			--screenX,
			y,			--screenY,
			2,			--spritesWide,
			2,			--spritesHigh,
			self.palOfs,--paletteIndex,
			nil,		--transparentIndex,
			nil,		--spriteBit,
			nil,		--spriteMask,
			self.scaleX,
			self.scaleY)
		if self.blend then blend() end
	end,
	onTouchFlames=[:]nil,
	onRemove=[:]do self.removeMe=true end,
}

do
	local super=BaseObj
	Cloud=BaseObj:subclass{
		init=[:,args]do
			super.init(self,args)
			self.doesBlock=false
			self.isBlocking=false
			self.blocksExplosion=false
			self.blend=1
			self.velX=args.vel[1]
			self.velY=args.vel[2]
			self.life=args.life
			self.scaleX,self.scaleY=args.scale,args.scale
			self:setPos(args.pos[1],args.pos[2])
			self.startTime=time()
			self.seq=seqs.cloud
		end,
		update=[:]do
			super.update(self)
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
	Flame=BaseObj:subclass{
		init=[:,args]do
			super.init(self,args)
			self.doesBlock=false
			self.isBlocking=false
			self.blocksExplosion=false
			self.removeTime=time()+args.life
			self:setPos(table.unpack(args.pos))
			self.startTime=time()
			self.seq=args.seq or seqs.spark
			self.blend=args.blend or 0
		end,
		update=[:]do
			super.update(self)
			if time()>=self.removeTime then
				removeObj(self)
				return
			end
		end,
		touch=[:,other]do
			if other and Player:isa(other) then
				other:die()
			end
			return super.touch(self,other)
		end,
	}
end

do
	local super=BaseObj
	Particle=BaseObj:subclass{
		init=[:,args]do
			super.init(self,args)
			self.doesBlock=false
			self.isBlocking=false
			self.blocksExplosion=false
			self.velX=args.vel[1]
			self.velY=args.vel[2]
			self.life=args.life
			self.scaleX,self.scaleY=args.radius*2,args.radius*2
			self:setPos(table.unpack(args.pos))
			self.startTime=time()
			self.seq=args.seq or seqs.spark
			self.blend=args.blend or 0
		end,
		update=[:]do
			super.update(self)
			local frac=math.max(0,1-(time()-self.startTime)/self.life)
			if frac==0 then
				removeObj(self)
				return
			end
		end,
	}
end

do
	local super=BaseObj
	Bomb=super:subclass{
		init=[:,args]do
			super.init(self,args)
			-- class constants / defaults:
			self.boomTime = 0
			self.bombLength = args.bombLength or 1
			self.explodingDone = 0
			self.sinkDone = 0
			self.fuseDuration = 2
			self.chainDuration = .2
			self.explodingDuration = .4
			--
			self.owner=args.owner
			self.state='idle'
			self.redbomb=args.redbomb
			self.incinerator=args.incinerator
			self.seq=self.redbomb and seqs.bomb or seqs.redbomb
		end,
		setFuse=[:,fuseTime]do
			if self.state=='exploding' then return end
			self.seq=self.redbomb and seqs.redbombLit or seqs.bombLit
			self.state='live'
			self.boomTime=time()+fuseTime
		end,
		update=[:]do
			super.update(self)
			if self.owner
			and self.ownerStandingOn
			then
				if linfDist(self.posX, self.posY, self.owner.posX, self.owner.posY) > .75
				then
					self.ownerStandingOn=false
				end
			end
			if self.state=='live' then
				local t=time()-self.boomTime
				local s=math.cos(2*t*math.pi)*.2+.9
				self.scaleX,self.scaleY=s,s
				if t>=0 then
					self:explode()
				end
			elseif self.state=='exploding' then
				local t=time()-self.explodingDone
				if t>=0 then
					removeObj(self)
				end
			end
		end,
		onTouchFlames=[:]self:setFuse(self.chainDuration),
		explode=[:]do
			--[[
			for i=0,9 do
				local scale=math.random()*2
				addObj(Cloud{
					pos={self.posX, self.posY},
					vel={math.random()*2-1, math.random()*2-1},
					scale=scale+1,
					-- TODO blending ...
					--life=5-scale,
					-- until then ...
					life=(5-scale)/5,
				})
			end
			--]]

			for side=0,3 do
				local checkPosX=math.floor(self.posX)
				local checkPosY=math.floor(self.posY)
				local len=0
				while true do
					local hit=false
					for _,o in ipairs(objs)do
						if not o.removeMe
						and not o.noPhysics	-- dont let dead players block
						and o~=self
						then
							local dist=linfDist(o.posX, o.posY, checkPosX+.5, checkPosY+.5)
							if Player:isa(o)
							and dist > .75 then
							elseif dist > .25 then
							else
								o:onTouchFlames()
								if o.blocksExplosion then
									hit=true
									break
								end
							end
						end
					end

					addObj(Flame{
						pos={checkPosX+.5, checkPosY+.5},
						life=self.explodingDuration,
					})


					if not self.redbomb and hit then
						break
					end
					len+=1
					if not self.incinerator and len>self.bombLength then
						len=self.bombLength
						break
					end

					checkPosX+=vecs[side][1]
					checkPosY+=vecs[side][2]
					local mapType=mapGetType(checkPosX, checkPosY)
					if mapType and mapType.blocksExplosion then
						if mapType.bombable then
							local divs=1
							for u=0,divs-1 do
								for v=0,divs-1 do
									local speed=0
									addObj(Particle{
										vel={speed*(math.random()*2-1), speed*(math.random()*2-1)},
										pos={checkPosX + (u+.5)/divs, checkPosY + (v+.5)/divs},
										life=math.random()*.5+.5,
										radius=.5,
										seq=seqs.brick,
										blend=0,
									})
								end
							end
							-- place an item here if it should be
							-- TODO track all item locations
							local tmp=hiddenItems[checkPosX][checkPosY]?(checkPosX,checkPosY)
							hiddenItems[checkPosX][checkPosY]=nil

							mapSet(checkPosX, checkPosY, EMPTY)
							-- blcok only if we don't have redbombs
							if not self.redbomb then break end
						else
							break -- block no matter what
						end
					end
				end
			end

			-- remove from owner
			self.owner.bombs:removeObject(self)

			self.state='exploding'
			self.explodingDone=time()+self.explodingDuration
		end,
	}
end

do
	local super=BaseObj
	Item=super:subclass{
		invincibleDuration=.5,
		init=[:,args]do
			super.init(self,args)
			self.spawnTime=time()
			self.isBlocking=false
			self.doesBlock=false
			self.blocksExplosion=true
		end,
		touch=[:,other]do
			--super.touch(self,other)
			if not other then return true end
			if not Player:isa(other) then return end
			other.items:insert(self)
			other[self.itemParam] = (other[self.itemParam] or 0) + 1
			self.seq=nil
			self:setPos(-10,-10)
			self.noPhysics=true
		end,
		onTouchFlames=[:]do
			if time()>self.spawnTime+self.invincibleDuration then
				removeObj(self)
			end
		end,
		respawn=[:]do
			local tries = 1
			local newpos = {0,0}
			while tries < 100 do
				-- minus a half so we end up [0,n-1]+.5 rather than [1,n]
				newpos[1] = math.random(mapw)-.5
				newpos[2] = math.random(maph)-.5
				if mapGetType(table.unpack(newpos))==EMPTY then
					local close=false
					for _,o in ipairs(objs) do
						if not o.removeMe
						-- todo - if the ent is a breakable then stuff the item back inside of it?
						and (newpos - e:getPos()):lenSq() < 1 then
							close = true
							break
						end
					end
					if not close then break end
				end
				tries+=1
			end
			if tries >= 100 then
				trace('couldnt spawn an item =( lost it to the deep ...')
			else
				self:setPos(table.unpack(newpos))
				self.seq=nil	-- default to class seq
				self.noPhysics=false
			end
		end,
	}
end

FlameItem=Item:subclass{
	itemParam='flameCount',
	seq=seqs.flameItem,
}

BombItem=Item:subclass{
	itemParam='bombCount',
	seq=seqs.bombItem,
}

IncineratorItem=Item:subclass{
	itemParam='incineratorCount',
	seq=seqs.incineratorItem,
}

RedBombItem=Item:subclass{
	itemParam='redbombCount',
	seq=seqs.redBombItem,
}

do
	local super=BaseObj
	Player=super:subclass{
		speed=5,
		bbox={-.3,-.3,.3,.3},
		redbombCount=0,
		incineratorCount=0,
		bumpDX=0,
		bumpDY=0,
		bumpTime=0,
		init=[:,args]do
			super.init(self,args)
			self.dead=false
			self.deadTime=0
			self.dir=dirs.down
			self.flameCount=1
			self.bombCount=1
			self.seq=seqs.playerStandDown
			self.bombs=table()
			self.items=table()
		end,
		move=[:,dir]do
			if self.dead then return end
			self.moveCmd=dir
		end,
		dropBomb=[:]do
			if self.dead then
				return
			end
			if #self.bombs>=self.bombCount then
				return
			end
			local bombpos={self.posX,self.posY}
			bombpos[1] = math.round(bombpos[1]-.5)+.5
			bombpos[2] = math.round(bombpos[2]-.5)+.5
			for _,e in ipairs(objs) do
				if not e.removeMe
				and Bomb:isa(e)
				and linfDist(e.posX,e.posY,bombpos[1],bombpos[2])<.25
				then
					return
				end
			end
			local bomb=Bomb{
				owner=self,
				bombLength=self.flameCount,
				redbomb=self.redbombCount>0,
				incinerator=self.incineratorCount>0,
			}
			self.bombs:insert(bomb)
			bomb:setPos(table.unpack(bombpos))
			bomb:setFuse(bomb.fuseDuration)
			bomb.wasTouching=self
			addObj(bomb)
		end,
		stopMoving=[:]do
			self.moveCmd=dirs.none
		end,
		update=[:]do

			if self and self.dead and self.deadTime < time() then
				removeObj(self)
			end

			if self.moveCmd~=dirs.none then self.dir=self.moveCmd end

			self.velX=0
			self.velY=0
			if not self.dead then

				if self.bumpDX~=0 or self.bumpDY~=0 then
					if math.abs(self.bumpDX)<math.abs(self.bumpDY) then	-- y is the min component so operate along y
						self.velX=math.sign(-self.bumpDX)*self.speed
					else			-- operate along x
						self.velY=math.sign(-self.bumpDY)*self.speed
					end
					-- but the vel gets cleared next frame anyways
					-- so this doesn't do anything
					-- and if we move this into the player loop then we get stuck in walls ...
				else
					if self.moveCmd==dirs.up then
						self.velY=-self.speed
					elseif self.moveCmd==dirs.down then
						self.velY=self.speed
					elseif self.moveCmd==dirs.left then
						self.velX=-self.speed
					elseif self.moveCmd==dirs.right then
						self.velX=self.speed
					end
				end
				if time() - self.bumpTime > 2*dt then
					self.bumpDX=0
					self.bumpDY=0
				end

				local animstep = self.moveCmd~=dirs.none and time() % .5 > .25
				if self.dir==dirs.up then
					self.seq = animstep and seqs.playerStandUp2 or seqs.playerStandUp
				elseif self.dir==dirs.left then
					self.seq = animstep and seqs.playerStandLeft2 or seqs.playerStandLeft
					self.scaleX = 1
				elseif self.dir==dirs.right then
					self.seq = animstep and seqs.playerStandLeft2 or seqs.playerStandLeft
					self.scaleX = -1
				else
					self.seq = animstep and seqs.playerStandDown2 or seqs.playerStandDown
				end
			end
			super.update(self)
		end,
		touch=[:,other]do
			if not other then
				-- if we bumped into a second bump then stop bumping
				if self.bumpDX~=0 or self.bumpDY~=0 then
					self.bumpDX=0
					self.bumpDY=0
					self.bumpTime=-100
				else
					self.bumpDX=self.contactTileX+.5-self.posX
					self.bumpDY=self.contactTileY+.5-self.posY
					self.bumpTime=time()
				end
			end
			return super.touch(self,other)
		end,
		onTouchFlames=[:]self:die(),
		die=[:]do
			if self.dead then return end
			self.seq=seqs.playerDead
			self.dead=true
			self.deadTime=time()+2
			self.noPhysics=true
			self.isBlocking=false
			self.isBlocked=false
			self.blockExplosion=false
			self.moveCmd=dirs.none
		end,
	}
end

nextLevel=[dontComplete]do
	--TODO if not dontComplete then set the local storage flag for this level
	-- use -1 as our custom-level flag for builtin editor (coming soon)
	if level>-1 then setLevel(level+1) end
	loadLevelRequest=true
end

setLevel=[level_]do
	level=level_
	levelTileX=level%25
	levelTileY=(level-levelTileX)/25*10
	levelTileX*=10
	if level>-1 then
		--TODO if level >= 0 then set the local storage current-level value to 'level'
		levelstr='level '..tostring(level)
	else
		--level%=maxLevels
		levelstr='level ?'
	end
end

playerOptions=table{
	off=0,
	human=1,
	ai=2,
	count=3,
}
playerOptionNames=playerOptions:map([v,k](k,v)):setmetatable(nil)
playersActive=table{playerOptions.off}:rep(maxPlayers-1)
playersActive[0]=playerOptions.human
playerWins=table{0}:rep(maxPlayers):map([v,k](v,k-1))
inMenu=true
menuSel=0

loadLevel=[]do
	reset()		-- reload our tilemap? or not?
	removeAll()
	local allBombable=table()
	for y=0,maph-1 do
		for x=0,mapw-1 do
			local posX,posY=x+.5,y+.5
			local m=mapGet(x,y)
			-- TODO randomly remove some? maybe?
			local mt=mapType[m]
			if mt.bombable then
				allBombable:insert{x,y}
			end
		end
	end
	allBombable = allBombable:shuffle()
	-- how many items to place ...
	for _,iteminfo in ipairs{
		{FlameItem,5},
		{BombItem,10},
		{IncineratorItem,1},
		{RedBombItem,1},
	} do
		local itemclass,count = table.unpack(iteminfo)
		for i=1,count do
			if #allBombable==0 then break end
			local x,y=table.unpack(allBombable:remove())
			hiddenItems[x][y]=[x,y]do
				local item=itemclass{}
				item:setPos(x+.5,y+.5)
				addObj(item)
			end
		end
		if #allBombable==0 then break end
	end
	for pid=0,maxPlayers-1 do
		if playersActive[pid]~=playerOptions.off then
			-- TODO handle AI
			local player=Player{}
			players[pid]=player
			local s=startPos[pid]
			player.playerID=pid
			player.palOfs=pid<<4
			player:setPos(s[1]+.5,s[2]+.5)
			objs:insert(player)
		end
	end
end

update=[]do
	if inMenu then
		cls(0xf0)
		spr(
			20,
			0, 0,
			8, 8,
			nil,
			nil,
			nil,
			nil,
			4,
			4)
		local x,y=16,96
		text('>', x-8, y+16*menuSel, 0xfc, 0xf0)
		text('wins',x+192-16,y-12,0xfc,0xf0)
		for pid=0,maxPlayers-1 do
			spr(seqs.playerStandDown, x, y-4, 2, 2, pid<<4)
			text('player '..pid..' = '
				..tostring(playerOptionNames[playersActive[pid]]),
				x+24, y, 0xfc, 0xf0)
			text(tostring(playerWins[pid]),x+192, y,0xfc,0xf0)
			y+=16
		end
		text('Start!', x, y, 0xfc, 0xf0)
		for pid=0,maxPlayers-1 do
			if btnp(0,pid) then
				menuSel-=1
				menuSel%=maxPlayers+1
			elseif btnp(1,pid) then
				menuSel+=1
				menuSel%=maxPlayers+1
			end
			if menuSel<maxPlayers then
				-- any players left/right can toggle
				if btnp(2,pid) then
					playersActive[menuSel]-=1
					playersActive[menuSel]%=playerOptions.count
				elseif btnp(3,pid) then
					playersActive[menuSel]+=1
					playersActive[menuSel]%=playerOptions.count
				else
					-- if any player presses a button then set them to human
					if btnp(4,pid) or btnp(5,pid) or btnp(6,pid) or btnp(7,pid) then
						playersActive[pid] = playerOptions.human
					end
				end
			else
				-- if any player pushes when we're on 'start' then go
				if btnp(4,pid) or btnp(5,pid) or btnp(6,pid) or btnp(7,pid) then
					matchDoneTime=nil
					winningPlayer=nil
					setLevel(0)
					removeAll()
					loadLevel()
					inMenu=false
				end
			end
		end
		return
	end

	local alive=0
	local lastAlive
	for pid=0,maxPlayers-1 do
		local player = players[pid]
		if player and not player.dead then
			alive+=1
			lastAlive=pid
			if btn(0,pid) then
				player:move(dirs.up)
			elseif btn(1,pid) then
				player:move(dirs.down)
			elseif btn(2,pid) then
				player:move(dirs.left)
			elseif btn(3,pid) then
				player:move(dirs.right)
			else
				player:stopMoving()
			end
			--if btn(7,pid) or btn(5,pid) or btn(4,pid) or btn(6,pid) then
			if btnp(7,pid) or btnp(5,pid) or btnp(4,pid) or btnp(6,pid) then
				player:dropBomb()
			end
		end
	end

	for _,o in ipairs(objs) do
		if not o.removeMe then o:update() end
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
	mattrans(8,16)
	-- draw ground and border
	map(10,20,mapw+2,maph+2,0,0,0,true)
	mattrans(16, 16)
	-- then draw map
	map(levelTileX,levelTileY,mapw,maph,0,0,0,true)

	for _,o in ipairs(objs) do
		o:drawSprite()
	end

	-- now draw border / ui
	matident()

	for pid=0,maxPlayers-1 do
		if playersActive[pid]~=playerOptions.off then
			local x=pid*56+32
			spr(seqs.playerStandDown, x, 0, 2, 2, pid<<4)
			text('x'..tostring(playerWins[pid]),x+16,0,0xfc,0xf0)
		end
	end

	if matchDoneTime==nil then
		if alive<=1 then
			winningPlayer=nil
			if alive==0 then
				-- draw
				text('DRAW', 128, 4, 0xfc, 0)
			elseif alive==1 then
				winningPlayer=lastAlive
				playerWins[winningPlayer]+=1
			end
			matchDoneTime=time()
		end
	else
		-- player won
		winMsgWidth=winMsgWidth or 0
		winMsgWidth=text('PLAYER '..tostring(winningPlayer)..' WON!', 128-(winMsgWidth>>1), 4, 0xfc, 0)
		if time()>matchDoneTime+5 then
			inMenu=true
			menuSel=0
		end
	end
end

setLevel(0)
removeAll()
if level>-1 then loadLevel() end
