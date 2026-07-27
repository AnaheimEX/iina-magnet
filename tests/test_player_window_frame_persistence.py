import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]


class PlayerWindowFramePersistenceTests(unittest.TestCase):
    def test_default_behavior_restores_the_last_window_frame(self):
        preference = (REPOSITORY / "iina" / "Preference.swift").read_text()
        controller = (REPOSITORY / "iina" / "MainWindowController.swift").read_text()

        self.assertIn("static var defaultValue = ResizeWindowTiming.never", preference)
        self.assertIn(
            ".resizeWindowTiming: ResizeWindowTiming.defaultValue.rawValue",
            preference,
        )
        self.assertIn("private func savedWindowFrame", controller)
        self.assertIn("resizeTiming == .never", controller)
        self.assertIn("shouldApplyInitialWindowSize", controller)
        self.assertIn("windowFrameFromGeometry() == nil", controller)
        self.assertIn("savedWindowFrame(constrainedTo: screenRect)", controller)

    def test_fullscreen_close_saves_the_prior_windowed_frame(self):
        controller = (REPOSITORY / "iina" / "MainWindowController.swift").read_text()
        self.assertIn(
            "let windowedFrame = fsState.priorWindowedFrame ?? w.frame",
            controller,
        )


if __name__ == "__main__":
    unittest.main()
