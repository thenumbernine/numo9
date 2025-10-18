--#include ext/class.lua

vec2=class{
	set=|:,x,y|do
		self[1]=x or 0
		self[2]=y or 0
		return self
	end,
	init=|:,...|self:set(...),
	unpack=table.unpack,
	dot=|a,b|a[1]*b[1]+a[2]*b[2],
	__add=|a,b|vec2(a[1]+b[1],a[2]+b[2]),
	__sub=|a,b|vec2(a[1]-b[1],a[2]-b[2]),
	__mul=|a,b|vec2(a[1]*b,a[2]*b),
	__div=|a,b|vec2(a[1]/b,a[2]/b),
}

local worldSize = 256	-- biggest size of the game
local dt = 1/60

local playerHitSound = 0
local blockHitSound = 0
local getItemSound = 0

local Player = class()
Player.score = 0
Player.size = 32
Player.sizeMin = 1
Player.sizeMax = 64
Player.y = 128
Player.vy = 0
Player.speedMin = 1
Player.speedMax = 64
Player.speed = 16
Player.speedScalar = 10
Player.xForIndex = {12, worldSize - 12}
Player.nForIndex = {1, -1}	-- x normal for the player
function Player:init(index)
	self.index = index
	self.normal = vec2()
	if index then	-- clientside doesn't know indexes, and doesn't use normals.  if it did you could always sync them
		self.normal[1] = self.nForIndex[index]
	end
end
function Player:move(dy)
	self.vy = dy
end

local Ball = class()
Ball.speedMin = 1
Ball.speedMax = 50
Ball.speedScalar = 12
function Ball:init()
	self.pos = vec2()
	self.vel = vec2()
end
function Ball:reset()
	self.pos:set(128,192)
	self.vel:set(-5,5)
end

local Block = class()
function Block:init(args)
	self.pos = args.pos
end

local messages = table()
local Message = class()
Message.duration = 3
Message.endPos = vec2(worldSize/2, 2)
function Message:init(args)
	messages:insert(self)
	--self.startPos = args.pos
	self.startPos = vec2(self.endPos:unpack())
	self.text = args.text
	self.startTime = time()
end

local Item = class()
Item.speed = 50
do
	local function changePaddleSize(amount)
		return function(player, game)
			player.size = math.clamp(player.sizeMin, player.size + amount, player.sizeMax)
		end
	end
	local function changePaddleSpeed(amount)
		return function(player, game)
			player.speed = math.clamp(player.speedMin, player.speed + amount, player.speedMax)
		end
	end
	local function changeBallSpeed(amount)
		return function(player, game)
			local ball = game.ball
			local speed = ball.vel[1]
			local absSpeed = math.abs(speed)
			local dir = speed / absSpeed
			absSpeed = math.clamp(ball.speedMin, absSpeed + amount, ball.speedMax)
			game.ball.vel[1] = absSpeed * dir
		end
	end
	Item.types = {
		{
			desc = 'Shrink Paddle',
			color = 1,
			exec = changePaddleSize(-1),
		},
		{
			desc = 'Grow Paddle',
			color = 2,
			exec = changePaddleSize(1),
		},
		{
			desc = 'Speed Ball',
			color = 3,
			exec = changeBallSpeed(1),
		},
		{
			desc = 'Slow Ball',
			color = 4,
			exec = changeBallSpeed(-1),
		},
		{
			desc = 'Speed Paddle',
			color = 5,
			exec = changePaddleSpeed(1),
		},
		{
			desc = 'Slow Paddle',
			color = 6,
			exec = changePaddleSpeed(-1),
		},
	}
end
function Item:init(itemType)
	self.pos = vec2()
	self.vel = vec2()
	self.type = itemType
end
function Item:touch(player, game)
	local itemType = assert(self.types[self.type])
	Message{
		text = 'player '..player.index..' got '..itemType.desc,
		pos = vec2(
			Player.xForIndex[player.index],
			player.y - (player.size>>1)
		),
	}
	itemType.exec(player, game)
