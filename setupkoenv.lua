-- Set search path for `require()`.
package.path =
    "common/?.lua;frontend/?.lua;plugins/exporter.koplugin/?.lua;" ..
    package.path
package.cpath =
    "common/?.so;common/?.dll;/usr/lib/lua/?.so;" ..
    package.cpath
-- App Store bundles can only carry libraries inside frameworks, while the
-- libraries are asked for by their usual names (see embed-bundle-payload.sh).
if os.getenv("KO_IOS") == "1" then
    local ffi = require("ffi")
    local frameworks = {
        ["libSDL3.0.dylib"] = "SDL3",
        ["libkoreader-monolibtic.dylib"] = "koreader-monolibtic",
        ["libluajit.dylib"] = "luajit",
    }
    local function frameworkPath(lib)
        local name = frameworks[lib:match("[^/]+$")]
        local path = name and string.format("../Frameworks/%s.framework/%s", name, name)
        local file = path and io.open(path, "rb")
        if file then
            file:close()
            return path
        end
        return lib
    end
    local ffi_load, package_loadlib = ffi.load, package.loadlib
    ffi.load = function(lib, global) return ffi_load(frameworkPath(lib), global) end
    package.loadlib = function(lib, func) return package_loadlib(frameworkPath(lib), func) end
end
-- Setup `ffi.load` override and 'loadlib' helper.
require("ffi/loadlib")
