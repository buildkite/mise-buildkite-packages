function PLUGIN:BackendExecEnv(ctx)
    local file = require("file")
    local path_separator = package.config:sub(1, 1) == "\\" and ";" or ":"

    return {
        env_vars = {
            {
                key = "PATH",
                value = file.join_path(ctx.install_path, "bin") .. path_separator .. ctx.install_path,
            },
        },
    }
end
