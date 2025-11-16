-- ChromeBookmarks.spoon
-- A tiny companion Spoon that loads a custom Seal plugin to search Google Chrome bookmarks.
-- Place this folder as ~/.hammerspoon/Spoons/ChromeBookmarks.spoon/
-- Then in your init.lua:
--   hs.loadSpoon("Seal")
--   spoon.Seal:start()
--   hs.loadSpoon("ChromeBookmarks")
--   spoon.ChromeBookmarks.profiles = "auto"           -- or { "Default", "Profile 1" }
--   spoon.ChromeBookmarks.keyword = "cb"              -- type: "cb <query>"
--   spoon.ChromeBookmarks.openBehavior = "chrome"     -- "chrome" or "default"
--   spoon.ChromeBookmarks.maxResults = 200
--   spoon.ChromeBookmarks:bindToSeal(spoon.Seal)

local obj = {}
obj.__index = obj

obj.name = "ChromeBookmarks"
obj.version = "0.1.0"
obj.author = "ChatGPT"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT"

-- User-configurable values (you can override from hs.init.lua before calling :bindToSeal)
obj.keyword = "cb"                -- Seal command keyword
obj.profiles = "auto"             -- "auto" or list like { "Default", "Profile 1" }
obj.maxResults = 200              -- clamp results shown in Seal
obj.openBehavior = "chrome"       -- "chrome" | "default"

-- Helper to get the absolute path of this spoon, for loading the plugin file.
local function scriptPath()
  local str = debug.getinfo(2, "S").source:sub(2)
  return str:match("(.*/)") or ""
end
obj.spoonPath = scriptPath()

-- Bind this Spoon to a running Seal instance by loading the plugin from our folder and passing config
function obj:bindToSeal(seal)
  if not seal then
    hs.alert.show("ChromeBookmarks: Seal instance not provided")
    return self
  end

  local pluginFile = self.spoonPath .. "seal_chrome_bookmarks.lua"
  if hs.fs.attributes(pluginFile) == nil then
    hs.alert.show("ChromeBookmarks: plugin file not found at " .. pluginFile)
    return self
  end

  -- Load plugin from our file path
  local ok = seal:loadPluginFromFile("chrome_bookmarks", pluginFile)
  if not ok then
    hs.alert.show("ChromeBookmarks: failed to load plugin into Seal")
    return self
  end

  -- Pass configuration into the plugin (mirrors Safari plugin pattern of setting vars on module table)
  local p = seal.plugins.chrome_bookmarks
  if p then
    p.keyword = self.keyword or p.keyword
    p.maxResults = self.maxResults or p.maxResults
    p.openBehavior = self.openBehavior or p.openBehavior
    p.profiles = self.profiles or p.profiles

    if p.logger and self.logLevel then
      p.logger:setLogLevel(self.logLevel)
    end
  end

  -- Let Seal re-register commands in case keyword changed
  if seal.refreshCommandsForPlugin then
    seal:refreshCommandsForPlugin("chrome_bookmarks")
  elseif seal.refreshAllCommands then
    seal:refreshAllCommands()
  end

  return self
end

return obj
