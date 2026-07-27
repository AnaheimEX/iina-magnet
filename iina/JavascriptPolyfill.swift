//
//  JavascriptPolyfill.swift
//  iina
//
//  Created by Collider LI on 6/3/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import JavaScriptCore

private final class JavascriptTimerContext {
  let identifier: String
  let callback: JSValue
  let repeats: Bool

  init(identifier: String, callback: JSValue, repeats: Bool) {
    self.identifier = identifier
    self.callback = callback
    self.repeats = repeats
  }
}

class JavascriptPolyfill {
  weak var plugin: JavascriptPluginInstance!
  private var timers = [String: Timer]()
  private var pendingTimerIDs = Set<String>()

  init(pluginInstance: JavascriptPluginInstance) {
    self.plugin = pluginInstance
  }

  deinit {
    removeAllTimers()
  }

  private func onMainThread(_ action: () -> Void) {
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.sync(execute: action)
    }
  }

  func removeAllTimers() {
    onMainThread {
      pendingTimerIDs.removeAll()
      for timer in timers.values {
        timer.invalidate()
      }
      timers.removeAll()
    }
  }

  func removeTimer(identifier: String) {
    onMainThread {
      pendingTimerIDs.remove(identifier)
      let timer = timers.removeValue(forKey: identifier)
      timer?.invalidate()
    }
  }

  func createTimer(callback: JSValue, ms: Double, repeats : Bool) -> String {
    let timeInterval  = ms/1000.0
    let uuid = NSUUID().uuidString
    onMainThread {
      pendingTimerIDs.insert(uuid)
    }

    DispatchQueue.main.async { [weak self] in
      guard let self, self.pendingTimerIDs.remove(uuid) != nil else { return }
      let context = JavascriptTimerContext(identifier: uuid, callback: callback, repeats: repeats)
      let timer = Timer.scheduledTimer(timeInterval: timeInterval,
                                       target: self,
                                       selector: #selector(self.callJSCallback),
                                       userInfo: context,
                                       repeats: repeats)
      self.timers[uuid] = timer
    }
    return uuid
  }

  @objc func callJSCallback(_ timer: Timer) {
    guard timer.isValid, let context = timer.userInfo as? JavascriptTimerContext else {
      timer.invalidate()
      return
    }
    if !context.repeats {
      timers.removeValue(forKey: context.identifier)
      timer.invalidate()
    }
    context.callback.call(withArguments: nil)
  }

  func register(inContext context: JSContext) {
    let setInterval: @convention(block) (JSValue, Double) -> String = { [unowned self] (callback, ms) in
      return self.createTimer(callback: callback, ms: ms, repeats: true)
    }

    let setTimeout: @convention(block) (JSValue, Double) -> String = { [unowned self] (callback, ms) in
      return self.createTimer(callback: callback, ms: ms, repeats: false)
    }

    let clearInterval: @convention(block) (String) -> () = { [unowned self] identifier in
      self.removeTimer(identifier: identifier)
    }

    let clearTimeout: @convention(block) (String) -> () = { [unowned self] identifier in
      self.removeTimer(identifier: identifier)
    }

    let require: @convention(block) (String) -> Any? = { [unowned self] path in
      let instance = self.plugin!
      let currentPath = instance.currentFile!.deletingLastPathComponent()
      let requiredURL = currentPath.appendingPathComponent(path).standardized
      guard requiredURL.absoluteString.hasPrefix(instance.plugin.root.absoluteString) else {
        return nil
      }
      return [
        "path": requiredURL.path,
        "module": instance.evaluateFile(requiredURL, asModule: true)
      ] as [String: Any?]
    }

    context.setObject(clearInterval, forKeyedSubscript: "clearInterval" as NSString)
    context.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)
    context.setObject(setInterval, forKeyedSubscript: "setInterval" as NSString)
    context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
    context.setObject(require, forKeyedSubscript: "__require__" as NSString)
    context.evaluateScript(requirePolyfill)
  }
}

fileprivate let requirePolyfill = """
require = (() => {
  const cache = {};
  return function (file) {
    if (cache[file]) {
      return cache[file];
    }
    const result = __require__(file);
    if (result) {
      cache[result.path] = result.module;
      return result.module;
    }
    return undefined;
  };
})();
"""
