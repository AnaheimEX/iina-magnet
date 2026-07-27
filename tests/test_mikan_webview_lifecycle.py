from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MIKAN_VIEW = (
    REPOSITORY
    / "iina-magnet"
    / "Sources"
    / "IinaMagnet"
    / "UI"
    / "Library"
    / "MikanView.swift"
)
MIKAN_COOKIE_PERSISTENCE = (
    REPOSITORY
    / "iina-magnet"
    / "Sources"
    / "IinaMagnet"
    / "Mikan"
    / "MikanCookiePersistence.swift"
)
PIKPAK_TOKEN_STORE = (
    REPOSITORY
    / "iina-magnet"
    / "Sources"
    / "IinaMagnet"
    / "PikPak"
    / "PikPakTokenStore.swift"
)


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated function: {signature}")


class MikanWebViewLifecycleSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = MIKAN_VIEW.read_text(encoding="utf-8")

    def test_representable_never_publishes_during_swiftui_view_update(self):
        bind = function_body(cls_source := self.source, "fileprivate func bind(")
        self.assertNotIn("setReady", bind)
        self.assertNotIn("setLoadState", bind)
        self.assertNotIn("sync(", bind)

        make = function_body(cls_source, "func makeNSView(context: Context)")
        self.assertIn("Task { @MainActor", make)
        self.assertIn("publishBoundNavigatorState", make)
        self.assertIn("prepareAndLoadHomeIfNeeded", make)

        update = function_body(cls_source, "func updateNSView(")
        self.assertNotIn("setReady", update)
        self.assertNotIn("setLoadState", update)
        self.assertNotIn("navigator.sync", update)

    def test_navigator_deduplicates_published_state(self):
        set_ready = function_body(self.source, "func setReady(_ ready: Bool)")
        set_state = function_body(
            self.source,
            "func setLoadState(_ state: LoadState)",
        )
        self.assertIn("guard isReady != ready else { return }", set_ready)
        self.assertIn("guard loadState != state else { return }", set_state)

    def test_passive_keychain_access_never_prompts_or_blocks_the_login_ui(self):
        mikan = MIKAN_COOKIE_PERSISTENCE.read_text(encoding="utf-8")
        pikpak = PIKPAK_TOKEN_STORE.read_text(encoding="utf-8")

        for source in (mikan, pikpak):
            query = function_body(source, "private var nonInteractiveQuery:")
            self.assertIn("context.interactionNotAllowed = true", query)
            self.assertIn("kSecUseAuthenticationContext", query)

            load = function_body(source, "func load()")
            self.assertIn("nonInteractiveQuery", load)

        self.assertIn(
            "SecItemUpdate(nonInteractiveQuery as CFDictionary", mikan
        )
        self.assertIn(
            "SecItemDelete(nonInteractiveQuery as CFDictionary", mikan
        )
        self.assertIn(
            "SecItemUpdate(nonInteractiveQuery as CFDictionary", pikpak
        )
        self.assertIn(
            "SecItemDelete(nonInteractiveQuery as CFDictionary", pikpak
        )


if __name__ == "__main__":
    unittest.main()
