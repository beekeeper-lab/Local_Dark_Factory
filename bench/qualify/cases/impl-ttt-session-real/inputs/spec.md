# bean-004 — Headless game session owning the human-versus-O flow

## What and why

This repository builds a desktop tic-tac-toe against the computer as a
headless Python package, one approved "bean" at a time. Beans 001–003 have
already landed in this tree: `src/tictactoe/game.py` holds the entire rule
set (the 3x3 board, legal moves, the eight winning lines, win and draw
detection) and `src/tictactoe/strategy.py` picks the computer player's O
move in a fixed deterministic order (win, block, center, corners, sides).
What does not exist yet is anything that *owns a game as a whole*: right now
a caller would have to remember to alternate turns, call the strategy after
every human move, stop when the game ends, and decide what to say to the
human. This bean adds one module for exactly that:
`src/tictactoe/session.py` with a `GameSession` class that plays one whole
game headlessly — the human's X move, O's immediate reply through the
strategy, the ending, and the reset — and that imports no GUI toolkit, so
it runs in a container with no display where `import tkinter` fails. Two
design questions were settled upstream with the person and are pinned here:
on a draw the result message is "It's a draw.", and after any result a
New Game action clears the board with the human starting again as X. The
session is the layer the later Tkinter window (bean-005) renders over:
that window will be deliberately thin — draw the board, forward clicks to
`move`, show `message` — which is why every decision of this bean must be
decidable without a display. The contract the bean fixes, in full: a fresh
session is an empty board with X to move and no result or message;
`move(cell)` places the human's X on `cell`, applies the rule set's
legality rules (a `ValueError` for an occupied or out-of-range cell while
the game is live, changing nothing), then — unless that move just ended the
game — O replies through the strategy; once the game is over, further
`move` calls are ignored entirely (no exception, no board change, including
for out-of-range indices); the outcome is exposed as `win`, `loss` or
`draw` plus the exact message the window will show — "You win.
Congratulations.", "You lost. Better luck next time." or "It's a draw.";
and `new_game()` resets to an empty board with X to move and no result or
message. Everything is proven by headless tests in
`tests/test_session.py` (seven, one per acceptance criterion) that script
real game lines through the real strategy rather than mocking it.

## Current behaviour

`src/tictactoe/session.py` and `tests/test_session.py` do not exist yet, and
nothing in the repository plays even one complete game: the four existing
test files (smoke, board, winner, strategy) each exercise one layer, and a
`GameSession` would stand on top of exactly these two, both of which
bean-004 may not modify. The two pieces it composes, as they exist today:

```python
# src/tictactoe/game.py (abridged; unchanged by this bean)
class Board:
    """A 3x3 board: nine cells, each empty, X or O, plus whose turn it is."""
    def __init__(self) -> None:
        self.cells: list[str] = [EMPTY] * 9
        self.turn: str = X                      # the human's mark moves first

    def apply_move(self, index: int) -> None:   # the legality the session reuses:
        if not 0 <= index <= 8:                 #   out-of-range ->
            raise ValueError(f"index out of range: {index}")
        if self.cells[index] != EMPTY:          #   occupied ->
            raise ValueError(f"cell already occupied: {index}")
        self.cells[index] = self.turn           #   otherwise place and flip turn
        self.turn = O if self.turn == X else X

    def winner(self) -> str:    # mark of the winner, or EMPTY when none
        ...
    def is_draw(self) -> bool:  # full board, no winner
        ...
```

```python
# src/tictactoe/strategy.py (abridged; unchanged by this bean)
def choose_move(board: Board, symbol: str) -> int:
    """Tries, in strict order: own win, block, center, corner, side;
    lowest cell index breaks every tie."""
    if board.winner() != EMPTY or board.is_draw():
        raise ValueError(f"game is already over: {board.cells!r}")
    # ... the five tiers, deterministic and fully pinned by test_strategy.py
```

Two properties of this code decide everything about the session design.
First, `apply_move` mutates in place and raises *before* touching the board
on an illegal cell, so a `move(cell)` that simply delegates to it gets
ac6's "raises and changes nothing" for free. Second, `choose_move` refuses
to play on a finished position — which is why the session must detect
"the human's move just ended the game" *before* it asks for an O reply; an
implementation that replies unconditionally would crash on the human's
winning move. Also to note: `Board.turn` already alternates, so after the
session performs the human's X and O's reply, `turn` is back to X for the
next human call.

