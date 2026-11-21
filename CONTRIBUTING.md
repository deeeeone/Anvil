# Contributing to Anvil

Thanks for wanting to help. Bug reports, eval tasks, fixes and features are all welcome.

## Building

You need macOS 15+, Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Anvil.xcodeproj -scheme Anvil -derivedDataPath build build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
open build/Build/Products/Debug/Anvil.app
```

`Anvil.xcodeproj` is generated from `project.yml` and isn't checked in. Add new files under `Anvil/` or `AnvilTests/` and run `xcodegen generate` again.

## Testing

```bash
xcodebuild -project Anvil.xcodeproj -scheme Anvil -derivedDataPath build test \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

- Most tests run offline. Agent behaviour is tested with scripted replies through `Brain.override` and `SessionController.brainFactory`.
- Tests with *Live* in their name call real services (ChatGPT, Gemini, language servers) and skip themselves when those aren't set up.
- If you change how the agent behaves, run the evals before and after and include both numbers in the PR:

  ```bash
  python3 evals/run.py --models glm-5.3-flash-uncensored --parallel 4
  ```

## Sending a change

1. Open an issue first for anything big, so we can agree on the approach.
2. Keep pull requests focused: one change, with tests.
3. Match the surrounding style. Comments say *why*, not *what*.
4. Make sure the build and tests pass, and describe how you verified the change.

## Adding an eval task

Each task in `evals/tasks/<name>/` has a `setup.sh` (builds the starting repo), a `prompt.txt` (what the agent is asked) and a `check.sh` (exit 0 means pass; the agent never sees it). Good tasks are small, realistic, and have one clearly right outcome.

## License

By contributing, you agree that your contributions are licensed under the [AGPL-3.0](LICENSE).
