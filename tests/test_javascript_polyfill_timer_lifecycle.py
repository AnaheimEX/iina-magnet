from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
SOURCE = REPOSITORY / "iina" / "JavascriptPolyfill.swift"


class TimerRegistryModel:
    """Executable model of the pending -> active -> cleared/fired contract."""

    def __init__(self) -> None:
        self.pending: set[str] = set()
        self.active: dict[str, bool] = {}
        self.queued: list[tuple[str, bool]] = []
        self.next_id = 0

    def create(self, repeats: bool) -> str:
        self.next_id += 1
        identifier = str(self.next_id)
        self.pending.add(identifier)
        self.queued.append((identifier, repeats))
        return identifier

    def flush_main_queue(self) -> None:
        queued, self.queued = self.queued, []
        for identifier, repeats in queued:
            if identifier not in self.pending:
                continue
            self.pending.remove(identifier)
            self.active[identifier] = repeats

    def clear(self, identifier: str) -> None:
        self.pending.discard(identifier)
        self.active.pop(identifier, None)

    def clear_all(self) -> None:
        self.pending.clear()
        self.active.clear()

    def fire(self, identifier: str) -> bool:
        repeats = self.active.get(identifier)
        if repeats is None:
            return False
        if not repeats:
            self.active.pop(identifier)
        return True


class JavascriptPolyfillTimerLifecycleTests(unittest.TestCase):
    def test_async_creation_race_and_one_shot_cleanup_model(self) -> None:
        registry = TimerRegistryModel()

        cancelled_pending = registry.create(repeats=True)
        registry.clear(cancelled_pending)
        registry.flush_main_queue()
        self.assertEqual(registry.pending, set())
        self.assertEqual(registry.active, {})

        pending_a = registry.create(repeats=True)
        pending_b = registry.create(repeats=False)
        registry.clear_all()
        registry.flush_main_queue()
        self.assertNotIn(pending_a, registry.active)
        self.assertNotIn(pending_b, registry.active)

        repeating = registry.create(repeats=True)
        one_shot = registry.create(repeats=False)
        registry.flush_main_queue()
        self.assertTrue(registry.fire(repeating))
        self.assertIn(repeating, registry.active)
        self.assertTrue(registry.fire(one_shot))
        self.assertNotIn(one_shot, registry.active)
        registry.clear(repeating)
        self.assertEqual(registry.active, {})

    def test_swift_source_binds_the_model_to_pending_active_and_fire_transitions(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        create = source[source.index("func createTimer"):source.index("@objc func callJSCallback")]
        remove_all = source[source.index("func removeAllTimers"):source.index("func removeTimer")]
        remove_one = source[source.index("func removeTimer"):source.index("func createTimer")]
        callback = source[source.index("@objc func callJSCallback"):source.index("func register")]

        self.assertLess(create.index("pendingTimerIDs.insert(uuid)"), create.index("DispatchQueue.main.async"))
        self.assertIn("[weak self]", create)
        self.assertLess(create.index("pendingTimerIDs.remove(uuid) != nil"), create.index("Timer.scheduledTimer"))
        self.assertIn("pendingTimerIDs.remove(identifier)", remove_one)
        self.assertIn("timers.removeValue(forKey: identifier)", remove_one)
        self.assertIn("pendingTimerIDs.removeAll()", remove_all)
        self.assertIn("timers.removeAll()", remove_all)
        self.assertLess(callback.index("timers.removeValue"), callback.index("context.callback.call"))
        self.assertIn("if !context.repeats", callback)


if __name__ == "__main__":
    unittest.main()
