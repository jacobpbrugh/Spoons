# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the official repository of Hammerspoon Spoons - a collection of plugins/extensions for Hammerspoon, a macOS automation tool. Each Spoon is a self-contained Lua module that provides specific functionality.

**Official Spoon repository:** http://www.hammerspoon.org/Spoons
**Main documentation:** https://github.com/Hammerspoon/hammerspoon/blob/master/SPOONS.md

## Repository Structure

```
Source/               # Source code for all Spoons
  <Name>.spoon/      # Individual Spoon directory
    init.lua         # Main Spoon implementation
    docs.json        # Auto-generated documentation metadata
    *.lua            # Additional plugin files (for complex Spoons)
    *.png            # Assets (icons, images)

Spoons/              # Built/packaged Spoons (zip files)
  <Name>.spoon.zip   # Distributed binary package

docs/                # Published HTML documentation (auto-generated)
```

## Development Workflow

### Building Spoons

**Build all Spoons:**
```bash
make
```

**Build specific Spoon:**
```bash
make Spoons/<SpoonName>.spoon.zip
```

**Clean built packages:**
```bash
make clean
```

### Documentation

**Generate documentation for all Spoons:**
```bash
./build_docs.sh
```
Requires the Hammerspoon repository to be in `../hammerspoon` or `./hammerspoon`.

**Lint documentation for a specific Spoon:**
```bash
python3 ../hammerspoon/scripts/docs/bin/build_docs.py -l -o /tmp/ -n Source/<SpoonName>.spoon
```

**Generate docs.json for a specific Spoon:**
```bash
python3 ../hammerspoon/scripts/docs/bin/build_docs.py -e ../hammerspoon/scripts/docs/templates/ -o Source/<SpoonName>.spoon/ -j -n Source/<SpoonName>.spoon/
```

### Merging New Spoons

Use `merge_spoon.sh` to merge a PR and generate all documentation:
```bash
./merge_spoon.sh <PR_NUMBER> <SpoonName>
# Or skip fetching PR: ./merge_spoon.sh 0 <SpoonName>
```

## Spoon Architecture

### Basic Spoon Structure

Every Spoon follows this pattern:

```lua
--- === SpoonName ===
---
--- Brief description
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpoonName.spoon.zip](...)

local obj = {}
obj.__index = obj

-- Metadata (required)
obj.name = "SpoonName"
obj.version = "1.0"
obj.author = "Author Name <email>"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Variables, methods, etc.

return obj
```

### Documentation Format

Use Lua doc comments (triple dash `---`) following Hammerspoon's conventions:

```lua
--- SpoonName.variableName
--- Variable
--- Description of the variable
---
--- Notes:
---  * Additional notes if needed
obj.variableName = defaultValue

--- SpoonName:methodName(param1, param2)
--- Method
--- Description of what the method does
---
--- Parameters:
---  * param1 - description
---  * param2 - description
---
--- Returns:
---  * Description of return value
---
--- Notes:
---  * Additional notes
function obj:methodName(param1, param2)
  -- implementation
end
```

### Plugin-Based Spoons

Some Spoons support plugins (e.g., Seal). Plugin files follow naming convention:
- Main spoon: `init.lua`
- Plugins: `<spoonname>_<pluginname>.lua` (e.g., `seal_apps.lua`, `seal_calc.lua`)

### Configuration Pattern

Many Spoons use a metatable pattern for reactive configuration:

```lua
local _store = {}
setmetatable(obj,
  { __index = function(_, k) return _store[k] end,
    __newindex = function(t, k, v)
      rawset(_store, k, v)
      if t._init_done and t._attribs[k] then
        t:init()  -- Reinitialize when config changes
      end
    end
  })
```

## CI/CD Pipeline

GitHub Actions automatically:
1. Lints documentation on PRs and pushes to master
2. Rebuilds docs.json for modified Spoons
3. Regenerates zip packages
4. Updates HTML documentation
5. Auto-commits changes

**PR workflow** (`.github/workflows/PR.yml`):
- Checks out both Spoons and Hammerspoon repos
- Detects modified .lua files
- Runs `gh_actions_doclint.sh` for validation
- Runs `gh_actions_publish.sh` to rebuild docs and zips
- Auto-commits if push to master

## Common Spoon Patterns

### Initialization
```lua
function obj:init()
  -- Setup code
  self._init_done = true
  return self
end
```

### Start/Stop
```lua
function obj:start()
  -- Enable functionality
  return self
end

function obj:stop()
  -- Disable functionality
  return self
end
```

### Hotkey Binding
```lua
function obj:bindHotkeys(mapping)
  local spec = {
    show = hs.fnutils.partial(self.show, self),
    hide = hs.fnutils.partial(self.hide, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end
```

## Important Notes

- Each Spoon must be self-contained in its `.spoon` directory
- The `docs.json` file is auto-generated - never edit manually
- Always run documentation linting before submitting PRs
- Spoon names use CamelCase (e.g., `MouseFollowsFocus`)
- Documentation follows strict format for automated processing
- Lua version: Uses Hammerspoon's embedded Lua runtime
- I set `MJConfigFile` to ~/.config/hammerspoon/init.lua and my recency file to hs.configDir .. <filename> so  that Seal freqency file is store under  ~/.config/hammerspoon/ for my setup