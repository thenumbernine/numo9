local fontWidthAddr = ramaddr'fontWidth'
for i=0,255 do
	poke(fontWidthAddr+i,8)
end

math.randomseed(tstamp())

--#include ext/class.lua
--#include vec/vec2.lua
--#include vec/box2.lua

mode(42)	-- 16:9 480x270x8bpp-indexed
local screenSize = vec2(480, 270)

tilemapTiles={
	floor = 80 | 0x400,
	wall =  0 | 0x400,
}

sprites={
	Player = 0,
	Spider = 2,
	Snake = 4,
	Lobster = 6,
	Cat = 8,
	Blob = 10,
	Imp = 12,
	Wolf = 14,
	Goblin = 16,
	Dwarf = 18,
	Human = 20,
	Elf = 22,
	Zombie = 24,
	Troll = 26,
	Gargoyle = 28,
	Golem = 30,
	Ogre = 1<<6,
	Bull = 1<<6 | 2,
	Lion = 1<<6 | 4,
	Liger = 1<<6 | 6,
	Giant = 1<<6 | 8,
	Dragon = 1<<6 | 10,
	['T-Rex'] = 1<<6 | 12,
	Treasure = 2<<6,
}

dirs = {
	'up',
	'down',
	'left',
	'right',
	up=vec2(0,-1),
	down=vec2(0,1),
	left=vec2(-1,0),
	right=vec2(1,0),
}

setFieldsByRange=|obj,fields|do
	for _,field in ipairs(fields) do
		local range = obj[field..'Range']
		if range then
			local lo, hi = range:unpack()
			assert(hi >= lo, "item "..obj.name.." field "..field.." has interval "..tostring(hi)..","..tostring(lo))
			obj[field] = math.random() * (hi - lo) + lo
		end
	end
end

capitalize=|s|s:sub(1,1):upper()..s:sub(2)

serializeTable=|obj|do
	local lines = table()
	lines:insert'{'
	for _,row in ipairs(obj) do
		local s = table()
		for k,v in pairs(row) do
			if type(k) ~= 'string' then k = '['..k..']' end
			v = ('%q'):format(tostring(v))
			s:insert(k..'='..v)
		end
		lines:insert('\t{'..s:concat'; '..'};')
	end
	lines:insert'}'
	return lines:concat'\n'
end
tiletypes = {
	floor = {
		char = '.',
		sprite = tilemapTiles.floor,
	},
	wall = {
		char = '0',
		solid = true,
		sprite = tilemapTiles.wall,
	},
}

con={
	locate=|x,y|do
		con.x=x
		con.y=y
	end,
	write=function(s)
		text(s,(con.x-1)<<3,(con.y-1)<<3,12,16)
		con.x+=#s
	end,
	clearline = function()
		rect(con.x<<3,con.y<<3,screenSize.x,8,16)
		con.x=1
		con.y+=8
	end,
}

--#include log.lua
--#include map.lua
--#include battle.lua
--#include entity.lua
--#include army.lua
--#include unit.lua
--#include player.lua
--#include treasure.lua
--#include items.lua
--#include monster.lua
--#include ui.lua
--#include view.lua
--#include client.lua

game = {
	time = 0,
	done = false,
	paused = false,
}

ents = table()
battles = table()

client = Client()
client.army.affiliation = 'good'
Player{pos=(map.size/2):floor(), army=client.army}

for i=1,math.floor(map.size:product() / 131) do
	local e = Monster{
		pos=vec2( math.random(map.size.x), math.random(map.size.y) ),
		army = Army{affiliation='evil'..math.random(4)},
	}
	map.tiles[e.pos.x][e.pos.y].type = tiletypes.floor
end

for i=1,math.floor(map.size:product() / 262) do
	local e = Treasure{
		pos=vec2( math.random(map.size.x), math.random(map.size.y) ),
		gold = math.random(100) + 10,
		army = Army(),
		pickupRandom = true,
	}
	map.tiles[e.pos.x][e.pos.y].type = tiletypes.floor
end

for i=1,math.floor(map.size:product() / 500) do
	local e = Player{
		pos=vec2( math.random(map.size.x), math.random(map.size.y) ),
		gold = math.random(10),
		army = Army{affiliation='good'},
	}
	map.tiles[e.pos.x][e.pos.y].type = tiletypes.floor
end


render=||do
	cls(0xf0)

	if client.army.currentEnt then
		view:update(client.army.currentEnt.pos)
	else
		view:update(client.army.leader.pos)
	end

	local v = vec2()
	for i=1,view.size.x do
		v.x = view.delta.x + i
		for j=1,view.size.y do
			v.y = view.delta.y + j

			if map.bbox:contains(v) then
				local tile = map.tiles[v.x][v.y]
				if tile:isRevealed() then
					tile:draw(i * 16, j * 16)

					local topEnt
					if tile.ents then
						topEnt = assert(tile.ents[1])
						for k=2,#tile.ents do
							local ent = tile.ents[k]
							if ent.zOrder > topEnt.zOrder then
								topEnt = ent
							end
						end

						topEnt:draw(i * 16, j * 16)
					end
				end
			end
		end
	end

	for _,battle in ipairs(battles) do
		local mins = battle.bbox.min - view.delta - 1
		local maxs = battle.bbox.max - view.delta + 1
		view:drawBorder(box2(mins,maxs))
	end

	local y = 1
	local printright=|s|do
		if s then
			con.locate(ui.size.x+2,y)
			con.write(s)
		end
		y = y + 1
	end

	if client.army.battle then
		printright'Battle:'
		printright'-------'
		for _,ent in ipairs(client.army.ents) do
			printright('hp '..ent.hp..'/'..ent:stat'hpMax')
			printright('move '..ent.movesLeft..'/'..ent:stat'move')
			printright('ct '..ent.ct..'/100')
			printright()
		end
	end

	printright'Commands:'
	printright'---------'

	if client.cmdstate then
		for k,cmd in pairs(client.cmdstate.cmds) do
			if not (cmd.disabled and cmd.disabled(client, cmd)) then
				printright(k..' = '..cmd.name)
			end
		end
	end

	for _,state in ipairs(client.cmdstack) do
		if state and state.draw then
			state.draw(client, state)
		end
	end
	if client.cmdstate and client.cmdstate.draw then
		client.cmdstate.draw(client, client.cmdstate)
	end

	log:render()
end

gameUpdate=||do
	if not game.paused then
		for _,ent in ipairs(ents) do
			ent:update()
		end

		for _,battle in ipairs(battles) do
			battle:update()
		end
	end
	render()
end

update=||do
	client:update()
	game.time = game.time + 1
	gameUpdate()
end

-- init draw
gameUpdate()
render()
flip()
render()
