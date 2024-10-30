w,h=32,32
hflip=0x4000
vflip=0x8000
sprites={
	empty=0,
	snakeUp=1,
	snakeDown=2,
	snakeLeft=3,
	snakeRight=4,
	fruit=6,
	snakeUpDown=32,
	snakeUpLeft=33,
	snakeUpRight=33|hflip,
	snakeDownLeft=33|vflip,
	snakeDownRight=33|hflip|vflip,
	snakeLeftRight=34,
	snakeEndUp=64,
	snakeEndDown=64|vflip,
	snakeEndLeft=65,
	snakeEndRight=65|hflip,
	snakeVertOverHorz=96,
	snakeHorzOverVert=97,
}
snakeBodies={
	[0]={
		[0]=sprites.snakeUpDown,
		[1]=sprites.snakeUpDown,
		[2]=sprites.snakeUpLeft,
		[3]=sprites.snakeUpRight,
	},
	[1]={
		[0]=sprites.snakeUpDown,
		[1]=sprites.snakeUpDown,
		[2]=sprites.snakeDownLeft,
		[3]=sprites.snakeDownRight,
	},
	[2]={
		[0]=sprites.snakeUpLeft,
		[1]=sprites.snakeDownLeft,
		[2]=sprites.snakeLeftRight,
		[3]=sprites.snakeLeftRight
	},
	[3]={
		[0]=sprites.snakeUpRight,
		[1]=sprites.snakeDownRight,
		[2]=sprites.snakeLeftRight,
		[3]=sprites.snakeLeftRight,
	},
	tail={
		[0]=sprites.snakeEndUp,
		[1]=sprites.snakeEndDown,
		[2]=sprites.snakeEndLeft,
		[3]=sprites.snakeEndRight,
	},
}

dirIndexForName={
	up=0,
	down=1,
	left=2,
	right=3,
}
dirNameForIndex=table.map(dirIndexForName,[v,k](k,v)):setmetatable(nil)
dirs={
	[0]={0,-1},
	[1]={0,1},
	[2]={-1,0},
	[3]={1,0},
}

local range=[a,b,c]do
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

local snakeHist=table()
pushSnakeHist=[]do
	snakeHist:insert(snake:mapi([s]
		(table(s):setmetatable(nil))
	))
end
popSnakeHist=[]do
	snake=snakeHist:remove()
	local head=snake[1]
	snakeX=head.x
	snakeY=head.y
	dir=head.dir
	done=false
end

