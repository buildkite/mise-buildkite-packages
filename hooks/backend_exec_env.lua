function PLUGIN:BackendExecEnv(ctx)
    local file = require("file")

    return {
        env_vars = {
            {
                key = "PATH",
                value = file.join_path(ctx.install_path, "bin"),
            },
            {
                key = "PATH",
                value = ctx.install_path,
            },
        },
    }
end
