# bean-003 — Strategic system-user move selection for O

## What and why

This repository builds a desktop tic-tac-toe against the computer, as a
headless Python package assembled one approved "bean" at a time: bean-001 and
bean-002 delivered the rule set (the 3x3 board, legal moves, and win/draw
detection) in `src/tictactoe/game.py`; bean-004 will later add a headless game
session that alternates moves; bean-005 adds the window. Nothing in the tree
today chooses a move, and that is the gap this bean fills: the computer
player, who plays O, needs a policy.

The requirements transcript is explicit that the machine player should not
pick a random cell — an OS user "wouldn't choose a random location, but would
try to choose a strategic location to win the game" — while a answered design
question fixes exactly how strategic: try, in strict order, (1) take O's own
immediate winning move, (2) otherwise block the human's immediate winning
move, (3) otherwise prefer the center, then a corner, then a side. That is
deliberately **not** perfect minimax. A perfect O could never lose, which
would make the game's "you win, congratulations" outcome unreachable, and the
human player could never beat the machine. This fixed order keeps the
machine convincingly non-random while a well-played human still beats it —
acceptance criterion ac6 exists to prove that. The bean adds one new module,
`tictactoe.strategy`, with one public function,
`choose_move(board, symbol) -> int`, built on the existing rule set, plus its
acceptance tests. Ties inside a tier always break to the lowest cell index so
every choice is deterministic and testable, and the module must not import any
GUI toolkit (`import tkinter` fails in the gate container, which has no
display).

## Current behaviour

`src/tictactoe/strategy.py` does not exist yet, and there is no move-selection
code anywhere in the repository: the three existing test files
(`tests/test_smoke.py`, `tests/test_board.py`, `tests/test_winner.py`) sit
next to a rule set that knows everything about a game except which move to
make. All the strategy needs is already in `src/tictactoe/game.py`, which
bean-003 may not modify — bean-001 and bean-002 own it:

```python
# src/tictactoe/game.py (abridged; the file is unchanged by this bean)
LINES: tuple[tuple[int, int, int], ...] = (
    (0, 1, 2),
    (3, 4, 5),
    (6, 7, 8),  # rows
    (0, 3, 6),
    (1, 4, 7),
    (2, 5, 8),  # columns
    (0, 4, 8),
    (2, 4, 6),  # diagonals through the center
)

class Board:
    """A 3x3 board: nine cells, each empty, X or O, plus whose turn it is."""
    def __init__(self) -> None:
        self.cells: list[str] = [EMPTY] * 9
        self.turn: str = X

    def apply_move(self, index: int) -> None:          # legality: range + not occupied
        ...

    def winning_line(self) -> tuple[int, int, int] | None:  # the three cells, or None
        ...

    def winner(self) -> str:     # mark of the winner, or EMPTY
        ...

    def is_draw(self) -> bool:   # full board, no winner
        ...
```

Cells are indices 0..8, read left-to-right, top-to-bottom: 0,1,2 on top,
3,4,5 in the middle, 6,7,8 on the bottom; cell 4 is the center; 0,2,6,8 are
the corners; 1,3,5,7 are the sides. `Board.turn` alternates X, O, X, ... after
each `apply_move`. The strategy will ask the rule set its questions through
`winner()`, `is_draw()` and `winning_line()`, and will never re-derive the
eight lines itself.

## Proposed change

Two tasks, two new files, no edits to anything existing.

### task-1 — the six red tests, and the stub