reset=[]do
	for j=0,h-1 do
		for i=0,w-1 do
			mset(i,j,0)
		end
	end
	snakeHist=table()
	done=false
	dir=4
	snake=table()
	snakeX=tonumber(w//2)
	snakeY=tonumber(h//2)
	snake:insert{x=snakeX,y=snakeY,dir=dir}
end

snakeCalcSprite=[i]do
	local prevLinkDir = i>1 and snake[i-1].dir or nil
	local link = snake[i]
	local x=link.x
	local y=link.y
	local linkDir=link.dir
	local crossingOver=link.crossingOver
	local linkDone=link.done
	if crossingOver ~= nil then
		-- draw order matters now since we have two links at one point whose sprites differ
		if linkDir&2==0 then	-- moving up/down
			return crossingOver and sprites.snakeVertOverHorz or sprites.snakeHorzOverVert
		else
			return crossingOver and sprites.snakeHorzOverVert or sprites.snakeVertOverHorz
		end
	elseif #snake==1 then
		return sprites.snakeDown
	else
		if i==1 then
			if done then
				return snakeBodies[linkDir][linkDir~1]
			else
				return sprites.snakeUp + linkDir
			end
		elseif i==#snake then
			if done then
				return snakeBodies[prevLinkDir][prevLinkDir~1]	-- use prevLinkDir since linkDir for the tail is 4 / invalid
			else
				return snakeBodies.tail[prevLinkDir]
			end
		else
			return snakeBodies[prevLinkDir][linkDir~1]
		end
	end
end

redraw=[]do
	cls(1)
	map(0,0,w,h,0,0)
	local prevLinkDir
	for i,link in ipairs(snake) do
		local x=link.x
		local y=link.y
		local linkDir=link.dir
		local crossingOver=link.crossingOver
		local linkDone=link.done
		local spriteIndex = snakeCalcSprite(i)
		local sx = spriteIndex & hflip ~= 0
		local sy = spriteIndex & vflip ~= 0
		spr(spriteIndex&0x3ff,(x + (sx and 1 or 0))<<3,(y + (sy and 1 or 0))<<3,1,1,0,-1,0,0xff,sx and -1 or 1,sy and -1 or 1)
		prevLinkDir=linkDir
	end
end
snakeGet=[x,y]do
	for i=#snake,1,-1 do
		local link=snake[i]
		if link.x==x and link.y==y then 
			return snakeCalcSprite(i), i
		end
	end
	return sprites.empty
end

reset()
update=[]do
	redraw()

	if btnp(4) and #snakeHist>0 then
		popSnakeHist()
		if snake[1].crossingOver~=nil then	-- don't leave us hanging at a crossing
			popSnakeHist()
		end
		return
	end
	if btnp(6) then
		reset()
		return
	end
	if done then return end

	nextDir=nil
	if btnp(0,0,5,5) and dir ~= 1 then
		nextDir=0
	elseif btnp(1,0,5,5) and dir ~= 0 then
		nextDir=1
	elseif btnp(2,0,5,5) and dir ~= 3 then
		nextDir=2
	elseif btnp(3,0,5,5) and dir ~= 2 then
		nextDir=3
	end

	if nextDir then
		local moveVert=nextDir&2==0
		local moveHorz=not moveVert
		local dx,dy=table.unpack(dirs[nextDir])
		newX=snakeX+dx
		newY=snakeY+dy
		newX%=w
		newY%=h
		local spriteIndex,snakeIndex=snakeGet(newX, newY)

		-- check for free movement or overlap/underlap ...
		local blocked
		if spriteIndex~=sprites.empty then
			-- TODO multiple over/under?
			if (
				moveVert
				and (spriteIndex==sprites.snakeLeftRight)
				and snakeGet(newX+dx,newY+dy)==sprites.empty
			)
			or (
				moveHorz
				and (spriteIndex==sprites.snakeUpDown)
				and snakeGet(newX+dx,newY+dy)==sprites.empty
			)
			then
				-- skip
				local crossingOver = true
				if btn(5) or btn(7) then
					crossingOver = false
				end
				pushSnakeHist()
				snake[snakeIndex].crossingOver=not crossingOver
				snake:insert(1,{x=newX,y=newY,dir=nextDir,crossingOver=crossingOver})
				newX+=dx
				newY+=dy
			elseif moveVert and (spriteIndex==sprites.snakeEndUp or spriteIndex==sprites.snakeEndDown) then
				done=true
			elseif moveHorz and (spriteIndex==sprites.snakeEndLeft or spriteIndex==sprites.snakeEndRight) then
				done=true
			else
				blocked=true
			end
		end

		if not blocked then
			dir=nextDir
			pushSnakeHist()
			snake:insert(1,{x=newX,y=newY,dir=dir,done=done})
			snakeX,snakeY=newX,newY
		
			if done then
				classify()
			end
		end
	end
end

classify=[]do
	-- calc knot stuff
trace('#snake', #snake)				
	-- this is the indexes of all crossings
	local ci = range(#snake):filter([i]snake[i].crossingOver~=nil)
trace('got crossing indexes', ci:mapi(tostring):concat',')				
	if #ci & 1 == 1 then 
		trace"somehow you have an odd number of links at crossings..."
		return
	end
	-- this is the indexes of the unique crossing coordinates
	local coords = ci:mapi([i](
		true,snake[i].x..','..snake[i].y
	)):keys():mapi([c]do
		local x,y=string.split(c,','):mapi([x]tonumber(x)):unpack()
		return {x=x,y=y}
	end)

	local crossingIndexesForCoords = coords:mapi([coord]
 		(assert.len(ci:filter([i]
			snake[i].x==coord.x
			and snake[i].y==coord.y
		), 2), coord.x..','..coord.y)
	)
	local getOtherLink=[i]do
		local link = snake[i]
		local cis=assert.index(crossingIndexesForCoords,link.x..','..link.y)
		assert.len(cis,2)
		if cis[1]==i then return snake[cis[2]] end
		if cis[2]==i then return snake[cis[1]] end
		error'here'
	end

	-- [[ print crossing # of each crossing
	-- crossing sign is going to be based on direction and on over/under...
	-- if the top arrow goes along the x-axis towards x+ then the crossing sign is the direction of the bottom arrow (towards y- = -1, towards y+ = +1)
	do
		for _,i in ipairs(ci) do
			local link = snake[i]
			local link2 = getOtherLink(i)
			local dir1 = link.dir
			local dir2 = link2.dir
			if link.crossingOver == false then
				dir1,dir2 = dir2,dir1
			elseif link.crossingOver ~= true then
				error'unknown crossing state at crossing link'
			end
			-- TODO this would all be much more simplified if my directions were in angle order
			local crossingSign
			if dir1==dirIndexForName.up then
				if dir2==dirIndexForName.left then
					crossingSign=1
				elseif dir2==dirIndexForName.right then
					crossingSign=-1
				else
					error'here'
				end
			elseif dir1==dirIndexForName.down then
				if dir2==dirIndexForName.right then
					crossingSign=1
				elseif dir2==dirIndexForName.left then
					crossingSign=-1
				else
					error'here'
				end		
			elseif dir1==dirIndexForName.left then
				if dir2==dirIndexForName.down then
					crossingSign=1
				elseif dir2==dirIndexForName.up then
					crossingSign=-1
				else
					error'here'
				end		
			elseif dir1==dirIndexForName.right then
				if dir2==dirIndexForName.up then
					crossingSign=1
				elseif dir2==dirIndexForName.down then
					crossingSign=-1
				else
					error'here'
				end
			end
trace('dir1', dirNameForIndex[dir1], 'dir2', dirNameForIndex[dir2], 'crossingSign', crossingSign)
		end
		return
	end
	--]]


	local n = #ci>>1
trace('# crossings', n)	
	if n==0 then
trace('V(t) = 1') 				
	else
		local t={}
		for i=1,n do t[i]={} end
		
		for i=1,n do
			for j=1,n do
				if i==j then
					local spriteIndex = snakeCalcSprite(ci[i<<1])
					t[i][j] = spriteIndex == sprites.snakeVertOverHorz and 0 or 1 
				else
					-- "count the # of times mod 2 we pass the i'th crossing" ...
					-- it's gonna be 0 or 1 always by the constraints of my system ...
					t[i][j] = 1
				end
			end
		end
trace'T='
		for i=1,n do
local str=table()					
			for j=1,n do
str:insert(t[i][j])
			end
trace(str:mapi(tostring):concat', ')					
		end
		-- 
	end
end
