_G=getfenv(1)
linfDist=[ax,ay,bx,by]do
	return math.max(math.abs(ax-bx), math.abs(ay-by))
end

dt=1/60
mapw,maph=10,10
maxLevels=31
levelstr='level ?'

EMPTY=0
TREE=2
BRICK=4
STONE=6
WATER=8

mapType={
	[EMPTY]={},
	[TREE]={cannotPassThru=true,drawGroundUnder=true},
	[BRICK]={cannotPassThru=true,blocksGunShot=true,blocksExplosion=true,bombable=true},
	[STONE]={cannotPassThru=true,blocksGunShot=true,blocksExplosion=true},
	[WATER]={cannotPassThru=true},
}

dirs={none=-1,down=0,left=1,right=2,up=3}
vecs={[0]={0,1},{-1,0},{1,0},{0,-1}}
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

--#include ext/class.lua
classmeta.__index=_G	-- obj __index looks in its class, if not there then looks into global.  This line is needed for :: setfenv(1,self) use.

BaseObj=class{
	init=[::,args]do
		scaleX,scaleY=1,1
		removeMe=false
		posX=0
		posY=0
		startPosX=0
		startPosY=0
		srcPosX=0
		srcPosY=0
		destPosX=0
		destPosY=0
		moveCmd=-1
		isBlocking=true
		isBlockingPushers=true
		blocksExplosion=true
	end,
	-- in AnimatedObj in fact ...
	update=[::]nil,
	setPos=[::,x,y]do
		posX=x
		srcPosX=x
		destPosX=x
		posY=y
		srcPosY=y
		destPosY=y
	end,
	drawSprite=[::]do
		-- posX posY are tile-centered so ...
		local x = posX * 16 - 8 * scaleX
		local y = posY * 16 - 8 * scaleY
		if blendMode then blend(blendMode) end
		spr(seq,	--spriteIndex,
			x,			--screenX,
			y,			--screenY,
			2,			--spritesWide,
			2,			--spritesHigh,
			nil,		--paletteIndex,
			nil,		--transparentIndex,
			nil,		--spriteBit,
			nil,		--spriteMask,
			scaleX,
			scaleY)
		if blendMode then blend() end
	end,
	isBlockingSentry=[::]isBlocking,
	hitEdge=[::,whereX,whereY]true,
	cannotPassThru=[::,maptype]mapType[maptype]?.cannotPassThru,
	hitWorld=[::,whereX,whereY,typeUL,typeUR,typeLL,typeLR]
		self:cannotPassThru(typeUL)
			or self:cannotPassThru(typeUR)
			or self:cannotPassThru(typeLL)
			or self:cannotPassThru(typeLR),
	hitObject=[::,what,pushDestX,pushDestY,side]'test object',
	startPush=[::,pusher,pushDestX,pushDestY,side]isBlocking,
	endPush=[::,who,pushDestX,pushDestY]nil,
	onKeyTouch=[::]nil,
	onTouchFlames=[::]nil,
	onGroundSunk=[::]removeObj(self),
	onRemove=[::]do self.removeMe=true end,
}