`tests/test_strategy.py` is written first, with exactly six tests, one per
acceptance criterion. Four test one fixed position each, built the same way
`tests/test_winner.py` builds its boards (a helper overwrites a fresh
`Board`'s cells from a nine-character mark string, position 0 reading first,
left to right; a dot is an empty cell; every scenario has exactly one more X
than O, so it is O's turn):

| test (AC) | marks (`_board` string) | expected `choose_move` |
|---|---|---|
| `test_takes_own_winning_move_first` (ac1) | `XX.X.XOO.` | 8 — O wins on 8; the open block at 2 must be ignored |
| `test_blocks_when_it_cannot_win` (ac2) | `XX.O.X..O` | 2 — O has no win of its own (3 and 8 share no line); only 2 lets X win |
| `test_prefers_center_when_available` (ac3) | `X........` | 4 |
| `test_prefers_corners_over_sides_deterministically` (ac4) | `X...X...O` | 2 — corners 2 and 6 and all sides open; lowest open corner, on all 25 calls |

The other two drive games through `Board.apply_move` with the board's own
legality rules in force:

- `test_move_is_always_legal` (ac5) breadth-first walks **every reachable
  position** from the empty board — for each empty cell, build a child board,
  and if the child has no winner and is not a draw, check
  `choose_move(child, child.turn)` is in range and empty on the child.
  De-duplicating by cell contents is required for speed: there are 4520
  distinct reachable non-terminal boards (well under a second to visit each),
  whereas enumerating move orders without dedup is a quarter million steps.
- `test_a_human_x_can_still_win` (ac6) plays a full game in which X is
  scripted to the fixed line **(0, 7, 6, 8)** — open a corner, meet the
  strategy's second corner with the opposite one, use the next opposite
  corner to fork two winning cells, and complete the row — while O answers
  every turn with `choose_move(board, O)`; the final `board.winner()` must be
  X. (That line was found by game-tree search over the strategy: X wins it no
  matter what the strategy's deterministic replies are.)

`src/tictactoe/strategy.py` is created in the same task, but only as an
importable module whose `choose_move(board, symbol) -> int` raises
`NotImplementedError`. The tests must be **red** at the end of task-1, and
that is deliberate: with the stub in place every test fails on an exception
raised inside `src/tictactoe/strategy.py`, and the task's `red-test.py`
verification passes only on that shape. It would reject a missing module (a
collection error) and a test that breaks on its own scenario, so the red tests
are certified to be failing for a reason the implementation can fix.

Illustrative form of the test file (the spec-checked reference; scenarios,
expected cells and test names are the binding part):

```python
tests/test_strategy.py (reference)
def _board(marks: str, turn: str) -> Board:
    """Build a fresh Board from a nine-character string, '.' for an empty cell."""
    board = Board()
    board.cells = ["" if m == "." else m for m in marks]
    board.turn = turn
    return board

def test_takes_own_winning_move_first() -> None:
    # O owns 6 and 7, so 8 is O's immediate winning cell; X owns 0, 1 and 5,
    # so the block at 2 is open in the same position. Win, not block.
    board = _board("XX.X.XOO.", O)
    assert choose_move(board, O) == 8

def test_move_is_always_legal() -> None:
    start = _board(".........", X)
    seen: set[tuple[str, ...]] = {tuple(start.cells)}
    frontier: deque[Board] = deque([start])
    while frontier:
        board = frontier.popleft()
        for cell in range(9):
            if board.cells[cell] != EMPTY:
                continue
            child = Board(); child.cells = list(board.cells); child.turn = board.turn
            child.apply_move(cell)
            if child.winner() != EMPTY or child.is_draw():
                continue
            move = choose_move(child, child.turn)
            assert 0 <= move <= 8
            assert child.cells[move] == EMPTY
            key = tuple(child.cells)
            if key not in seen:
                seen.add(key)
                frontier.append(child)
    assert len(seen) > 1000

def test_a_human_x_can_still_win() -> None:
    x_plan = (0, 7, 6, 8)
    board = Board()
    x_moves = iter(x_plan)
    while True:
        if board.turn == X:
            board.apply_move(next(x_moves))
        else:
            board.apply_move(choose_move(board, O))
        if board.winner() != EMPTY or board.is_draw():
            break
    assert board.winner() == X
```

Verification for task-1 is the red-test helper over the future fix path:
`python factory/tools/red-test.py --fixes src/tictactoe/strategy.py tests/test_strategy.py`
(the task passes a second, `**/`-prefixed copy of the glob so the helper
accepts either relative or absolute paths in the tracebacks).

### task-2 — the strategy itself

`src/tictactoe/strategy.py` receives the real body of `choose_move`. The
policy is exactly the bean's fixed order, with every tie broken to the lowest
empty cell index — that is what makes each of the tests above have a single
expected integer. "Would complete a winning line" is answered by the rule set:
copy `board.cells` into a scratch `Board`, place the mark, call
`Board.winning_line()`; the live board is never mutated and no second table of
the eight lines exists in this module. A finished position (someone has won,
or it is a draw) raises `ValueError` — see Open questions.

```python
src/tictactoe/strategy.py (reference)
"""Move selection for the system user (bean-003)."""

from tictactoe.game import EMPTY, Board, O, X

CENTER = 4
CORNERS = (0, 2, 6, 8)
SIDES = (1, 3, 5, 7)


def _completes(board: Board, index: int, mark: str) -> bool:
    """Would placing ``mark`` at ``index`` complete a winning line?"""
    trial = Board()
    trial.cells = list(board.cells)
    trial.cells[index] = mark
    return trial.winning_line() is not None


def choose_move(board: Board, symbol: str) -> int:
    """Pick a cell for ``symbol``'s turn: win, block, center, corner, side."""
    if board.winner() != EMPTY or board.is_draw():
        raise ValueError(f"game is already over: {board.cells!r}")
    opponent = O if symbol == X else X
    empty = [index for index in range(9) if board.cells[index] == EMPTY]
    for index in empty:  # 1. take own winning move, even when a block is open
        if _completes(board, index, symbol):
            return index
    for index in empty:  # 2. otherwise block the opponent's winning move
        if _completes(board, index, opponent):
            return index
    if board.cells[CENTER] == EMPTY:  # 3. the center
        return CENTER
    for index in CORNERS:  # 4. a corner
        if board.cells[index] == EMPTY:
            return index
    for index in SIDES:  # 5. a side
        if board.cells[index] == EMPTY:
            return index
    raise AssertionError("non-terminal board with no empty cell")
```

Both reference files were checked in this session: all six tests were run
directly under `python3` and pass against the reference strategy; `ruff check` (ruff 0.16.7, under
the repo's own `pyproject.toml` settings: E, F, I, UP, B), `ruff format --check`, and `mypy
--strict` (mypy 2.3.1, python 3.11) are all clean on both files. The worker re-checks its own files the
same way; the gate re-checks on the pinned toolchain. The full 250-line budget
of the bean is not a pinch: the two files together are about 150 lines.

## Risk

The main risk is strategic, not mechanical: an implementation that is
*smarter* than the bean — minimax, threat-counting two ply deep, or even a
corner-hungering variation — can quietly make the scripted human's game a
draw or a loss, and ac6 is the single test that catches that (it fails on the
final-`winner` assertion, which is easy to read). The mirror image — wrong
tier order or non-deterministic ties — fails ac1..ac4 on specific small
integers, with the assertion message showing expected vs. actual cell, so the
offending tier is obvious. The BFS test is the one with a real performance
risk: without de-duplication it enumerates a quarter million move orders and
can take minutes inside a gate with no stated time budget; the task mandates
the de-duplicated walk (measured at about a tenth of a second here) and the
`len(seen) > 1000` end assertion guards against a walk that silently stopped
working. Nothing in the repository imports `tictactoe.strategy` at the point
this bean lands, so a regression cannot surface anywhere but the tests; bean-004
is the first consumer. If anything fails: each AC is its own verify command,
so a red verify names the exact behaviour; to back out, revert the bean's
commits — both files are new and have no callers, so the tree returns exactly
to the bean-002 state with no cleanup.

## Blast radius

**Touched:** exactly the bean's two allowed paths, both brand-new files —
`src/tictactoe/strategy.py` (one public function, ~45 lines) and
`tests/test_strategy.py` (~110 lines, six tests). Within `tictactoe`,
`strategy` becomes importable as an ordinary submodule; no `__init__.py`
change is needed and none is allowed.

**Not touched:** `src/tictactoe/game.py` (forbidden by the bean — bean-001 and
bean-002 own the rule set, and the strategy imports from it rather than around
it); `tictactoe/__init__.py`, any future `app.py`, `__main__.py` or
`session.py` (non-goals or later beans); the three existing test files;
`factory/`, `pyproject.toml`, `README.md`. No data, no configuration, no new
dependencies (standard library plus `tictactoe.game` only), no deployment: the
gate image picks up the two files from the commits. The only cross-file
effect is that `mypy src` and `ruff check .` now see one module and one test
file each, and the suite runs six extra tests.

## Verification

The bean's acceptance criteria, each verified by a named test in the gate
image (`kind: test`), and the task-level commands the controller runs:

| AC | Criterion (short) | verify (test id) |
|---|---|---|
| ac1 | O's own winning cell is played exactly, even when a block is also open | `tests/test_strategy.py::test_takes_own_winning_move_first` |
| ac2 | With no own win, the human's would-be winning cell is played | `tests/test_strategy.py::test_blocks_when_it_cannot_win` |
| ac3 | No win, no block, center empty ⇒ the center | `tests/test_strategy.py::test_prefers_center_when_available` |
| ac4 | No win, no block, center taken ⇒ an open corner over an open side, deterministically | `tests/test_strategy.py::test_prefers_corners_over_sides_deterministically` |
| ac5 | For every reachable non-terminal position the returned cell is in range and currently empty | `tests/test_strategy.py::test_move_is_always_legal` |
| ac6 | A scripted, well-played X defeats the strategy in a full game | `tests/test_strategy.py::test_a_human_x_can_still_win` |

| Task | controller-verified by |
|---|---|
| task-1 | `python factory/tools/red-test.py --fixes src/tictactoe/strategy.py --fixes '**/src/tictactoe/strategy.py' tests/test_strategy.py` — passes only when the six tests fail by an assertion, or by a defect raising inside the file task-2 rewrites |
| task-2 | the six AC tests above, one `pytest -q` command each, plus the full `tests/` suite |

Invariants, by name (the bean has no `invariants_ref`; these are its
constraints, checked where marked "checked" rather than judged):

- **determinism** — no randomness in move selection; ties break to the lowest
  cell index — tested by ac4's repeated calls, and by every other AC pinning
  one exact cell.
- **fixed priority** — win, then block, then center, then corners, then
  sides, in that strict order — tested by ac1..ac4.
- **no GUI toolkit** — `tkinter` is a forbidden import of the strategy module
  (checked by the gate).
- **no changes to the game core** — `src/tictactoe/game.py` is a forbidden
  write path for this bean (checked by the gate).
- **mypy strict / Python 3.11** — the whole package must stay
  `mypy --strict` clean (checked by the gate).

What could not be checked from this session, said plainly: pytest itself does
not run here, so the six AC tests and the task verify commands were not
executed; they were instead driven directly with `python3` (all six pass
against the reference implementation) and `ruff`/`mypy` were run at exactly
the versions the toolchain pins. The gate image re-runs everything from a
clean state; that re-run is the verdict.

## Open questions

Nothing here blocks the build, but these were assumptions the bean left open:

- **Finished positions.** The bean specifies behaviour only for "reachable
  non-terminal" positions. We assumed `choose_move` raises `ValueError` when
  the position is finished (a winner, or a draw) rather than returning some
  arbitrary cell. No AC tests this; it is declared so the implementation is
  complete and the choice is visible.
- **"Reachable" in ac5** was read as "reachable from the empty board by legal
  alternating moves through `Board.apply_move`", de-duplicated by cell
  contents. That is 4520 boards and is the reading that keeps the test fast;
  testing by move-order enumeration would mean the same 4520 positions,
  reached 255,168 ways.
- **The scripted X in ac6.** The bean asks for "a scripted, well-played X"
  without naming the line. We fixed it to (0, 7, 6, 8), found by search over
  the strategy — a corner-open game in which X forks after the strategy's
  second corner and wins, regardless of the strategy's deterministic replies.
  Any other beating line would do equally; this one is short and principled.
- **Symbol generality.** The bean's title says "the move for O", and the
  background names the function `choose_move(board, symbol)`. We implemented
  the tiered policy generically in the mark to move (the tier-2 "block" is
  defined against the opposite mark) and tested it only for O, as the
  criteria do.
- **Scenario hygiene.** The four single-position tests use boards whose
  marks are genuinely reachable positions (one more X than O, and a legal
  move order exists for each — verified), even though building them by
  overwriting `cells` does not require reachability. Tests should not depend
  on positions the game cannot produce.
