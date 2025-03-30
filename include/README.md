I bet you're thinking this is some kind of header folder for the Fantasy Console itself.

Didn't you read the root level README?  There's no compiler required.  That means no include files.

Nope.

This folder is for code snippets that are preprocess-included into the carts upon archive.  Similar to pico-8's `#include`.

I don't like this feature honestly.  I'd rather add support for multiple files, virtual-filesystem mount-points, and a proper `require` function within the fantasy console virtual filesystem.
Maybe some day. I guess tic80's multi-file-projects do this too, idk?
