--[[
doing knot theory stuff
https://core.ac.uk/download/pdf/81160141.pdf
https://homepages.warwick.ac.uk/~maaac/TimL.html
--]]
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

table.equals=[a,b]do
	local ka=table.keys(a)
	local kb=table.keys(b)
	if #ka~=#kb then return false end
	for _,k in ipairs(ka) do
		if a[k]~=b[k] then return false end
	end
	return true
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
	knotMsg=nil
	knotMsgTime=nil
	knotMsgWidth=0
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
				return snakeBodies[linkDir][snake[#snake-1].dir~1]
			else
				return sprites.snakeUp + linkDir
			end
		elseif i==#snake then
			if done then
				return snakeBodies[prevLinkDir][snake[1].dir~1]	-- use prevLinkDir since linkDir for the tail is 4 / invalid
			else
				return snakeBodies.tail[prevLinkDir]
			end
		else
			return snakeBodies[prevLinkDir][linkDir~1]
		end
	end
end

local knotNames = table{
	'0_1',
	'3_1',
	'4_1',
	'5_1', '5_2',
	'6_1', '6_2', '6_3',
	'7_1', '7_2', '7_3', '7_4', '7_5', '7_6', '7_7',
}
local knotNameSet = knotNames:mapi([v](true,v)):setmetatable(nil)
-- per each knot we track, record the time to draw and the number of links
local knotStats = {}

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
	if knotMsg then
		if knotMsgWidth > 256 then
			-- cycle back and forth
			local cycle = knotMsgWidth - 256
			knotMsgX = (time()*32) % (4 * cycle)
			if knotMsgX < cycle then
				knotMsgX = -cycle
			elseif knotMsgX < 2*cycle then
				knotMsgX = -2*cycle+knotMsgX	-- -cycle to 0
			elseif knotMsgX < 3*cycle then
				knotMsgX = 0
			else
				knotMsgX = -(knotMsgX - 3*cycle)	-- 0 to -cycle
			end
		else
			knotMsgX = math.min((time()-knotMsgTime)*32, 256-knotMsgWidth)
		end
		knotMsgWidth = text(knotMsg,knotMsgX,0,0xfc,0xf0)
	end
	for i,name in ipairs(knotNames) do
		local knotStat = knotStats[name]
		if knotStat then
			text(name..' '..tostring(knotStat.len), 0, i<<3, 0xfc, 0xf0)
		else
			text(name..' '..'*', 0, i<<3, 0xfc, 0xf0)
		end
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

inSplash=true
reset()
update=[]do
	if inSplash then
		cls(0x10)
		local x,y = 24, 48
		local txt=[s]do text(s,x,y,0xc,-1) y+=8 end
		txt'KNOTS!!!!'
		txt'tie the snake in a knot'
		txt'try to find all the prime knots'
		txt'then try to complete them in the least steps'
		txt''
		txt'arrows = move'
		txt'press KP-S / JP-A to undo a move'
		txt'hold KP-X / JP-B to duck under'
		txt'press KP-A / JP-X to reset'
		txt''
		txt'press any JP button to continue...'
		for i=0,7 do
			if btnr(i) then
				inSplash=false
			end
		end
		return
	end
	redraw()

	if btnp(4,0,5,5) and #snakeHist>0 then
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
		local crossingOver
		if spriteIndex~=sprites.empty then
			-- TODO multiple over/under?
			if (
				moveVert
				and (spriteIndex==sprites.snakeLeftRight)
				--and snakeGet(newX+dx,newY+dy)==sprites.empty
			)
			or (
				moveHorz
				and (spriteIndex==sprites.snakeUpDown)
				--and snakeGet(newX+dx,newY+dy)==sprites.empty
			)
			then
				-- skip
				crossingOver = true
				if btn(5) or btn(7) then
					crossingOver = false
				end
				--pushSnakeHist()
				--snake[snakeIndex].crossingOver=not crossingOver
				--snake:insert(1,{x=newX,y=newY,dir=nextDir,crossingOver=crossingOver})
				--newX+=dx
				--newY+=dy
			--[[ only allow move into the tail from same dir ...
			elseif moveVert and (spriteIndex==sprites.snakeEndUp or spriteIndex==sprites.snakeEndDown) then
				done=true
			elseif moveHorz and (spriteIndex==sprites.snakeEndLeft or spriteIndex==sprites.snakeEndRight) then
				done=true
			--]]
			-- [[ allow move into tail from any dir
			elseif spriteIndex==sprites.snakeEndUp
			or spriteIndex==sprites.snakeEndDown
			or spriteIndex==sprites.snakeEndLeft
			or spriteIndex==sprites.snakeEndRight
			then
				done=true
			--]]
			else
				blocked=true
			end
		end

		if not blocked then
			dir=nextDir
			pushSnakeHist()
			if crossingOver~=nil then
				snake[snakeIndex].crossingOver=not crossingOver
			end
			snake:insert(1,{x=newX,y=newY,dir=dir,done=done,crossingOver=crossingOver})
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
	local crossingIndexes = range(#snake):filter([i]snake[i].crossingOver~=nil)
trace('got crossing indexes', crossingIndexes:mapi(tostring):concat',')
	if #crossingIndexes & 1 == 1 then
		trace"somehow you have an odd number of links at crossings..."
		return
	end
	-- this is the indexes of the unique crossing coordinates
	local crossingCoords = crossingIndexes:mapi([i](
		true,snake[i].x..','..snake[i].y
	)):keys():mapi([c]do
		local x,y=string.split(c,','):mapi([x]tonumber(x)):unpack()
		return {x=x,y=y}
	end)
	assert.eq(#crossingCoords<<1, #crossingIndexes)

	-- key = coord string, value = table of snake link indexes
	local crossingIndexesForCoords = crossingCoords:mapi([coord]
 		(assert.len(crossingIndexes:filter([i]
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
	local crossingSigns={}	-- index is the snake link index
	do
		for _,i in ipairs(crossingIndexes) do
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
			-- then we get crossingSign=(dir2-dir1)%4 ... and then 3=>-1
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
			crossingSigns[i]=crossingSign
		end
	end
	-- assert all crossing signs of a coord are the same
	for i,coord in ipairs(crossingCoords) do
		local key = coord.x..','..coord.y
		local is = crossingIndexesForCoords[key]
		assert.len(is, 2)
		assert.eq(crossingSigns[is[1]], crossingSigns[is[2]])
	end
	--]]

	local polyToStr=[p]do
		local s = p:keys():sort([a,b]a>b):mapi([exp,_,t]do
			local o = table()
			local v = p[exp]
			local sign = '+'
			if v<0 then
				v=math.abs(v)
				sign = '-'
			end
			if v~=1 then o:insert(v) end
			if exp~=0 then
				local sexp
				if exp==1 then
					sexp = 't'
				else
					sexp = 't^'..exp
				end
				o:insert(sexp)
			end
			return (#t>0 and ' '..sign..' ' or (sign=='-' and sign or ''))
				..(#o==0 and '1' or o:concat'*'),
				#t+1
		end)
		return #s==0 and '0' or s:concat()
	end
	local polyName=[p]do
		if p:equals{															  							   [0]=1																			} then return '0_1' end
		if p:equals{													   [-4]=-1, [-3]=1,			  [-1]=1																					} then return '3_1' end
		if p:equals{															  			 [-2]=1,  [-1]=-1, [0]=1,  [1]=-1, [2]=1															} then return '4_1' end
		if p:equals{							[-7]=-1, [-6]=1,  [-5]=-1, [-4]=1, 			 [-2]=1																								} then return '5_1' end
		if p:equals{									 [-6]=-1, [-5]=1,  [-4]=-1, [-3]=2,  [-2]=-1, [-1]=1																					} then return '5_2' end
		if p:equals{													   [-4]=1,  [-3]=-1, [-2]=1,  [-1]=-2, [0]=2,  [1]=-1, [2]=1															} then return '6_1' end
		if p:equals{											  [-5]=1,  [-4]=-2, [-3]=2,  [-2]=-2, [-1]=2,  [0]=-1, [1]=1																	} then return '6_2' end
		if p:equals{															    [-3]=-1, [-2]=2,  [-1]=-2, [0]=3,  [1]=-2, [2]=2,  [3]=-1													} then return '6_3' end
		if p:equals{[-10]=-1, [-9]=1,  [-8]=-1, [-7]=1,  [-6]=-1, [-5]=1,		    [-3]=1																										} then return '7_1' end
		if p:equals{				   [-8]=-1, [-7]=1,  [-6]=-1, [-5]=2,  [-4]=-2, [-3]=2,	 [-2]=-1, [-1]=1																					} then return '7_2' end
		if p:equals{																										   [2]=1,  [3]=-1, [4]=2,  [5]=-2, [6]=3,  [7]=-2, [8]=1, [9]=-1	} then return '7_3' end
		if p:equals{																								   [1]=1,  [2]=-2, [3]=3,  [4]=-2, [5]=3,  [6]=-2, [7]=1,  [8]=-1			} then return '7_4' end
		if p:equals{		  [-9]=-1, [-8]=2,  [-7]=-3, [-6]=3,  [-5]=-3, [-4]=3,  [-3]=-1, [-2]=1																								} then return '7_5' end
		if p:equals{									 [-6]=-1, [-5]=2,  [-4]=-3, [-3]=4,  [-2]=-3, [-1]=3,  [0]=-2, [1]=1																	} then return '7_6' end
		if p:equals{																[-3]=-1, [-2]=3,  [-1]=-3, [0]=4,  [1]=-4, [2]=3,  [3]=-2, [4]=1											} then return '7_7' end
	end
	local polyNameOrStr=[p]do
		return polyName(p)
		or polyName(p:map([coeff,exp](coeff,-exp)))		-- t -> t^-1 ... is that right?
		or ' V(t)='..polyToStr(p)
	end

	local poly=table()
	local n = #crossingCoords
trace('# crossings', n)
	if n==0 then
		poly=table{[0]=1}
	else

		local writhe=0
		for i=1,n do
trace('i', i)
			local coordI = crossingCoords[i]
trace('coordI', coordI.x..','..coordI.y)
			local k = crossingIndexesForCoords[coordI.x..','..coordI.y]
trace('crossing indexes', k:concat' ')
			writhe+=crossingSigns[k[1]]
		end
trace('writhe', writhe)

		local tripMatrix=range(n):mapi([i]do
			local coordI = crossingCoords[i]
			local coordIKey = coordI.x..','..coordI.y
			local firstLinkIndexAtCrossingCoordI = assert.index(crossingIndexesForCoords[coordIKey], 1)
			return range(n):mapi([j]do
				local coordJ = crossingCoords[j]
				local coordJKey = coordJ.x..','..coordJ.y
				if i==j then
					-- all indexes per-coord-key in crossingIndexesForCoords have the same crossing sign ...
					-- source says sign==1 means diagonal==0 but my signs are all -1 so my trefoil knot is opposite the Zulli paper
					local sign = assert.index(crossingSigns, firstLinkIndexAtCrossingCoordI)
					return sign==1 and 0 or 1
				else
					-- "count the # of times mod 2 we pass the i'th crossing" ...
					-- ... won't that always be 2 times?  I'm missing something.
					-- the other papers say this is the # times we cross any crossing that it goes against the arrow of positive-sign at that crossing
					-- and since it's just passing one point
					-- and since it's mod 2
					-- it's just the parity of the one link when starting from the other
					local result = 0
					for k=1,#snake do
						local link = snake[((firstLinkIndexAtCrossingCoordI-1+k)%#snake)+1]
						local coordKey = link.x..','..link.y
						if coordKey == coordIKey then break end
						if coordKey == coordJKey then
							-- then increment ... something ... based on what ...
							result += 1
						end
					end
					return result & 1
				end
			end)
		end)
trace'tripMatrix='
for i=1,n do
trace(tripMatrix[i]:mapi(tostring):concat',')
end

		local numStates = 1 << n
		for i=0,numStates-1 do
			local state = range(0,n-1):mapi([j]((i>>j)&1))
			local ABs={[0]=0,[1]=0}
			for j,statej in ipairs(state) do
				ABs[statej]+=1
			end
			local A,B=ABs[0],ABs[1]

			local stateMatrix=range(n):mapi([i]
				range(n):mapi([j]do
					if i==j then
						return (state[i] + tripMatrix[i][j]) & 1
					else
						return tripMatrix[i][j]
					end
				end)
			)

			local m=range(n):mapi([i] table(stateMatrix[i]))
			local swapRows=[i1,i2]do
				for j=1,n do
					m[i1][j],m[i2][j]=m[i2][j],m[i1][j]
				end
			end
			local subRows=[i1,i2]do
				for j=1,n do
					m[i1][j]=(m[i1][j]-m[i2][j])&1
				end
			end
			local imax=n
			for j=1,n-1 do
				local maxZero=1
				for i=1,imax do
					if m[i][j]==0 then
						maxZero=math.max(maxZero,i)
					else
						if i<n then
							if m[i+1][j]==0 then
								swapRows(i,i+1)
							elseif m[i+1][j]==1 then
								subRows(i,i+1)
							else
								error'here'
							end
							maxZero=math.max(maxZero,i)
						end
					end
				end
				imax=maxZero
			end

			local nullity=0
			for i=1,n do
				if m[i]:sum()==0 then nullity+=1 end
			end
trace('state', state:concat(), 'nullity', nullity, 'A='..A, 'B='..B, 'A-B='..(A-B))

			local statePoly=table()
			local sign=-1
			for r=0,nullity do
				sign*=-1
				local num,denom=1,1
				for s=0,r-1 do
					num*=nullity-s
					denom*=s+1
				end
--trace('num='..num..' denom='..denom)
				local coeff=math.floor(num/denom)
				local exp=4*r-2*nullity
				statePoly[exp]=(statePoly[exp] or 0) + coeff
			end
			-- multiply statePoly by `sign*t^(A-B)`
			statePoly=statePoly:map([coeff,exp](coeff*sign,exp+A-B))
trace('statePoly', polyToStr(statePoly))
			-- add statePoly to poly
			for exp,coeff in pairs(statePoly) do
				poly[exp]=(poly[exp] or 0) + coeff
			end
			--poly=poly:filter([coeff,exp]coeff~=0)
			for _,k in ipairs(table.keys(poly)) do if poly[k]==0 then poly[k]=nil end end
trace('V(t) so far', polyToStr(poly))

			-- yield so we can kill it if it gets out of hand
			flip()
		end

		-- sign = (-1)^(3*w) ... = (-1)^(2*w) * (-1)^w ... = (-1)^w
		local sign = writhe&1==0 and 1 or -1
		-- multiply poly by `sign*t^(-3*w)`
		poly=poly:map([coeff,exp](coeff*sign,3*writhe-exp))
			--:filter([coeff,exp]coeff~=0)
		for _,k in ipairs(table.keys(poly)) do if poly[k]==0 then poly[k]=nil end end
	end

	-- it's a poly of the 4th root, and looks like the powers are all 4s, so ...
	poly=poly:map([coeff,exp](coeff,exp/4))

	local knotName = polyNameOrStr(poly)
	knotMsg = 'len='..(#snake-1)..' knot='..knotName
trace(knotMsg)
	knotMsgTime=time()
	if knotNameSet[knotName] then
		local newlen = #snake-1
		local oldlen = knotStats[knotName]?.len or math.huge
		if newlen < oldlen then
			knotStats[knotName] = {len=newlen}
		end
	end
end
