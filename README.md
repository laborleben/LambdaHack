LambdaHack [![Build Status](https://secure.travis-ci.org/LambdaHack/LambdaHack.png)](http://travis-ci.org/LambdaHack/LambdaHack)[![Build Status](https://drone.io/github.com/LambdaHack/LambdaHack/status.png)](https://drone.io/github.com/LambdaHack/LambdaHack/latest)
==========

This is an alpha release of LambdaHack, a [Haskell] [1] game engine
library for [roguelike] [2] games of arbitrary theme, size and complexity,
packaged together with a small example dungeon crawler. When completed,
the engine will let you specify content to be procedurally generated,
define the AI behaviour on top of the generic content-independent rules
and compile a ready-to-play game binary, using either the supplied
or a custom-made main loop. Several frontends are available
(GTK is the default) and many other generic engine components
are easily overridden, but the fundamental source of flexibility lies
in the strict and type-safe separation of code and content and of clients
(human and AI-controlled) and server. Long-term goals for LambdaHack include
support for multiplayer tactical squad combat, in-game content creation,
auto-balancing and persistent content modification based on player behaviour.

The engine comes with a sample code for a little dungeon crawler,
called LambdaHack and described in `PLAYING.md`. The engine and the example
game are bundled together in a single [Hackage] [3] package.
You are welcome to create your own games by modifying the sample game
and the engine code, but please consider eventually splitting your changes
into a separate Hackage package that depends on the upstream library,
to help us exchange ideas and share improvements to the common code.

Games known to use the LambdaHack library:

* [Allure of the Stars] [6], a near-future Sci-Fi game in early development
* [Space Privateers] [8], an adventure game set in far future


Compilation and installation
----------------------------

The library is best compiled and installed via Cabal (already a part
of your OS distribution, or available within [The Haskell Platform] [7]),
which also takes care of all the dependencies. The latest official
version of the library can be downloaded automatically by Cabal
from [Hackage] [3] as follows

    cabal install LambdaHack

For a newer snapshot, download source from a development branch
at [github] [5] and run Cabal from the main directory

    cabal install

For the example game, the best frontend (wrt keyboard support and colours)
is the default gtk. To compile with one of the terminal frontends,
use Cabal flags, e.g,

    cabal install -fvty


Compatibility notes
-------------------

The current code was tested with GHC 7.6 and 7.8,
but should also work with other GHC versions.

If you are using the terminal frontends, numerical keypad may not work
correctly depending on versions of the libraries, terminfo and terminal
emulators. The curses frontend is not fully supported due to the limitations
of the curses library. With the vty frontend run in an xterm,
CTRL-keypad keys for running seem to work OK, but on rxvt they do not.
Laptop (uk8o79jl) and Vi keys (hjklyubn, if enabled in config.ui.ini)
should work everywhere regardless. GTK works fine, too.


Testing and debugging
---------------------

The `Makefile` contains many sample test commands. All commands that use
the screensaver game modes (AI vs. AI) and the dumb `stdout` frontend
are gathered in `make test`. Of these, travis runs `test-travis-*`
on each push to the repo. Test commands with prefix `frontend` start
AI vs. AI games with the standard, user-friendly frontend.

Run `LambdaHack --help` to see a brief description of all debug options.
Of these, `--sniffIn` and `--sniffOut` are very useful (though verbose
and initially cryptic), for monitoring the traffic between clients
and the server. Some options in the config file may prove useful too,
though they mostly overlap with commandline options (and will be totally
merged at some point).

You can use HPC with the game as follows (a quick manual playing session
after the automated tests would be in order, as well, since the tests don't
touch the topmost UI layer).

    cabal clean
    cabal install --enable-library-coverage
    make test
    hpc report --hpcdir=dist/hpc/mix/LambdaHack-0.2.14/ LambdaHack
    hpc markup --hpcdir=dist/hpc/mix/LambdaHack-0.2.14/ LambdaHack

Note that debug option `--stopAfter` is required to cleanly terminate
any automated test that is used to gather HPC info, because HPC needs
a clean exit (to save data files).


Further information
-------------------

For more information, visit the [wiki] [4]
and see `GameDefinition/PLAYING.md`, `CREDITS` and `LICENSE`.

Have fun!



[1]: http://www.haskell.org/
[2]: http://roguebasin.roguelikedevelopment.org/index.php?title=Berlin_Interpretation
[3]: http://hackage.haskell.org/package/LambdaHack
[4]: https://github.com/LambdaHack/LambdaHack/wiki
[5]: http://github.com/LambdaHack/LambdaHack
[6]: http://allureofthestars.com
[7]: http://www.haskell.org/platform
[8]: https://github.com/tuturto/space-privateers