## Proposed change

Two tasks, two new files, no edits to anything existing. Task-1 writes the
seven red tests plus an importable stub so the red-test verification can
certify that all seven tests fail inside the very file task-2 replaces;
task-2 fills in the session and the same seven tests go green.

### task-1 — the seven red tests, and the stub

`tests/test_session.py` holds exactly seven test functions, each named by
an acceptance criterion, importing only `pytest`, `tictactoe.game` and
`tictactoe.session` — never tkinter. Four of them script whole games by
repeating `session.move(cell)` over a fixed X line, and every line below
was replayed in this session against the **real** deterministic
strategy before being pinned, so the expected O replies are exact:

| test (AC) | scripted X line | O's replies (real strategy) | ends with |
|---|---|---|---|
| `test_human_moves_x_and_o_replies` (ac1) | 0, 8 (live game) | 4, 2 | no result: two X, two O, X to move |
| `test_win_message_is_exact` (ac2) | 0, 7, 6, 8 | 4, 2, 3 | X completes bottom row (6, 7, 8): "You win. Congratulations." |
| `test_loss_message_is_exact` (ac3) | 0, 8, 1 | 4, 2, 6 | O completes (2, 4, 6): "You lost. Better luck next time." |
| `test_draw_message_is_exact` (ac4) | 0, 1, 6, 5, 7 | 4, 2, 3, 8 | board full, `winner() == EMPTY`, `is_draw()`: "It's a draw." |

The arithmetic behind the loss and draw lines, which were found by
exhaustive search over the strategy, is: the human opens 0, then plays two
opposite corners, 8 and 1, that never threaten — O takes the center, the
corner at 2, and its own open (2, 4, 6) line at 6 (`test_loss`); for the
draw, the human plays 0, 1, 6, 5, 7 and creates exactly two real threats
(2 and 3), each blocked immediately, while O's own lines are always broken
by corners X holds, so the board fills with no winner. The remaining three
tests need no scripted line: `test_moves_after_the_end_are_ignored` plays
the win line, snapshots cells/result/message, then calls `move(1)`,
`move(0)`, `move(9)` and `move(-1)` and asserts nothing changed and nothing
raised; `test_illegal_move_raises_while_live` checks `move(9)` and
`move(-1)` raise `ValueError` on a fresh session with the board untouched,
then one legal exchange, then an occupied-cell `move(0)` raising with the
board unchanged; `test_new_game_resets_with_x_to_move` finishes the win
line, calls `new_game()`, asserts the fresh state, and makes one more real
move (X on 2, O center) so that the reset demonstrably starts a game, not
merely clears state.

`src/tictactoe/session.py` is created in the same task as an importable
stub: a `GameSession` whose `__init__`, `board`, `result`, `message`,
`move` and `new_game` all raise `NotImplementedError`, with correct
signatures so `mypy strict` and ruff stay clean. The seven tests must be
**red** at the end of task-1, and the red-test verifier passes only on that
shape: every test dies inside `src/tictactoe/session.py` (the `--fixes`
path), and a missing module or a test that breaks on its own scenario would
be rejected.

