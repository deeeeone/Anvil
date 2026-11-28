import Foundation

/// The help screens. Short, example-led, and the exit codes are listed where scripts need them.
enum Help {
    static let exitCodes = """
    Exit codes:
      0    done: the request finished (with --output json: ok is true)
      1    not done: the agent stopped (step or cost limit, timeout, judge said no)
      2    usage or configuration: bad option, no provider set up, unknown name
      3    the model provider failed (rejected key, rate limit, timeout, network)
      130  stopped with Ctrl-C
    """

    static let main = """
    anvil \(CLIRouter.version): a coding agent for your project, from the terminal.

    Usage:
      anvil                          open the interactive session (in a terminal)
      anvil -p "PROMPT" [options]    run one request and print the answer
      echo "PROMPT" | anvil          same, reading the prompt from stdin
      anvil <command> [args]         config, providers, models, sessions

    Examples:
      anvil -p "add a --verbose flag to the CLI" -C ~/code/tool
      anvil -p "why do the tests fail?" --output json > result.json
      anvil -p "fix the typo in README" --mode bypass --max-steps 20
      anvil -p "continue the migration" --continue
      anvil config set api-key            (the key is read hidden; it is never printed)
      anvil providers add openrouter

    Request options (with -p):
      -p, --print [PROMPT]    the request; "-" or no value reads stdin
      -C, --project DIR       the project folder (default: the current folder)
      --model ID              model to use (see `anvil models`)
      --mode MODE             ask | edits | plan | bypass (default: the setting, ask)
      --approve               allow edits and commands that would ask (dangerous ones still refused)
      --max-steps N           stop after N steps
      --max-cost USD          stop once the request costs this much
      --timeout SECONDS       stop after this many seconds (exit 1, reason "timeout")
      --continue              add to the newest session of this project
      --resume ID             add to a session (`anvil sessions` lists ids; a prefix works)
      --no-verify --no-review --no-judge --no-stream   turn off one check or the live text

    Output:
      --output text           the answer on stdout; progress on stderr (default)
      --output json           nothing on stdout until the end, then one JSON object
      --output stream-json    one JSON event per line on stdout; the last line has type "result"
      -q, --quiet             no progress lines

    Other:
      -h, --help              this help (or `anvil <command> --help`)
      --version               print the version

    Commands: config, providers, models, sessions. Run `anvil help <command>`.

    \(exitCodes)
    """

    static let config = """
    anvil config: the settings this CLI reads and writes (model, mode, limits, checks).
    The Mac app keeps its own copy in its preferences, so changes made here do not reach the app yet.
    Values shown are the CLI's copy: where nothing was set, the built-in default.

    Usage:
      anvil config list                 every setting, its value and what it does
      anvil config get NAME             one value
      anvil config set NAME VALUE       change a value (checked: a bool, a number or a listed word)
      anvil config set api-key          store the provider API key (read hidden, never printed)
      anvil config path                 the folder that holds the settings and credentials

    Examples:
      anvil config set max-steps 40
      anvil config set default-mode edits
      anvil config get model

    Names can be written as max-steps, maxSteps or max_steps.

    Exit codes: 0 done, 2 unknown name or bad value.
    """

    static let providers = """
    anvil providers: model providers (built in, or plugins added from a preset).

    Usage:
      anvil providers                   list what is installed and whether it is ready
      anvil providers presets           the presets you can add
      anvil providers add PRESET_ID     install a preset, then ask for its API key
      anvil providers key ID            set or change a plugin's API key (read hidden)
      anvil providers remove ID         remove a plugin (its key too)

    Examples:
      anvil providers presets
      anvil providers add openrouter
      anvil providers key openrouter

    Web sign-in (Gemini, ChatGPT and web presets) is done in the Mac app for now.

    Exit codes: 0 done, 2 unknown preset or provider, or the plugin folder can't be written.
    """

    static let models = """
    anvil models: the models you can pick right now, with the default marked "*".

    Usage:
      anvil models

    A model that needs a provider you have not set up is marked "not set up".
    Use one with: anvil -p "..." --model ID

    Exit codes: 0 done.
    """

    static let sessions = """
    anvil sessions: this project's sessions, newest first.

    Usage:
      anvil sessions            sessions of the folder you are in (or -C DIR)
      anvil sessions --all      sessions of every project

    Continue one with: anvil -p "..." --resume ID   (a prefix of the id is enough)
    or the newest one with: anvil -p "..." --continue

    Exit codes: 0 done.
    """

    /// The help for one command, or nil when there is none.
    static func command(_ name: String) -> String? {
        switch name {
        case "config": return config
        case "providers", "provider": return providers
        case "models": return models
        case "sessions": return sessions
        default: return nil
        }
    }
}
