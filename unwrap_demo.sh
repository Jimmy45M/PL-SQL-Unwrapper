#
# Proof-of-concept to unwrap 10g+ wrapped code using basic Linux shell utilities
#
# Reads from standard input, writes to standard output.
#
# Assumes any Oracle installation will have access to a recent(ish) openssl with zlib support.
# If this is not available, there are reasonably simple alternatives using Python, Perl, etc.
#
# Testing performed on the Podman/docker container for Oracle 23ai Free.
#
# Note: This is for demonstration purposes only - it is *NOT* intended for production use.
# If you want a standalone 10g+ unwrapper we recommend translating (and simplyfing) the logic
# and other checks used in the PL/SQL version into something like Java, Python, Perl, etc.
#

# TR is a byte-by-byte translator and allows us to specify the translation using an octal sequence

CIPHER_FROM=$( for f in {0..255}; do printf '\%03o' $f; done)

CIPHER_TO="\
\075\145\205\263\030\333\342\207\361\122\253\143\113\265\240\137\175\150\173\233\044\302\050\147\212\336\244\046\036\003\353\027\
\157\064\076\172\077\322\251\152\017\351\065\126\037\261\115\020\170\331\165\366\274\101\004\201\141\006\371\255\326\325\051\176\
\206\236\171\345\005\272\204\314\156\047\216\260\135\250\363\237\320\242\161\270\130\335\054\070\231\114\110\007\125\344\123\214\
\106\266\055\245\257\062\042\100\334\120\303\241\045\213\234\026\140\134\317\375\014\230\034\324\067\155\074\072\060\350\154\061\
\107\365\063\332\103\310\343\136\031\224\354\346\243\225\024\340\235\144\372\131\025\305\057\312\273\013\337\362\227\277\012\166\
\264\111\104\132\035\360\000\226\041\200\177\032\202\071\117\301\247\327\015\321\330\377\023\223\160\356\133\357\276\011\271\167\
\162\347\262\124\267\052\307\163\220\146\040\016\121\355\370\174\217\056\364\022\306\053\203\315\254\313\073\304\116\300\151\066\
\142\002\256\210\374\252\102\010\246\105\127\323\232\275\341\043\215\222\112\021\211\164\153\221\373\376\311\001\352\033\367\316"

echo -n 'CREATE OR REPLACE '

tr -d '\r' | \
  awk -- '/^ *\/ *$/ { output = 0 }; output; /^[[:alnum:]]+ +[[:alnum:]]+ *$/ { output=1 };' | \
  base64 --decode --ignore-garbage | \
  tail --bytes=+21 | \
  tr "$CIPHER_FROM" "$CIPHER_TO" | \
  openssl zlib -d | \
  tr -d '\000'

echo
echo '/'