```python
tests/test_session.py (reference, verified green against the task-2 code)
"""Acceptance tests for the headless game session (bean-004)."""

import pytest

from tictactoe.game import EMPTY, O, X
from tictactoe.session import GameSession


def test_human_moves_x_and_o_replies() -> None:
    session = GameSession()
    assert session.board.cells == [EMPTY] * 9
    assert session.board.turn == X
    assert session.result is None
    assert session.message is None
    session.move(0)
    assert session.board.cells[0] == X
    assert session.board.cells[4] == O  # the strategy's first reply is the center
    assert session.board.turn == X
    session.move(8)
    assert session.board.cells[8] == X
    assert session.board.cells[2] == O  # no win, no block, center taken -> corner
    assert sum(cell == X for cell in session.board.cells) == 2
    assert sum(cell == O for cell in session.board.cells) == 2
    assert session.board.turn == X


def test_win_message_is_exact() -> None:
    session = GameSession()
    # 0, then fork with 7 and 6; the strategy replies 4, 2 and blocks 3.
    for cell in (0, 7, 6, 8):
        session.move(cell)
    assert session.board.winner() == X
    assert session.result == "win"
    assert session.message == "You win. Congratulations."


def test_loss_message_is_exact() -> None:
    session = GameSession()
    # 0, then two opposite corners that never threaten; O finishes (2,4,6).
    for cell in (0, 8, 1):
        session.move(cell)
    assert session.board.winner() == O
    assert session.result == "loss"
    assert session.message == "You lost. Better luck next time."


def test_draw_message_is_exact() -> None:
    session = GameSession()
    # 0,1,6,5,7: X's two threats (2 and 3) are blocked, O never completes.
    for cell in (0, 1, 6, 5, 7):
        session.move(cell)
    assert session.board.winner() == EMPTY
    assert session.board.is_draw()
    assert session.result == "draw"
    assert session.message == "It's a draw."


def test_moves_after_the_end_are_ignored() -> None:
    session = GameSession()
    for cell in (0, 7, 6, 8):
        session.move(cell)
    cells_before = list(session.board.cells)
    for cell in (1, 0, 9, -1):   # empty, occupied and out of range: all ignored
        session.move(cell)
    assert session.board.cells == cells_before
    assert session.result == "win"
    assert session.message == "You win. Congratulations."


def test_illegal_move_raises_while_live() -> None:
    session = GameSession()
    for index in (9, -1):
        with pytest.raises(ValueError):
            session.move(index)
    assert session.board.cells == [EMPTY] * 9
    session.move(0)
    cells_after_exchange = list(session.board.cells)
    with pytest.raises(ValueError):
        session.move(0)          # occupied
    assert session.board.cells == cells_after_exchange
    assert session.result is None


def test_new_game_resets_with_x_to_move() -> None:
    session = GameSession()
    for cell in (0, 7, 6, 8):
        session.move(cell)
    session.new_game()
    assert session.board.cells == [EMPTY] * 9
    assert session.board.turn == X
    assert session.result is None
    assert session.message is None
    session.move(2)              # the reset really starts a game
    assert session.board.cells[2] == X
    assert session.board.cells[4] == O
```

### task-2 — the session itself

`src/tictactoe/session.py` gets the real `GameSession`. The flow is a
composition of the two modules it stands on, nothing more:

- `move(cell)`: while the game is **over** (a result exists), return
  immediately — this check comes before any rule-set call, which is what
  makes even out-of-range indices ignored after the end. While live,
  delegate the placement to `Board.apply_move` — its `ValueError` for an
  occupied or out-of-range cell propagates, and it has already changed
  nothing when it raises. Then settle: X's winning line is `win` plus
  "You win. Congratulations.", O's is `loss` plus "You lost. Better luck
  next time.", a full board with no winner is `draw` plus "It's a draw.".
  Only if the human's move did **not** end the game does the session apply
  `choose_move(board, O)` and settle again — that ordering is also what
  keeps `choose_move` from ever being called on a finished position.
- `new_game()`: a fresh `Board()`, no result, no message.
- The session owns no rules: it does not re-derive the eight lines, it does
  not contain a second legality check, and no cell is written directly to
  `board.cells` — the only two writers are `apply_move` and the strategy
  through it. `board`, `result` and `message` are read-only properties; the
  window in bean-005 will render off `board.cells` and show `message`.

```python
src/tictactoe/session.py (reference; ruff and mypy-strict clean here)
"""The headless game session owning one whole human-versus-O game (bean-004)."""

from tictactoe.game import Board, O, X
from tictactoe.strategy import choose_move

WIN_MESSAGE = "You win. Congratulations."
LOSS_MESSAGE = "You lost. Better luck next time."
DRAW_MESSAGE = "It's a draw."


class GameSession:
    """One whole game: the human plays X, O replies via the strategy."""

    def __init__(self) -> None:
        self._board = Board()
        self._result: str | None = None
        self._message: str | None = None

    @property
    def board(self) -> Board:
        """The live rule-set board; the human's X is to move whenever live."""
        return self._board

    @property
    def result(self) -> str | None:
        """None while live; 'win', 'loss' or 'draw' once the game ends."""
        return self._result

    @property
    def message(self) -> str | None:
        """None while live; the exact window text once the game ends."""
        return self._message

    def move(self, cell: int) -> None:
        """The human's X move: place, settle, and reply with O unless over."""
        if self._result is not None:
            return
        self._board.apply_move(cell)  # ValueError for an illegal cell
        self._settle()
        if self._result is None:  # no reply after a game the move ended
            self._board.apply_move(choose_move(self._board, O))
            self._settle()

    def new_game(self) -> None:
        """Start over: empty board, X to move, no result and no message."""
        self._board = Board()
        self._result = None
        self._message = None

    def _settle(self) -> None:
        """Record the result and its exact message when this move ended it."""
        if self._board.winner() == X:
            self._result, self._message = "win", WIN_MESSAGE
        elif self._board.winner() == O:
            self._result, self._message = "loss", LOSS_MESSAGE
        elif self._board.is_draw():
            self._result, self._message = "draw", DRAW_MESSAGE
```

