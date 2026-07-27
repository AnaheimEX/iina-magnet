import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]


class MediaLibraryRemovalUITests(unittest.TestCase):
    def test_removal_is_discoverable_confirmed_and_non_destructive(self):
        window = (REPOSITORY / "iina-magnet" / "Sources" / "IinaMagnet" / "UI" /
                  "Library" / "LibraryWindowView.swift").read_text()
        archive = (REPOSITORY / "iina-magnet" / "Sources" / "IinaMagnet" / "UI" /
                   "Library" / "ArchiveView.swift").read_text()
        components = (REPOSITORY / "iina-magnet" / "Sources" / "IinaMagnet" / "UI" /
                      "Library" / "LibraryComponents.swift").read_text()

        self.assertIn("confirmationDialog", window)
        self.assertIn("不会删除磁盘上的源文件", window)
        self.assertIn("removeFromLibrary", window)
        self.assertIn("从媒体库移除", archive)
        self.assertIn("contextMenu", components)
        self.assertIn("role: .destructive", components)


if __name__ == "__main__":
    unittest.main()
