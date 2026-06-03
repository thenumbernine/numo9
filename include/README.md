I bet you're thinking this is some kind of header folder for the Fantasy Console itself.

Didn't you read the root level README?  There's no compiler required.  That means no include files.

Nope.

It can be used for either `#include` preprocessor for directly injecting code, or for `require()` file-scope code blocks/modules.

Static analysis at archive time will determine what additional `include/` files need to be packaged.
