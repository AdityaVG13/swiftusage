import Testing
@testable import UsageGraphs

struct CLITests {
    /// What macOS, Finder, a login item, Xcode or `defaults` open the app with, and the options and typos
    /// that must never open it: a second copy of the app reads limits with the person's logins and writes
    /// into the folder the installed one keeps its history in.
    @Test(arguments: [
        ([], CLI.app),
        (["-psn_0_12345"], .app),
        (["-AppleLanguages", "(en)"], .app),
        (["-NSDocumentRevisionsDebugMode", "YES"], .app),
        (["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"], .app),
        (["stray"], .app),
        (["-x"], .usageError("unknown option -x")),
        (["-v"], .usageError("unknown option -v")),
        (["-V"], .usageError("unknown option -V")),
        (["-help"], .usageError("unknown option -help")),
        (["-Help"], .usageError("unknown option -Help")),
        (["-dump"], .usageError("unknown option -dump")),
        (["-Dump", "--json"], .usageError("unknown option -Dump")),
        (["-NSKey", "--dump"], .usageError("unknown option -NSKey")),
        (["-AppleLanguages"], .usageError("unknown option -AppleLanguages")),
        (["-"], .usageError("unknown option -")),
        (["-h"], .help),
        (["--help"], .help),
        (["--version"], .version),
        (["--dump", "--json", "--provider", "codex"], .dump(provider: .codex, cold: false, json: true)),
        (["--dump", "--json", "--provider", "unattributed"], .dump(provider: .unattributed, cold: false, json: true)),
        (["--limits", "--json"], .limits(provider: nil, json: true)),
        (["--dump", "--provider", "nope"], .usageError("unknown provider 'nope' (valid ids: codex, claude, cursor, grok, opencode, antigravity, muse, pi, devin, droid, nous, zai, kimi, unattributed)")),
    ] as [([String], CLI)])
    func arguments(_ arguments: [String], _ expected: CLI) {
        #expect(CLI.parse(arguments) == expected)
    }
}
