shipSprite=0
shipMoveUpSprite=32
shipMoveDownSprite=64
playerShotSprite=2

explodeSprites={4,6,8,10}

enemySprites={96,98,100}
enemyShotSprite = 3

-- scroll and subsequent tilemap x y
scrollX,scrollY=0,0
mx,my=0,0

-- player stats
playerDeadTime = nil
playerX,playerY=32,128-4
playerVelX,playerVelY=0,0
nextshottime = 0

playerShots=table()
playerShoot=[playerVelX,playerVelY]do
	if time() < nextshottime then return end
	playerShots:insert{x=playerX+8,y=playerY,vx=playerVelX,vy=playerVelY}
	nextshottime = time() + 1/10
end

local explosions = table()
makeExplosion=[x,y]do
	explosions:insert{x=x,y=y,time=time()}
end

local enemyShots = table()

local enemyShotTime = 1
local enemyShotSpeed = 2
local Enemy = {}
Enemy.__index = Enemy
Enemy.shootPlayer=[:]do
	if time() - self.lastShotTime < enemyShotTime then return end
	local vx = playerX - self.x
	local vy = playerY - self.y
	local ilen = enemyShotSpeed/math.sqrt(vx*vx + vy*vy)
	vx *= ilen
	vy *= ilen
	enemyShots:insert{
		x=self.x,
		y=self.y,
		vx=vx,
		vy=vy,
	}
end

enemies=table()
makeEnemy=[x,y,class]do
	enemies:insert(setmetatable({
		x=x,
		y=y,
		class=class,
		time=time(),
		lastShotTime = time(),
	}, Enemy))
end

reset=[]do
	scrollX,scrollY = 0,0
	mx,my = 0,0
	playerDeadTime = nil
	playerX, playerY = 32, 128-4
	playerVelX, playerVelY = 0, 0
	nextshottime = 0
	playerShots = table()
	explosions = table()
	enemyShots = table()
	enemies = table()

	-- TODO for the sake of level state,
	-- copy whatever loaded level into tilemap slot 0 or something
	-- and then we can modify the level as we play it (erase enemy spawn markers etc)
	-- and reset() will work fine
end
reset()

local scrollSpeed = .5
update=[]do
	cls()

	scrollX += scrollSpeed
	oldmx,oldmy=mx,my
	mx = scrollX>>3
	my = scrollY>>3
	--TODO level end at soem scroll distance
	map(
		mx,
		my,
		33,
		33,
		-(scrollX-(mx<<3)),
		-(scrollY-(my<<3))
	)

	-- go through right col of tilemap and see if there are any new enemies
	if mx ~= oldmx then
		local chkx = mx+32
		for y=0,31 do
			local t = mget(chkx, y)
			if t == 2 then		-- TODO enemy class
				makeEnemy(chkx<<3, y<<3, t)
				mset(chkx,y,0)
			end
		end
	end

	if not playerDeadTime then
		spr(playerVelY < 0 and shipMoveUpSprite or
			(playerVelY > 0 and shipMoveDownSprite or
			shipSprite),playerX,playerY,2,1)

		local speed = 2
		playerVelX,playerVelY = 0,0
		if btn(0) then playerVelY -=speed end
		if btn(1) then playerVelY +=speed end
		if btn(2) then playerVelX -=speed end
		if btn(3) then playerVelX +=speed end
		if btn(7) then playerShoot(8,0) end

		playerX+=playerVelX 
		playerY+=playerVelY
		-- should coords be relative to screen or relative to level?  hmm...
		--playerX += 1	-- whatever the scroll screen is ...? 
	else
		if time() > playerDeadTime + 5 then
			reset()
		end
	end

	for i=#playerShots,1,-1 do
		local s = playerShots[i]
		s.x += s.vx
		s.y += s.vy
		spr(playerShotSprite,s.x,s.y)
		-- TODO detect impact or off screen
		-- detect off screen
		if s.x < 0 or s.x >= 256 or s.y < 0 or s.y >= 256 then
			playerShots:remove(i)
			goto playerShotDone
		end
		for j=#enemies,1,-1 do
			local e = enemies[j]
			if s.x+1 >= e.x-8 and s.x-1 <= e.x+8
			and s.y+1 >= e.y-4 and s.y-1 <= e.y+4
			then
				enemies:remove(j)
				playerShots:remove(i)
				makeExplosion(s.x, s.y)
				goto playerShotDone
			end
		end
::playerShotDone::
	end

--trace('#enemyShots', #enemyShots)
	for i=#enemyShots,1,-1 do
		local s = enemyShots[i]
		s.x += s.vx
		s.y += s.vy
		spr(enemyShotSprite,s.x,s.y)
		-- TODO detect impact or off screen
		-- detect off screen
		if s.x < 0 or s.x >= 256 or s.y < 0 or s.y >= 256 then
--trace('...oob, removing')			
			enemyShots:remove(i)
			goto enemyShotDone
		end
		local e = enemies[j]
		if not playerDeadTime
		and s.x+1 >= playerX-8 and s.x-1 <= playerX+8
		and s.y+1 >= playerY-4 and s.y-1 <= playerY+4
		then
--trace('...hit player, removing')			
			enemyShots:remove(i)
			makeExplosion(s.x, s.y)
			playerDeadTime = time()
			goto enemyShotDone
		end
::enemyShotDone::
	end


-- [[
	for i=#enemies,1,-1 do
		local e = enemies[i]
		local frame = math.floor((time() - e.time) * 5) % #enemySprites
		spr(enemySprites[frame+1],e.x,e.y, 2, 1)
		local t = time() - e.time
		e.x -= 1 + math.cos(2*math.pi*t)
		e.y += math.sin(2*math.pi*t)

		-- blow up upon crash
		if not playerDeadTime
		and e.x+8 >= playerX-8 and e.x-8 <= playerX+8
		and e.y+4 >= playerY-4 and e.y-4 <= playerY+4
		then
			playerDeadTime = time()
			makeExplosion(e.x, e.y)
			makeExplosion(playerX, playerY)
		end

		if math.random() < .01 then
			e:shootPlayer()
		end

		-- or just check shot impact here
		if e.x < 0 then
			enemies:remove(i)
		end
	end
--]]

	for i=#explosions,1,-1 do
		local ex = explosions[i]
		local f = explodeSprites[math.floor((time() - ex.time) * 8) + 1]
		if not f then
			explosions:remove(i)
		else
			spr(f, ex.x, ex.y, 2, 2)
		end
	end
end
