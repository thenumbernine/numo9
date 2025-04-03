# TODO

- dif shaped key sprites for identification
- dif shaped map blocks for art or whatever
- map generation
	- smooth cornered map blocks for vis ...
	- or, I swapped out the zeta3d map gen ... it's so so ... 16 seems too big and 8 seems too small, i might npo2 the map block sizes ...
	- in map gen, not just keys but also dif barriers / items to break them, dif bosses, etc.


- dif types of monsters
- dif stats of monsters prop to progress in game
- power ups for health, damage, etc
- hide keys etc in monsters
- proper respawn / room-groups

- add extra later-doors between old previous-rooms
- room types ... water acid heat laval etc
- hide stuff in blocks / x-ray from distance and from angle all in realtime

- weapon powerups = dif colors unlocked, gameplyy is like ikaruga - you can switch colors, absorb shots colors (or weak % damage or something)
	and dif monsters have their color % for defense and their shot colors, and bullet hell, so gameplay is all about switching your colors back and forth while dodging shots and shooting monsters
	- weapons list ... how about 5 dif colors ... and skill trees per-color, so each color has its own style of attacks lol skill tree ...

- then dif keys correlate with dif items ... ?
	or dif keys = weapon-color + weapon-level
	and dif weapon skill-tree upgrades have dif levels associated with them ...

# BUGS
- clamp the map() render so it doesn't wrap -- we're seeing ghost rooms on edges
- item display wrap
