local cmd = require("cmd")
local http = require("http")
local json = require("json")

local M = {}

local cached_token = nil
local cached_token_source = nil

local function trim(value)
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function required_string(value, description)
    if type(value) ~= "string" or value == "" then
        error(description .. " is required")
    end

    return value
end

local function validate_slug(value, description)
    required_string(value, description)
    if not value:match("^[%w][%w_-]*$") then
        error(description .. " contains unsupported characters: " .. value)
    end

    return value
end

local function platform_value(value, description)
    return required_string(value, description):lower()
end

local function expand(value, replacements, description)
    required_string(value, description)
    for placeholder, replacement in pairs(replacements) do
        value = value:gsub(placeholder, function()
            return replacement
        end)
    end

    local unknown = value:match("({[^}]+})")
    if unknown then
        error("Unknown " .. description:lower() .. " placeholder: " .. unknown)
    end

    return value
end

local function url_encode(value)
    return value:gsub("([^%w%-%._~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
end

local function command_token(command)
    local ok, output = pcall(cmd.exec, command)
    if not ok or type(output) ~= "string" then
        return nil
    end

    output = trim(output)
    if output == "" then
        return nil
    end

    return output
end

function M.command_quote(value)
    if RUNTIME.osType:lower() == "windows" then
        return '"' .. value:gsub('"', '\\"') .. '"'
    end

    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function token_for(config)
    if cached_token then
        return cached_token, cached_token_source
    end

    for _, variable in ipairs({ "BUILDKITE_PACKAGES_TOKEN", "BUILDKITE_API_TOKEN" }) do
        local token = os.getenv(variable)
        if token and trim(token) ~= "" then
            cached_token = trim(token)
            cached_token_source = variable
            return cached_token, cached_token_source
        end
    end

    if os.getenv("BUILDKITE_JOB_ID") then
        local token = command_token(
            "buildkite-agent oidc request-token --audience " .. config.audience .. " --lifetime 300"
        )
        if token then
            cached_token = token
            cached_token_source = "Buildkite Agent OIDC"
            return cached_token, cached_token_source
        end
    end

    local token = command_token("bk auth token")
    if token then
        cached_token = token
        cached_token_source = "bk auth token"
        return cached_token, cached_token_source
    end

    error(
        "Could not authenticate to Buildkite Packages. Set BUILDKITE_PACKAGES_TOKEN or "
            .. "BUILDKITE_API_TOKEN, run inside a Buildkite job with registry OIDC access, "
            .. "or authenticate the bk CLI."
    )
end

local function request_headers(config, accept)
    local token, source = token_for(config)
    return {
        ["Accept"] = accept,
        ["Authorization"] = "Bearer " .. token,
        ["User-Agent"] = "mise-buildkite-packages/" .. PLUGIN.version .. " (auth: " .. source .. ")",
    }
end

local function decode_response(response, url)
    if response.status_code < 200 or response.status_code >= 300 then
        error("Buildkite Packages returned HTTP " .. response.status_code .. " for " .. url)
    end

    local ok, decoded = pcall(json.decode, response.body)
    if not ok then
        error("Buildkite Packages returned invalid JSON for " .. url)
    end

    return decoded
end

function M.config(ctx)
    local options = ctx.options or {}
    local tool = required_string(ctx.tool, "Tool name")
    local organization = options.organization or os.getenv("BUILDKITE_ORGANIZATION_SLUG")
    local registry = options.registry or os.getenv("BUILDKITE_PACKAGES_REGISTRY")
    local runtime_os = platform_value(RUNTIME.osType, "Runtime OS")
    local platform_replacements = {
        ["{tool}"] = tool,
        ["{os}"] = runtime_os,
        ["{arch}"] = platform_value(RUNTIME.archType, "Runtime architecture"),
        ["{exe_ext}"] = runtime_os == "windows" and "exe" or "bin",
    }
    local package_name = expand(options.package or tool, platform_replacements, "Package name")

    validate_slug(organization, "Buildkite organization")
    validate_slug(registry, "Buildkite Packages registry")

    local extract = options.extract
    if extract ~= nil and type(extract) ~= "boolean" then
        error("extract must be true or false")
    end

    local strip_components = options.strip_components or 0
    if strip_components ~= 0 and strip_components ~= 1 then
        error("strip_components must be 0 or 1")
    end

    local bin = expand(options.bin or tool, platform_replacements, "Executable name")
    if bin == "." or bin == ".." or bin:find("[/\\]") then
        error("bin must be a file name, not a path: " .. bin)
    end

    local audience = "https://packages.buildkite.com/" .. organization .. "/" .. registry

    return {
        organization = organization,
        registry = registry,
        package_name = package_name,
        audience = audience,
        extract = extract,
        strip_components = strip_components,
        bin = bin,
        platform_replacements = platform_replacements,
    }
end

function M.filename(ctx, config)
    local options = ctx.options or {}
    local version = required_string(ctx.version, "Version")
    local replacements = {
        ["{tool}"] = config.platform_replacements["{tool}"],
        ["{os}"] = config.platform_replacements["{os}"],
        ["{arch}"] = config.platform_replacements["{arch}"],
        ["{exe_ext}"] = config.platform_replacements["{exe_ext}"],
        ["{package}"] = config.package_name,
        ["{version}"] = version,
    }
    local filename

    if options.filename then
        filename = expand(options.filename, replacements, "Filename")
    elseif options.extension then
        local extension = expand(options.extension, replacements, "File extension")
        if extension:find("[/\\]") then
            error("extension must not contain a path separator")
        end
        filename = config.package_name .. "-" .. version .. "." .. extension
    else
        error("Set filename or extension so the package download URL can be constructed")
    end

    if filename == "." or filename == ".." or filename:find("[/\\]") then
        error("filename must be a file name, not a path: " .. filename)
    end

    return filename
end

function M.list_packages(ctx)
    local config = M.config(ctx)
    local url = "https://api.buildkite.com/v2/packages/organizations/"
        .. config.organization
        .. "/registries/"
        .. config.registry
        .. "/packages?per_page=100&name="
        .. url_encode(config.package_name)
    local packages = {}

    while url do
        local response, request_error = http.try_get({
            url = url,
            headers = request_headers(config, "application/json"),
        })
        if request_error then
            error("Could not list Buildkite Packages: " .. request_error)
        end

        local data = decode_response(response, url)
        if type(data.items) ~= "table" then
            error("Buildkite Packages response did not contain an items list")
        end

        for _, item in ipairs(data.items) do
            if item.name == config.package_name then
                table.insert(packages, item)
            end
        end

        -- The Packages API emits cursor links in both the JSON body and Link header.
        url = data.links and data.links.next or nil
    end

    return packages, config
end

function M.find_package(ctx)
    local packages, config = M.list_packages(ctx)
    for _, item in ipairs(packages) do
        if item.version == ctx.version then
            return item, config
        end
    end

    error(
        "Package "
            .. config.package_name
            .. "@"
            .. required_string(ctx.version, "Version")
            .. " was not found in "
            .. config.organization
            .. "/"
            .. config.registry
    )
end

function M.download(config, filename, destination)
    local url = config.audience .. "/files/" .. url_encode(filename)
    http.download_file({
        url = url,
        headers = request_headers(config, "application/octet-stream"),
    }, destination)
end

function M.verify_sha256(pkg, destination)
    local expected = pkg.digests and pkg.digests.sha256
    if type(expected) ~= "string" or #expected ~= 64 or not expected:match("^%x+$") then
        error("Buildkite Packages API response did not include a valid SHA-256 digest")
    end

    local command
    if RUNTIME.osType:lower() == "windows" then
        command = "certutil -hashfile " .. M.command_quote(destination) .. " SHA256"
    elseif RUNTIME.osType:lower() == "darwin" then
        command = "shasum -a 256 " .. M.command_quote(destination)
    else
        command = "sha256sum " .. M.command_quote(destination)
    end

    local ok, output = pcall(cmd.exec, command)
    if not ok then
        error("Could not calculate the downloaded package's SHA-256 digest: " .. output)
    end

    local actual
    for line in output:gmatch("[^\r\n]+") do
        local compact = line:gsub("%s", "")
        if #compact == 64 and compact:match("^%x+$") then
            actual = compact
            break
        end

        local hash = line:match("^(%x+)")
        if hash and #hash == 64 then
            actual = hash
            break
        end
    end

    if not actual then
        error("Could not parse the downloaded package's SHA-256 digest")
    end
    if actual:lower() ~= expected:lower() then
        error("Downloaded package SHA-256 digest did not match the Buildkite Packages API")
    end
end

return M
