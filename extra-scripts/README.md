Here's some extrasscripts I found useful at one time or another.

By the way, in the ../../mesh/ folder is `chopupboxes.lua` and `chopupboxes2.lua`, which are useful for chopping up `.obj` files into unit boxes, great for making meshes for voxelmaps.  They output to [0,1], so from there you'll have to `* 128` and then `- 64` to the vertexes... and of course transform your texcoords to your own liking.