do
	local super=BaseObj
	MovableObj=BaseObj:subclass{
		init=[:,args]do
			super.init(self,args)
			self.lastMoveResponse='no move'
			self.moveCmd=dirs.none
			self.speed=10
			self.moveFracMoving=false
			self.moveFrac=0
		end,
		moveIsBlocked_CheckHitWorld=[:,whereX,whereY]do
			return self:hitWorld(
				whereX,whereY,
				mapGet(whereX-.25,whereY-.25),
				mapGet(whereX+.25,whereY-.25),
				mapGet(whereX-.25,whereY+.25),
				mapGet(whereX+.25,whereY+.25)
			)
		end,
		hitWorld=[:,whereX,whereY,typeUL,typeUR,typeLL,typeLR]do
			for _,o in ipairs(objs) do
				if not o.removeMe
				and o~=self
				and Bomb:isa(o)
				and o.state=='sinking'
				then
					if typeUL==WATER and linfDist(o.destPosX,o.destPosY,whereX-.25,whereY-.25)<.5 then
						typeUL=EMPTY
					end
					if typeUR==WATER and linfDist(o.destPosX,o.destPosY,whereX+.25,whereY-.25)<.5 then
						typeUR=EMPTY
					end
					if typeLL==WATER and linfDist(o.destPosX,o.destPosY,whereX-.25,whereY+.25)<.5 then
						typeLL=EMPTY
					end
					if typeLR==WATER and linfDist(o.destPosX,o.destPosY,whereX+.25,whereY+.25)<.5 then
						typeLR=EMPTY
					end
				end
			end
			return super.hitWorld(self,whereX,whereY,typeUL,typeUR,typeLL,typeLR)
		end,
		moveIsBlocked_CheckEdge=[:,newDestX,newDestY]do
			if newDestX < .25
			or newDestY < .25
			or newDestX > mapw - .25
			or newDestY > maph - .25
			then
				return self:hitEdge(newDestX,newDestY)
			end
			return false
		end,
		moveIsBlocked_CheckHitObject=[:,o,cmd,newDestX,newDestY]do
			if linfDist(o.destPosX,o.destPosY,newDestX,newDestY)>.75 then return false end
			local response=self:hitObject(o,newDestX,newDestY,cmd)
			if response=='stop' then return true end
			if response=='test object' then
				if o:startPush(self,newDestX,newDestY,cmd) then return true end
			end
			return false
		end,
		moveIsBlocked_CheckHitObjects=[:,cmd,newDestX,newDestY]do
			for _,o in ipairs(objs) do
				if not o.removeMe
				and o ~= self
				and self:moveIsBlocked_CheckHitObject(o, cmd, newDestX, newDestY) then
					return true
				end
			end
		end,
		moveIsBlocked=[:,cmd,newDestX,newDestY]do
			return self:moveIsBlocked_CheckEdge(newDestX, newDestY)
			or self:moveIsBlocked_CheckHitWorld(newDestX, newDestY)
			or self:moveIsBlocked_CheckHitObjects(cmd, newDestX, newDestY)
		end,
		doMove=[:,cmd]do
			if cmd==dirs.none then return 'no move' end
			local newDestX=self.posX
			local newDestY=self.posY
			if cmd >= 0 and cmd < 4 then
				newDestX+=vecs[cmd][1] * .5
				newDestY+=vecs[cmd][2] * .5
			else
				return 'no move'
			end
			if self:moveIsBlocked(cmd,newDestX,newDestY) then
				self.moveFracMoving=false
				return 'was blocked'
			end
			self.destPosX=newDestX
			self.destPosY=newDestY
			self.moveFrac=0
			self.moveFracMoving=true
			self.srcPosX=self.posX
			self.srcPosY=self.posY
			return 'did move'
		end,
		update=[:]do
			super.update(self)
			if self.moveFracMoving then
				self.moveFrac+=dt*self.speed
				if self.moveFrac>=1 then
					self.moveFracMoving=false
					self.posX=self.destPosX
					self.posY=self.destPosY
					for _,o in ipairs(objs) do
						if not o.removeMe
						and o ~= self
						and linfDist(o.destPosX, o.destPosY, self.destPosX, self.destPosY) <= .75
						then
							o:endPush(self, self.destPosX, self.destPosY)
						end
					end
				else
					local oneMinusMoveFrac=1 - self.moveFrac
					self.posX=self.destPosX * self.moveFrac + self.srcPosX * oneMinusMoveFrac
					self.posY=self.destPosY * self.moveFrac + self.srcPosY * oneMinusMoveFrac
				end
			end

			if not self.moveFracMoving then
				self.lastMoveResponse=self:doMove(self.moveCmd)
			else
				self.lastMoveResponse='no move'
			end
		end,
	}
end

do
	local super=MovableObj
	PushableObj=MovableObj:subclass{
		init=[:,args]do
			super.init(self, args)
		end,
		startPush=[:,pusher,pushDestX,pushDestY,side]do
			local superResult=super.startPush(self,pusher,pushDestX,pushDestY,side)
			if not self.isBlocking then return false end

			local delta=0
			if side==dirs.left or side==dirs.right then
				delta=self.destPosY-pusher.destPosY
			elseif side==dirs.up or side==dirs.down then
				delta=self.destPosX-pusher.destPosX
			end
			delta=math.abs(delta)
			local align=delta<.25

			if align and not self.moveFracMoving then
				local moveResponse=self:doMove(side)
				if moveResponse=='was blocked'
				or moveResponse=='did move'
				then
					return true
				end
			end
			return superResult
		end,
		hitObject=[:,what,pushDestX,pushDestY,side]do
			if what.isBlockingPushers then return 'stop' end
			return super.hitObject(self,what,pushDestX,pushDestY,side)
		end,
	}
end

