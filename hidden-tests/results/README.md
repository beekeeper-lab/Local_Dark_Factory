# Hidden test output

Full output from hidden-test runs. Outside every repo the line builds in,
because the run directory is inside the repo under test and the worker mounts
that repo whole.

Nothing prunes this directory. One file per run per bean, a few kilobytes each,
and they are the only place a hidden-test failure is written in full — so they are
kept until someone decides otherwise rather than rotated by a script that would
have to guess which one somebody still wants.