Both reference files were checked in this session at the toolchain's pinned
versions: `ruff check` and `ruff format --check` (E, F, I, UP, B, the
repo's own `pyproject.toml` settings) and `mypy --strict` (python 3.11) are
clean on both the stub form and the implementation form; all seven tests
were executed against the reference implementation via direct `python3`
calls (there is no pytest in this container) and all seven pass, while
against the stub all seven fail with `NotImplementedError` raised inside
`src/tictactoe/session.py`. The budget is comfortable: the two files total
about 196 lines against the bean's 300-line cap, 2 of 4 tasks, 2 of 2
files. The worker re-checks its own files the same way; the gate re-checks
on the pinned image.

## Risk

The behavioural risks are all ordering risks, and each one has a test that
fails loudly and readably. The worst mis-ordering — asking the strategy for
a reply without first checking that the human's move ended the game —
cannot fail quietly: `choose_move` raises `ValueError` on a finished
position, so a human win would blow up inside the winning `move` call and
`test_win_message_is_exact` would show that exact exception. Swapping the
two checks in `move` (rule-set first, "game over" second) fails
`test_moves_after_the_end_are_ignored` on the `move(9)` line — the
out-of-range index that must be *swallowed* would raise instead. A
re-implemented or mutated copy of the rules (a second table of lines, a
direct `board.cells[i] = ...` write, random O) breaks one of the exact-cell
or exact-message assertions, and a message typo fails the exact-equality
assert in the matching AC with the wrong string visible in the diff of the
failure. How to notice, in production terms: every AC is its own pytest id,
so a red gate names the one behaviour, and the suite runs in no time — the
seven games are 9, 9 and 7 half-moves long. How to back out: both files are
brand new with zero callers (bean-005 is the first consumer and is a
non-goal here), so reverting the bean's two commits returns the tree
exactly to the bean-003 state; there is no migration, no data, no
configuration to roll back.

## Blast radius

**Touched:** exactly the bean's two allowed paths, both brand-new files —
`src/tictactoe/session.py` (~71 lines, one class, three properties, two
methods) and `tests/test_session.py` (~125 lines, seven tests). Within
`tictactoe`, `session` becomes importable as an ordinary submodule; no
`__init__.py` change is needed and none is allowed. The test suite gains
seven tests (all headless, all milliseconds).

**Not touched:** `src/tictactoe/game.py` and `src/tictactoe/strategy.py`
(forbidden write paths — the session imports them, it never edits them);
the four existing test files; `tictactoe/__init__.py`, any future
`app.py`, `__main__.py` (non-goals / bean-005); `factory/`,
`pyproject.toml`, `README.md`. No new dependencies (standard library plus
the two sibling modules), no data, no configuration, no deployment: the
gate image picks up two files from the commits. The only cross-file
effect is that `ruff check .`, `mypy src` and pytest each see one new
module and one new test file.

## Verification

The bean's acceptance criteria, each verified by a named test in the gate
image, and the task-level commands the controller runs:

| AC | Criterion (short) | verify (test id) |
|---|---|---|
| ac1 | Fresh session empty with X to move; a live human move places X and O replies via the strategy | `tests/test_session.py::test_human_moves_x_and_o_replies` |
| ac2 | X completing a line reports the human win with the exact message "You win. Congratulations." | `tests/test_session.py::test_win_message_is_exact` |
| ac3 | A scripted O win reports the loss with the exact message "You lost. Better luck next time." | `tests/test_session.py::test_loss_message_is_exact` |
| ac4 | A scripted full-board no-winner line reports the draw with the exact message "It's a draw." | `tests/test_session.py::test_draw_message_is_exact` |
| ac5 | After the end, any further `move` (occupied, empty, out of range) is ignored with no exception and no change | `tests/test_session.py::test_moves_after_the_end_are_ignored` |
| ac6 | While live, an occupied or out-of-range cell raises `ValueError` and changes nothing | `tests/test_session.py::test_illegal_move_raises_while_live` |
| ac7 | `new_game()` on a finished session resets to empty board, X to move, no result or message, and play resumes | `tests/test_session.py::test_new_game_resets_with_x_to_move` |

| Task | controller-verified by |
|---|---|
| task-1 | `python factory/tools/red-test.py --fixes src/tictactoe/session.py --fixes '**/src/tictactoe/session.py' tests/test_session.py` — passes only while the seven tests fail by assertion or by a defect raising inside the file task-2 rewrites |
| task-2 | the seven AC tests above, one `pytest -q` command each, plus the full `tests/` suite so beans 001–003 stay green |

The bean has no `invariants_ref`; its constraints are the invariants,
checked where marked:

- **no GUI toolkit** — `tkinter` is a forbidden import of the session
  module (checked by the gate); the module imports only `tictactoe.game`
  and `tictactoe.strategy`.
- **delegation, not re-implementation** — every legality check is the rule
  set's and every O move is the strategy's (reviewed; the design has no
  second table of lines and no direct cell writes).
- **no changes to the game core or strategy** — `src/tictactoe/game.py` and
  `src/tictactoe/strategy.py` are forbidden write paths (checked by the
  gate); the full-suite verify keeps their tests green anyway.
- **Python 3.11 / mypy strict** — the whole package must stay
  `mypy --strict` clean (checked by the gate).
- **deterministic O** — no randomness in the reply; pinned by ac1's exact
  expected cells 4 and 2.

What could not be checked from this session, said plainly: pytest itself
does not run here, so the seven AC tests, the red-test helper and the task
verify commands were not executed under pytest; they were instead driven
directly through `python3` (all seven pass against the reference
implementation, all seven fail inside `session.py` against the stub) and
`ruff`/`mypy` were run at the versions the toolchain pins, clean on both
files in both forms. The gate image re-runs everything from a clean state;
that re-run is the verdict.

## Open questions

Nothing here blocks the build; these were the assumptions the bean left
open, declared so the reviewer sees them:

- **The public surface was not named.** The bean specifies behaviour
  ("exposes the outcome as one of win, loss or draw, plus the exact
  message") but no method names. We read that as a
  `GameSession(board, result, message, move(cell), new_game())` surface,
  with `result` the lowercase tokens `"win"` / `"loss"` / `"draw"`, a
  separate `message` string, and `board` returning the *live* `Board` so
  bean-005's window can render `board.cells` without the session copying
  state.
- **"Ignored entirely" after the end.** We read it to cover out-of-range
  indices too: once a result exists, `move` returns before any rule-set
  call, so `move(9)` and `move(-1)` on a finished game are silent. ac5
  pins exactly that.
- **The scripted lines were not specified.** The bean asks for "a line that
  loses to O and a line that ends in a draw" without naming them, and
  their existence was not self-evident because the strategy both takes
  wins and blocks threats. We find them by exhaustive search over the real
  strategy and pin one each: loss is the human playing 0, 8, 1 (never
  threatening, letting O finish 2-4-6) and the draw is 0, 1, 6, 5, 7 (two
  threats, both blocked, board full). The win line is 0, 7, 6, 8 — the
  same fork line bean-003 pinned — so the human's winning game is
  consistent across beans. Any other verified line would do equally.
- **No extra turn guard.** The bean's contract requires the rule set's
  `ValueError` while live and silence after the end, and nothing else. We
  deliberately do not add a "not X's turn" check: the flow guarantees it is
  always X's turn on a human call (X to move at start, O's answer restores
  it), so an extra guard would be untestable dead code the bean did not ask
  for.
- **Draw reachability.** Declared with evidence: draws *are* reachable
  against this strategy (the search found several lines, 0, 1, 6, 5, 7 is
  the shortest it verified), so ac4 is satisfiable; had the search found
  none, that would have been a bean conflict and this session would have
  stopped with `QUESTIONS.md` instead of a plan.