do
	local super=BaseObj
	Cloud=BaseObj:subclass{
		init=[:,args]do
			super.init(self,args)
			self.isBlocking=false
			self.isBlockingPushers=false
			self.blocksExplosion=false
			self.blendMode=1
			self.vel=args.vel
			self.life=args.life
			self.scaleX,self.scaleY=args.scale,args.scale
			self:setPos(args.pos[1],args.pos[2])
			self.startTime=time()
			self.seq=seqs.cloud
		end,
		update=[:]do
			super.update(self)
			self:setPos(self.posX+dt*self.vel[1],self.posY+dt*self.vel[2])
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
		init=[:,args]do
			self.isBlocking=false
			self.isBlockingPushers=false
			self.blocksExplosion=false
			self.vel=args.vel
			self.life=args.life
			self.scaleX,self.scaleY=args.radius*2,args.radius*2
			self:setPos(args.pos[1],args.pos[2])
			self.startTime=time()
			self.seq=args.seq or seqs.spark
			self.blendMode=args.blendMode or 0
		end,
		update=[:]do
			super.update(self)
			self:setPos(self.posX+dt*self.vel[1],self.posY+dt*self.vel[2])
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
		init=[:,owner]do
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
		hitObject=[:,whatWasHit,pushDestX,pushDestY,side]do
			if whatWasHit==self.owner
			and self.owner
			and self.ownerStandingOn
			then
				return 'move thru'
			end
			return super.hitObject(self,whatWasHit,pushDestX,pushDestY,side)
		end,
		startPush=[:,pusher,pushDestX,pushDestY,side]do
			if pusher==self.owner
			and self.owner
			and self.ownerStandingOn
			then
				return false
			end
			return super.startPush(self,pusher,pushDestX,pushDestY,side)
		end,
		setFuse=[:,fuseTime]do
			if self.state=='exploding'
			or self.state=='sinking'
			then
				return
			end
			self.seq=seqs.bombLit
			self.state='live'
			self.boomTime=time()+fuseTime
		end,
		cannotPassThru=[:,maptype]do
			local res=super.cannotPassThru(self,maptype)
			if not res then return false end
			return maptype~=WATER
		end,
		drawSprite=[:,c,rect]do
			super.drawSprite(self,c,rect)
			if self.state=='idle'
			or self.state=='live'
			then
				if self.blendMode then blend(self.blendMode) end
				spr(self.blastRadius<<1,
					16*self.posX-4,
					16*self.posY-4,
					2,
					2,
					nil,
					nil,
					nil,
					nil,
					.5,.5)
				if self.blendMode then blend() end
			end
		end,
		onKeyTouch=[:]removeObj(self),
		update=[:]do
			super.update(self)
			if self.owner
			and self.ownerStandingOn
			then
				if linfDist(self.destPosX, self.destPosY, self.owner.destPosX, self.owner.destPosY) > .75
				then
					self.ownerStandingOn=false
				end
			end

			if self.state=='idle'
			or self.state=='live'
			then
				if not self.moveFracMoving then
					local typeUL=mapGet(self.destPosX-.25, self.destPosY-.25)
					local typeUR=mapGet(self.destPosX+.25, self.destPosY-.25)
					local typeLL=mapGet(self.destPosX-.25, self.destPosY+.25)
					local typeLR=mapGet(self.destPosX+.25, self.destPosY+.25)

					for _,o in ipairs(objs)do
						if not removeMe
						and Bomb:isa(o)
						and o.state=='sinking'
						then
							if typeUL==WATER and linfDist(o.destPosX, o.destPosY, self.destPosX - .25, self.destPosY - .25) < .5 then typeUL=EMPTY end
							if typeUR==WATER and linfDist(o.destPosX, o.destPosY, self.destPosX + .25, self.destPosY - .25) < .5 then typeUR=EMPTY end
							if typeLL==WATER and linfDist(o.destPosX, o.destPosY, self.destPosX - .25, self.destPosY + .25) < .5 then typeLL=EMPTY end
							if typeLR==WATER and linfDist(o.destPosX, o.destPosY, self.destPosX + .25, self.destPosY + .25) < .5 then typeLR=EMPTY end
						end
					end

					if typeUL==WATER
					and typeUR==WATER
					and typeLL==WATER
					and typeLR==WATER
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
				self.scaleX,self.scaleY=s,s
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
						and linfDist(o.destPosX, o.destPosY, self.destPosX, self.destPosY) < .75
						then
							local typeUL=mapGet(o.destPosX - .25, o.destPosY - .25)
							local typeUR=mapGet(o.destPosX + .25, o.destPosY - .25)
							local typeLL=mapGet(o.destPosX - .25, o.destPosY + .25)
							local typeLR=mapGet(o.destPosX + .25, o.destPosY + .25)

							for _,o2 in ipairs(objs)do
								if not o2.removeMe
								and Bomb:isa(o2)
								and o2.state=='sinking'
								then
									if typeUL==WATER and linfDist(o2.destPosX, o2.destPosY, o.destPosX - .25, o.destPosY - .25) < .5 then typeUL=EMPTY end
									if typeUR==WATER and linfDist(o2.destPosX, o2.destPosY, o.destPosX + .25, o.destPosY - .25) < .5 then typeUR=EMPTY end
									if typeLL==WATER and linfDist(o2.destPosX, o2.destPosY, o.destPosX - .25, o.destPosY + .25) < .5 then typeLL=EMPTY end
									if typeLR==WATER and linfDist(o2.destPosX, o2.destPosY, o.destPosX + .25, o.destPosY + .25) < .5 then typeLR=EMPTY end
								end
							end

							if typeUL==WATER
							and typeUR==WATER
							and typeLL==WATER
							and typeLR==WATER
							then
								o:onGroundSunk()
							end
						end
					end
				end
			end
		end,
		onGroundSunk=[:]nil,
		onTouchFlames=[:]self:setFuse(self.chainDuration),
		explode=[:]do
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

			local cantHitWorld=false
			local fpartx=self.destPosX - math.floor(self.destPosX)
			local fparty=self.destPosY - math.floor(self.destPosY)
			if fpartx<.25 or fpartx>.75
			or fparty<.25 or fparty>.75
			then
				cantHitWorld=true
			end

			for side=0,3 do
				local checkPosX=self.destPosX
				local checkPosY=self.destPosY
				local len=0
				while true do
					local hit=false
					for _,o in ipairs(objs)do
						if not o.removeMe
						and o~=self
						then
							local dist=linfDist(o.destPosX, o.destPosY, checkPosX, checkPosY)
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

					self:makeSpark(checkPosX, checkPosY)

					if hit then break end
					len+=1
					if len>self.blastRadius then
						len=self.blastRadius
						break
					end

					checkPosX += vecs[side][1]
					checkPosY += vecs[side][2]
					local wallStopped=false
					for ofx=0,1 do
						for ofy=0,1 do
							local cfx=math.floor(checkPosX+ofx*.5-.25)
							local cfy=math.floor(checkPosY+ofy*.5-.25)
							local mapType=mapType[mapGet(cfx, cfy)]
							if mapType and mapType.blocksExplosion then
								if not cantHitWorld
								and mapType.bombable
								then
									local divs=1
									for u=0,divs-1 do
										for v=0,divs-1 do
											local speed=0
											addObj(Particle{
												vel={speed*(math.random()*2-1), speed*(math.random()*2-1)},
												pos={cfx + (u+.5)/divs, cfy + (v+.5)/divs},
												life=math.random()*.5+.5,
												radius=.5,
												seq=seqs.brick,
												blendMode=0,
											})
										end
									end
									mapSet(cfx, cfy, EMPTY)
								end
								wallStopped=true
							end
						end
					end
					if wallStopped then break end
				end
			end

			self.state='exploding'
			self.explodingDone=time()+self.explodingDuration
		end,
		makeSpark=[:,x,y]do
			for i=0,2 do
				local c=math.random()
				addObj(Particle{
					vel={math.random()*2-1, math.random()*2-1},
					pos={x,y},
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
		init=[:,owner]do
			self.owner=owner
			self:setPos(owner.posX, owner.posY)
			self.seq=-1	--invis
		end,
		cannotPassThru=[:,maptype]mapType[maptype].blocksGunShot,
		hitObject=[:,what,pushDestX,pushDestY,side]do
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
		init=[:]do
			super.init(self,{})
			self.seq=seqs.gun
		end,
		update=[:]do
			super.update(self)

			self.seq=seqs.gun

			if player and not player.dead then
				local diffX = player.posX - self.posX
				local diffY = player.posY - self.posY
				local absDiffX = math.abs(diffX)
				local absDiffY = math.abs(diffY)
				local dist = math.min(absDiffX, absDiffY)

				if dist<self.MAD_DIST then
					self.seq=seqs.gunMad
				end

				if dist<self.FIRE_DIST then
					local dir = dirs.none
					if diffX < diffY then	-- left or down
						if diffX < -diffY then
							dir = dirs.left
						else
							dir = dirs.down
						end
					else	-- up or right
						if diffX < -diffY then
							dir = dirs.up
						else
							dir = dirs.right
						end
					end

					local shot = GunShot(self)
					local response = -1
					repeat
						response = shot:doMove(dir)
						shot:setPos(shot.destPosX, shot.destPosY)
					until response=='was blocked'
					--delete ... but it's not attached, so we're safe
				end
			end
		end,
		onKeyTouch=[:]do	--puff
			removeObj(self)
		end,
	}
end

do
	local super=MovableObj
	Sentry=MovableObj:subclass{
		init=[:]do
			super.init(self,{})
			self.dir = dirs.left
			self.seq=seqs.sentry
		end,
		update=[:]do
			--if the player moved onto us ...
			--TODO - put self inside 'endPush' instead! no need to call it each frame
			if linfDist(self.destPosX, self.destPosY, player.destPosX, player.destPosY) < .75 then
				player:die()
			end
			self.moveCmd = self.dir
			super.update(self)
			if self.lastMoveResponse=='was blocked' then
				if self.dir==dirs.up then
					self.dir=dirs.left
				elseif self.dir==dirs.left then
					self.dir=dirs.down
				elseif self.dir==dirs.down then
					self.dir=dirs.right
				elseif self.dir==dirs.right then
					self.dir=dirs.up
				end
			end
		end,

		--the sentry tried to move and hit an object...
		hitObject=[:,what,pushDestX,pushDestY,side]do
			if Player:isa(what) then
				return 'move thru'	--wait for the update() test to pick up hitting the player
			end
			return what:isBlockingSentry() and 'stop' or 'test object'
			--return superHitObject(self, what, pushDestX, pushDestY, side)
		end,

		onKeyTouch=[:]do
			--puff
			removeObj(self)
		end,
	}
end

do
	local super=PushableObj
	Framer=PushableObj:subclass{
		init=[:]do
			super.init(self,{})
			self.seq=seqs.framer
		end,
	}
end

do
	local super=MovableObj
	Player=MovableObj:subclass{
		init=[:,args]do
			super.init(self,args)
			self.dead=false
			self.deadTime=0
			self.dir=dirs.down
			self.bombs=0
			self.bombBlastRadius=1
			self.seq=seqs.playerStandDown
		end,
		move=[:,dir]do
			if self.dead then return end
			self.moveCmd=dir
		end,
		dropBomb=[:]do
			if self.dead then return end
			if self.bombs <= 0 then return end
			local bomb=Bomb(self)
			bomb:setPos(self.destPosX,self.destPosY)
			if bomb:moveIsBlocked_CheckEdge(self.destPosX,self.destPosY)
			or bomb:moveIsBlocked_CheckHitWorld(self.destPosX,self.destPosY)
			then return end
			for _,o in ipairs(objs) do
				if not o.removeMe
				and Bomb:isa(o)
				and o.owner==self
				and linfDist(self.destPosX,self.destPosY,o.destPosX,o.destPosY)<.25
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
		stopMoving=[:]do
			self.moveCmd=dirs.none
		end,
		update=[:]do
			if self.moveCmd~=dirs.none then self.dir=self.moveCmd end
			super.update(self)
			if not self.dead then
				--if self.moveFracMoving then
				local animstep = self.moveCmd~=dirs.none and time() % .5 > .25
				if self.dir==dirs.up then
					self.seq = animstep and seqs.playerStandUp2 or seqs.playerStandUp
				elseif self.dir==dirs.left then
					self.seq = animstep and seqs.playerStandLeft2 or seqs.playerStandLeft
				elseif self.dir==dirs.right then
					self.seq = animstep and seqs.playerStandRight2 or seqs.playerStandRight
				else
					self.seq = animstep and seqs.playerStandDown2 or seqs.playerStandDown
				end
			end
		end,
		getMoney=[:,money]do
			self:setBombs(self.bombs+money.bombs)
		end,
		onTouchFlames=[:]do self:die()end,
		die=[:]do
			if self.dead then return end
			self.seq=seqs.playerDead
			self.dead=true
			self.deadTime=time()+2
			self.isBlocking=false
			self.isBlockingPushers=false
			self.blockExplosion=false
			self.moveCmd=dirs.none
		end,
		onGroundSunk=[:]do self:die()end,
		setBombs=[:,bombs]do
			self.bombs=bombs
		end,
	}
end

do
	local super=BaseObj
	Money=BaseObj:subclass{
		init=[:,args]do
			super.init(self,args)
			self.items=0
			self.bombs=0
			self.isBlocking=false
			self.seq=seqs.money
		end,
		isBlockingSentry=[:]true,
		drawSprite=[:]do
			super.drawSprite(self)

			if self.bombs>0 then
				if self.blendMode then blend(self.blendMode) end
				spr(self.bombs<<1,
					16*self.posX-4,
					16*self.posY-4,
					2,
					2,
					nil,
					nil,
					nil,
					nil,
					.5,.5)
				if self.blendMode then blend() end
			end
		end,

		endPush=[:,who,pushDestX,pushDestY]do
			if not Player:isa(who)
			or linfDist(pushDestX,pushDestY,self.destPosX,self.destPosY) >= .5
			then return end

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
		init=[:,args]do
			super.init(self,args)
			self.changeLevelTime=0
			self.touchToEndLevelDuration=dt
			self.inactive=true
			self.isBlocking=false
			self.blocksExplosion=false
			self.seq=seqs.keyGrey
			self.doFirstCheck=true
		end,
		show=[:]do
			self.inactive=false
			self.seq=seqs.key
		end,

		endPush=[:,who,pushDestX,pushDestY]do
			if not Player:isa(who)
			or self.inactive
			or self.changeLevelTime > 0
			or linfDist(pushDestX,pushDestY,self.destPosX,self.destPosY) >= .5
			then return end
			self.changeLevelTime = time() + self.touchToEndLevelDuration

			for _,o in ipairs(objs) do
				if not o.removeMe then o:onKeyTouch() end
			end

			if player then
				player:setBombs(0)
			end
		end,

		update=[:]do
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

		checkMoney=[:]do
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

mapGet=[x,y]mget(x+levelTileX,y+levelTileY)&0x3ff	-- drop the hv flip and pal-hi
mapSet=[x,y,value]mset(x+levelTileX,y+levelTileY,value)

loadLevel=[]do
	reset()		-- reload our tilemap? or not?
	removeAll()
	for y=0,maph-1 do
		for x=0,mapw-1 do
			local posX,posY=x+.5,y+.5
			local m = mapGet(x,y)
			if m==EMPTY
			or m==TREE
			or m==BRICK
			or m==STONE
			or m==WATER
			then
				-- map type
			else
				mapSet(x,y,EMPTY)
				if m==10 then
					player=Player{}
					player:setPos(posX,posY)
					objs:insert(player)
				elseif m==12 then
					local key=Key{}
					key:setPos(posX,posY)
					objs:insert(key)
				elseif m==14 then
					local framer=Framer{}
					framer:setPos(posX,posY)
					objs:insert(framer)
				elseif m==16 then
					local gun=Gun{}
					gun:setPos(posX,posY)
					objs:insert(gun)
				elseif m==18 then
					local sentry=Sentry{}
					sentry:setPos(posX,posY)
					objs:insert(sentry)
				elseif m>=64 and m<84 then
					local money=Money{}
					money.bombs=(m-64)>>1
					money:setPos(posX,posY)
					objs:insert(money)
				elseif m>=128 and m<148 then
					local bomb=Bomb()
					bomb.blastRadius=(m-128)>>1
					bomb:setPos(posX,posY)
					objs:insert(bomb)
				else
					trace('unknown spawn', x,y,m)
				end
			end
		end
	end
end

update=[]do
	if player then
		if btn'up' then
			player:move(dirs.up)
		elseif btn'down' then
			player:move(dirs.down)
		elseif btn'left' then
			player:move(dirs.left)
		elseif btn'right' then
			player:move(dirs.right)
		else
			player:stopMoving()
		end
		if btnp'y' then
			player:dropBomb()
		end
		if btnp'x' then
			player:die()
		end
		if btn'a' then
			if btnp'left' then
				setLevel(level-1) loadLevelRequest=true
				--player.blendMode=((player.blendMode or 0)-1)%9
			end
			if btnp'right' then
				setLevel(level+1) loadLevelRequest=true
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

	mattrans(32, 32)

	-- draw the map border

	-- draw ground first
	--map(0,20,mapw,maph,0,0,0,true)
	map(10,20,mapw+2,maph+3,0,0,0,true)
	mattrans(16, 32)
	-- then draw map
	map(levelTileX,levelTileY,mapw,maph,0,0,0,true)

	for _,o in ipairs(objs) do
		o:drawSprite()
	end
end

setLevel(0)
removeAll()
if level>-1 then loadLevel() end
