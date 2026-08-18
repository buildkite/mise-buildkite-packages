function PLUGIN:BackendListVersions(ctx)
    local semver = require("semver")
    local packages = dofile(RUNTIME.pluginDirPath .. "/lib/buildkite_packages.lua")
    local items, config = packages.list_packages(ctx)
    local versions = {}
    local seen = {}

    for _, item in ipairs(items) do
        if type(item.version) == "string" and item.version ~= "" and not seen[item.version] then
            table.insert(versions, item.version)
            seen[item.version] = true
        end
    end

    if #versions == 0 then
        error(
            "No versions of "
                .. config.package_name
                .. " were found in "
                .. config.organization
                .. "/"
                .. config.registry
        )
    end

    return { versions = semver.sort(versions) }
end
