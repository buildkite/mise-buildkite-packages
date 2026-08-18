local function archive_name(filename)
    local lower = filename:lower()
    return lower:match("%.zip$")
        or lower:match("%.tar%.gz$")
        or lower:match("%.tar%.xz$")
        or lower:match("%.tar%.bz2$")
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function PLUGIN:BackendInstall(ctx)
    local archiver = require("archiver")
    local cmd = require("cmd")
    local file = require("file")
    local packages = dofile(RUNTIME.pluginDirPath .. "/lib/buildkite_packages.lua")

    local package, config = packages.find_package(ctx)
    local filename = packages.filename(ctx, config)
    local extract = config.extract
    if extract == nil then
        extract = archive_name(filename) ~= nil
    end

    if extract then
        if not archive_name(filename) then
            error("extract=true requires a .zip, .tar.gz, .tar.xz, or .tar.bz2 package")
        end

        local download_path = file.join_path(ctx.download_path, filename)
        packages.download(config, filename, download_path)
        packages.verify_sha256(package, download_path)
        archiver.decompress(download_path, ctx.install_path, {
            strip_components = config.strip_components,
        })
    else
        local installed_file = file.join_path(ctx.install_path, "bin", config.bin)
        packages.download(config, filename, installed_file)
        packages.verify_sha256(package, installed_file)

        if RUNTIME.osType:lower() ~= "windows" then
            cmd.exec("chmod 0755 " .. shell_quote(installed_file))
        end
    end

    return {}
end
