Anvil marketing screenshots (real app, isolated demo instance, fake project)
All images: 2880x1698 PNG, retina (2x) window-only capture, no shadow, dark appearance (the app is dark-only).

anvil-main.png
  Main window after a finished task in the demo project "orders-api": the user's request
  (validate order items, add tests, run the suite), the collapsed step summary, and the agent's
  answer ("Verified with npm test (all 9 tests passed)"). Sidebar shows the project and two sessions.

anvil-diff.png
  Same session with the Git inspector open: branch main, two modified files, the full unified
  diff of src/validate.js and test/validate.test.js, and the commit box with "Write message" and
  "Commit all".

anvil-changes.png
  Same session with the Changes inspector: per-file change list, a diff of the new tests, and the
  Checkpoints and "Undo last task" controls.

anvil-command-palette.png
  Command palette (Cmd+K) filtered to "Show", listing the inspector panes: Changes, Preview,
  Device, Files, Plan, Terminal, Git.

anvil-new-session.png
  New session empty state ("What are we building in orders-api?") with a typed prompt, Bypass
  permission mode, the model picker, and suggestion chips.

Notes
- The tasks were real agent runs (model gemini-auto, $0) against a throwaway Node project at
  /tmp/code/orders-api; the tests really pass afterwards (5/5, then 9/9).
- The "1 failed" label next to the step summary is real: the built-in syntax check caught a stray
  brace and the agent fixed it on the next step.