end

local Game = class()
Game.blockGridSize = 16
Game.spawnBlockDuration = 1
function Game:init()
	self.ball = Ball()
	self.playerA = Player(1)
	self.playerB = Player(2)
	self:reset()
end
function Game:reset()
	self.startTime = time() + 3
	self.ball:reset()
	self.blocks = table()
	self.items = table()
	self.blockForPos = {}
	self.nextBlockTime = time() + self.spawnBlockDuration
end
function Game:update()

	local players = {self.playerA, self.playerB}

	for _,player in ipairs(players) do
		player.y = player.y + player.vy * (player.speedScalar * player.speed * dt)
		if player.y < 0 then player.y = 0 end
		if player.y > worldSize then player.y = worldSize end
	end

	if time() < self.startTime then return end

	if time() > self.nextBlockTime then
		self.nextBlockTime = time() + self.spawnBlockDuration
		local newBlockPos = vec2(math.random(1,self.blockGridSize), math.random(1,self.blockGridSize))
		local blockCol = self.blockForPos[newBlockPos[1]]
		if not blockCol then
			blockCol = {}
			self.blockForPos[newBlockPos[1]] = blockCol
		end
		if not blockCol[newBlockPos[2]] then
			local block = Block{pos=newBlockPos}
			blockCol[newBlockPos[2]] = block
			self.blocks:insert(block)
			self.nextBlockTime = time() + self.spawnBlockDuration
		end
	end

	local ball = self.ball

	-- cheat AI
	for index,player in ipairs(players) do
		if not player.serverConn then
			if ball.pos[2] < player.y then
				player:move(-1)
			elseif ball.pos[2] > player.y then
				player:move(1)
			end
		end
	end

	-- update items
	for i=#self.items,1,-1 do
		local item = self.items[i]
		local itemNewPos = item.pos + item.vel * dt

		if item.pos[1] < 0 or item.pos[1] > worldSize then
			self.items:remove(i)
		else
			local minx, maxx = math.min(item.pos[1], itemNewPos[1]), math.max(item.pos[1], itemNewPos[1])
			for playerIndex,player in ipairs(players) do
				local playerX = Player.xForIndex[playerIndex]
				if playerX >= minx
				and playerX <= maxx
				and item.pos[2] >= player.y - player.size * .5
				and item.pos[2] <= player.y + player.size * .5
				then
					sfx(getItemSound)
					item:touch(player, self)
					self.items:remove(i)
					break
				end
			end
		end

		-- item may have been removed...
		item.pos = itemNewPos
	end

	-- update ball
	local step = ball.vel * dt * ball.speedScalar
	local newpos = ball.pos + step

	-- hit far wall?
	local reset = false
	if newpos[1] <= 0 then
		self.playerB.score = self.playerB.score + 1
		reset = true
	elseif newpos[1] >= worldSize then
		reset = true
		self.playerA.score = self.playerA.score + 1
	end
	if reset then
		self:reset()
		do return end
	end

	-- bounce off walls
	if newpos[2] < 0 and ball.vel[2] < 0 then
		sfx(blockHitSound)
		ball.vel[2] = -ball.vel[2]
	end
	if newpos[2] > worldSize and ball.vel[2] > 0 then
		sfx(blockHitSound)
		ball.vel[2] = -ball.vel[2]
	end

	-- bounce off blocks
	-- TODO traceline
	do
		local gridPos = vec2(
			newpos[1] / worldSize * self.blockGridSize,
			newpos[2] / worldSize * self.blockGridSize)
		local blockCol = self.blockForPos[math.ceil(gridPos[1])]
		if blockCol then
			local block = blockCol[math.ceil(gridPos[2])]
			if block then
				local delta = (block.pos - vec2(.5,.5)) - gridPos
				local absDelta = vec2(math.abs(delta[1]), math.abs(delta[2]))
				local n = vec2()
				if absDelta[1] > absDelta[2] then	-- left/right
					n[2] = 0
					if delta[1] > 0 then	-- ball left of block
						n[1] = -1
					else	-- ball right of block
						n[1] = 1
					end
				else	-- up/down
					n[1] = 0
					if delta[2] > 0 then	-- ball going down
						n[2] = -1
					else	-- ball going up
						n[2] = 1
					end
				end

				local nDotV = vec2.dot(n, ball.vel)
				if nDotV < 0 then
					-- hit block
					ball.vel = ball.vel - n * 2 * nDotV
					sfx(blockHitSound)

					-- and remove the block
					self.blocks:removeObject(block)
					blockCol[math.ceil(gridPos[2])] = nil

					if ball.lastHitPlayer
					and math.random() < .2
					then
						local item = Item()
						item.type = math.random(#item.types)
						item.pos[1] = newpos[1]
						item.pos[2] = newpos[2]
						item.vel[1] = -ball.lastHitPlayer.normal[1] * item.speed
						self.items:insert(item)
					end
				end
			end
		end
	end

	-- now test if it hits the paddle
	for index,player in ipairs(players) do
		local playerX = Player.xForIndex[index]

		local frac = (playerX - ball.pos[1]) / step[1]
		if frac >= 0 and frac <= 1 then
			-- ballX is playerX at this point
			local ballY = ball.pos[2] + step[2] * frac

			-- cull values outside of line segment
			if newpos[2] >= player.y - player.size * .5
			and newpos[2] <= player.y + player.size * .5
			then
				local nDotV = vec2.dot(player.normal, ball.vel)
				if nDotV < 0 then
					sfx(playerHitSound)

					ball.vel[1] = -ball.vel[1]
					ball.vel[2] = ((ballY - (player.y - player.size * .5)) / player.size * 2 - 1) * 2 * math.abs(ball.vel[1])
					ball.lastHitPlayer = player
				end
			end
		end
	end

	ball.pos = newpos
end


local game = Game()

update=||do
	for playerIndex,player in ipairs{game.playerA, game.playerB} do
		if btn('up',playerIndex-1) then
			player:move(-1)
		elseif btn('down',playerIndex-1) then	
			player:move(1)
		else
			player:move(0)
		end
	end

	matident()

	cls(0xf0)
	spr(
		2,
		game.ball.pos[1] - 4,
		game.ball.pos[2] - 4
	)

	for playerIndex,player in ipairs{game.playerA, game.playerB} do
		spr(
			0,
			Player.xForIndex[playerIndex],	-- pos
			player.y - (player.size>>1),
			2, 2,	-- sprites wide/high
			0,		-- orientation2D
			1/2,		-- scale x
			player.size/16	-- scale y
		)
	end

	for _,item in ipairs(game.items) do
		-- TODO rotate by 180 * time(),
		spr(
			64 + Item.types[item.type].color,
			item.pos[1] - 4,
			item.pos[2] - 4
		)
	end

	for _,block in ipairs(game.blocks) do
		spr(
			4,
			(block.pos[1]-1) / game.blockGridSize * worldSize,
			(block.pos[2]-1) / game.blockGridSize * worldSize,
			2, 2,
			0,
			worldSize / game.blockGridSize / 16,
			worldSize / game.blockGridSize / 16
		)
	end
	
	matident()
	for i=#messages,1,-1 do
		local message = messages[i]
		local timeFrac = (time() - message.startTime) / message.duration
		if timeFrac > 1 then
			messages:remove(i)
		else
			-- TOOD some weird effects
			local x = math.mix(message.startPos[1], message.endPos[1], timeFrac)
			local y = math.mix(message.startPos[2], message.endPos[2], timeFrac)
			local width = text(
				message.text,		-- text
				-100, -100,			-- pos
				-1, -1				-- color
			)
			text(
				message.text,		-- text
				x - .5 * width, y,	-- pos
				0xfc, -1			-- color
			)
		end
	end

	game:update()
end
