// swift-tools-version: 6.2
// AnvilCore: the platform-neutral part of Anvil, compiled in place from Anvil/ for the cross-platform CLI.
// The Mac app (project.yml) still compiles these same files itself; this package only adds Linux and Windows.
// `sources` grows one group at a time as each group is made portable.
import PackageDescription

/// NonisolatedNonsendingByDefault is left out on Linux. Swift 6.2 on Linux miscompiles async closure calls under this feature
/// combined with default MainActor isolation: a JSON argument reached the closure as .null (reproduced in isolation; the
/// Mac toolchain, Swift 6.4, is fine). Apple platforms keep the feature, so the Mac behaviour is unchanged.
#if os(Linux)
let nonisolatedNonsendingFlags: [SwiftSetting] = []
#else
let nonisolatedNonsendingFlags: [SwiftSetting] = [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
#endif

/// Mirrors the Anvil target's compile flags (taken from an xcodebuild log), so the same code means the same thing here.
let appFlags: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
] + nonisolatedNonsendingFlags

/// The test target: the same flags, except default MainActor isolation applies only on macOS. XCTest's overridable
/// methods (setUp, init(name:testClosure:)) are MainActor-isolated in the Darwin SDK but not in swift-corelibs-xctest,
/// so on Linux the default makes every XCTestCase override fail to compile. The Xcode test target keeps the default.
let testFlags: [SwiftSetting] = [.defaultIsolation(MainActor.self, .when(platforms: [.macOS]))] + Array(appFlags.dropFirst())

let coreSources = [
    // Every non-UI file except the app shell (windows, app state, SwiftTerm, notifications, the AppKit headless runner).
    // Mac-only pieces inside these files are fenced with #if os(macOS) / canImport(WebKit).
    // App/Schedule, SubSessions, TaskQueue, WorktreeCleanup extend AppState/SessionController: later, with sub-sessions.
    "App/AppInfo.swift", "Brain/ActionParser.swift", "Brain/AgentLoop.swift", "Brain/Brain.swift",
    "Brain/ChatGPTWebClient.swift", "Brain/ChatMessage.swift", "Brain/GeminiWebClient.swift", "Brain/JSON.swift",
    "Brain/Jailbreak.swift", "Brain/ModelCatalog.swift", "Brain/OpenAIClient.swift", "Brain/PromptBuilder.swift",
    "Brain/Providers.swift", "Core/Checkpoints.swift", "Core/Compactor.swift", "Core/CompletionJudge.swift",
    "Core/Decoding.swift", "Core/DesignCritique.swift", "Core/Diff.swift", "Core/DiscordPresence.swift",
    "Core/FileWatcher.swift", "Core/Git.swift", "Core/GoalState.swift", "Core/HTTPLines.swift", "Core/KeepAwake.swift", "Core/Keychain.swift",
    "Core/LSP.swift", "Core/Mentions.swift", "Core/NotebookLM.swift", "Core/NotebookMemory.swift",
    "Core/OutputCheck.swift", "Core/PipeReader.swift", "Core/Permissions.swift", "Core/Platform.swift", "Core/ProjectContext.swift", "Core/ProjectMemory.swift",
    "Core/Redactor.swift", "Core/SHA3.swift", "Core/SafariCookies.swift", "Core/Session.swift",
    "Core/SessionMeta.swift", "Core/SessionTree.swift", "Core/Settings.swift", "Core/SkillLibrary.swift",
    "Core/SlashCommands.swift", "Core/Speed.swift", "Core/TokenMeter.swift", "Core/WebAccounts.swift",
    "Providers/PresetData.swift", "Providers/ProviderClient.swift", "Providers/ProviderPlugins.swift", "Providers/ProviderServers.swift",
    "Providers/ProviderSpec.swift", "Tools/AgentBrowser.swift", "Tools/Browser.swift", "Tools/BrowserQA.swift", "Tools/EditEngine.swift", "Tools/FileTools.swift",
    "Tools/GitHub.swift", "Tools/MCPClient.swift", "Tools/ProcessRunner.swift", "Tools/ShellTools.swift",
    "Tools/Simulator.swift", "Tools/Tool.swift", "Tools/WorkTools.swift",
]

/// Files under Anvil/ that are not part of this package: the app shell, the SwiftUI views, bundle resources.
/// SwiftPM would otherwise warn that it found them unhandled.
let excludes = [
        "Anvil.entitlements",
        "AnvilPasskeys.entitlements",
        "Info.plist",
        "Assets.xcassets",
        "UI",
        "Providers/Presets",
        "App/AnvilApp.swift",
        "App/AppState.swift",
        "App/AppState+Organize.swift",
        "App/Headless.swift",
        "App/Notifier.swift",
        "App/PaneLayout.swift",
        "App/Schedule.swift",
        "App/SessionController.swift",
        "App/SubSessions.swift",
        "App/TaskQueue.swift",
        "App/Terminals.swift",
        "App/WorktreeCleanup.swift",
]

let package = Package(
    name: "Anvil",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AnvilCore", targets: ["AnvilCore"])],
    targets: [
        .target(name: "AnvilCore", path: "Anvil", exclude: excludes, sources: coreSources, swiftSettings: appFlags),
        .testTarget(
            name: "AnvilCoreTests",
            dependencies: ["AnvilCore"],
            path: "AnvilTests",
            exclude: [
                "CleanupTokensTreeTests.swift",
                "CommandPaletteTests.swift",
                "ControlTests.swift",
                "FeatureTests.swift",
                "GoalPanelTests.swift",
                "MarkdownAndCompatTests.swift",
                "ParallelAgentsTests.swift",
                "SlashGoalScheduleTests.swift",
                "SplitViewTests.swift",
            ],
            sources: [
        "AgentLoopTests.swift",
        "BrowserQATests.swift",
        "ChatGPTProviderTests.swift",
        "CoreTests.swift",
        "DesignCritiqueTests.swift",
        "DiscordPresenceTests.swift",
        "EditAndDiffTests.swift",
        "HarnessFixTests.swift",
        "HarnessStressTests.swift",
        "HarnessTests.swift",
        "JudgeAndGoalTests.swift",
        "LivenessTests.swift",
        "MCPTests.swift",
        "MethodAndDesignTests.swift",
        "NotebookLMTests.swift",
        "ParserTests.swift",
        "PermissionTests.swift",
        "PresetDataTests.swift",
        "ProviderPluginTests.swift",
        "ProviderTests.swift",
        "SessionMetaTests.swift",
        "WebAccountTests.swift"
            ],
            swiftSettings: testFlags
        ),
    ],
    swiftLanguageModes: [.v5]
)
