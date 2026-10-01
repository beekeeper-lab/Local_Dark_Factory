# Revision instructions from the owner's review

Change only what is named here. Every other draft stays as it is.

- **Split bean-001** into two beans, the second depending on the first.
- **Split bean-003** into two beans, the second depending on the first.
- **Revise bean-002.**

After a split or a merge, renumber the whole set bean-001, bean-002, ... in run order, so that every dependency has a lower number than the bean that needs it. Update every `id`, every `dependencies` entry and every mention of a bean id in the text, and delete any file whose id no longer exists.

The owner's note: bean-002: O takes its own winning move first and blocks only when it cannot win (win, then block, then center, corners, sides, as answered in q-2). ac2 must not say O blocks when it could win. bean-001: split into (a) the board and legal moves - a fresh board, applying a move, refusing occupied or out-of-range cells, whose turn it is if you model it - and (b) win and draw detection over the eight lines. bean-003: split into (a) a headless game-session module with no GUI import that owns the flow - the human's X, O's reply via the strategy, ignoring moves after the game ends, the exact result message for a win, a loss and a draw, and New Game resetting with X to move - all verified by tests, and (b) a thin Tkinter window over that session, whose only manual criteria are what a person must see in the window. Expected result: five beans in run order: board and moves, win and draw, strategy, game session, Tkinter window.
