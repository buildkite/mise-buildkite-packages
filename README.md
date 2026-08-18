# mise-buildkite-packages

A [mise backend plugin](https://mise.jdx.dev/backend-plugin-development.html)
that installs tools from a Buildkite Packages
[Files registry](https://buildkite.com/docs/package-registries/ecosystems/files).

The plugin uses the Buildkite Packages REST API to list package versions and the
registry's authenticated `/files/{filename}` endpoint to install the selected
version. It supports raw executables and `.zip`, `.tar.gz`, `.tar.xz`, and
`.tar.bz2` archives, and verifies downloads against the SHA-256 digest returned
by the API. `curl` is required for downloads.

## Try the local checkout

```sh
mise plugins link --force buildkite-packages ~/bk/mise-buildkite-packages
```

Then add a tool to `mise.toml`:

```toml
[settings]
experimental = true

[tools."buildkite-packages:README.md"]
version = "0.0.0"
organization = "buildkite"
registry = "test-files"
filename = "README.md"
```

```sh
mise ls-remote buildkite-packages:README.md
mise install buildkite-packages:README.md@0.0.0
```

The example uses the existing `buildkite/test-files` test registry. The package
is a text file rather than a runnable tool, but it exercises authenticated
version listing and downloading.

## Configure a tool

Buildkite Files package names and versions are parsed from filenames of the
form `{BASENAME}-{SEMVER}.{EXT}`. For platform-specific tools, put the platform
in the basename and publish one package per platform. For example:

```text
bktec-darwin-arm64-3.0.0.bin
bktec-linux-amd64-3.0.0.bin
```

Configure the logical mise tool with a package name template:

```toml
[tools."buildkite-packages:bktec"]
version = "3.0.0"
organization = "buildkite"
registry = "test-engine-client-files"
package = "bktec-{os}-{arch}"
extension = "{exe_ext}"
bin = "bktec"
```

`{tool}`, `{os}`, `{arch}`, and `{exe_ext}` are expanded by the plugin. `{os}`
and `{arch}` use mise's runtime names, such as `darwin`, `linux`, `arm64`, and
`amd64`. `{exe_ext}` is `exe` on Windows and `bin` elsewhere.

Available options:

| Option | Default | Purpose |
| --- | --- | --- |
| `organization` | `$BUILDKITE_ORGANIZATION_SLUG` | Buildkite organization slug |
| `registry` | `$BUILDKITE_PACKAGES_REGISTRY` | Files registry slug |
| `package` | mise tool name | Files package name; supports platform placeholders |
| `filename` | none | Exact filename; supports all placeholders below plus `{package}` and `{version}` |
| `extension` | none | Build the filename as `{package}-{version}.{extension}`; supports `{tool}`, `{os}`, `{arch}`, and `{exe_ext}` |
| `bin` | mise tool name | Installed name for a raw executable |
| `extract` | inferred from extension | Force or disable archive extraction |
| `strip_components` | `0` | Strip zero or one leading archive path component |

Raw files are installed as `bin/<bin>` and made executable. Archives are
extracted into the tool installation directory; both that directory and its
`bin` child are added to `PATH`. One of `filename` or `extension` is required;
`extension` is the concise choice for files following the registry's current
semver filename convention.

## Authentication

Credentials are selected in this order:

1. `BUILDKITE_PACKAGES_TOKEN`
2. `BUILDKITE_API_TOKEN`
3. A Buildkite Agent OIDC token when `$BUILDKITE_JOB_ID` is present
4. `bk auth token`

API and registry tokens need `read_packages`. For agent OIDC, configure the
registry with a matching `read_packages` policy. The plugin requests a token
whose audience is the registry's canonical URL:

```text
https://packages.buildkite.com/{organization}/{registry}
```

## Making the plugin available

Vendoring this small plugin in the consuming repository removes a network
bootstrap dependency. Mise releases containing the local-plugin fix from
[mise#11487](https://github.com/jdx/mise/pull/11487) can link it during
`mise install`:

```toml
[plugins]
buildkite-packages = "./vendor/mise-buildkite-packages"
```

Older versions, including mise 2026.6.12 currently used by Buildkite's
`mise#v1.1.3` plugin, need an explicit link before installation:

```sh
mise plugins link --force buildkite-packages ./vendor/mise-buildkite-packages
mise install
```

The Buildkite mise plugin has no pre-install hook for that link. For CI, either
bake the backend into the agent image under
`$MISE_DATA_DIR/plugins/buildkite-packages`, upgrade mise and vendor the plugin,
or add backend-plugin bootstrapping to the Buildkite mise plugin.

Once this prototype has a hosted Git repository, consumers that accept a Git
bootstrap dependency can use its URL instead:

```toml
[plugins]
buildkite-packages = "https://example.com/buildkite/mise-buildkite-packages.git"
```

In `buildkite/buildkite`, mise currently resolves the root
`github:buildkite/test-engine-client@latest` declaration while preparing the
plan-step environment even though `install_args: ruby` prevents installation
and the tests plugin supplies bktec. Replacing that declaration with this
backend removes that GitHub API lookup after the backend is bootstrapped.

The Buildkite mise plugin also downloads mise itself from GitHub on a cold
cache. Fully GitHub-independent CI therefore needs a preinstalled mise binary
or a configurable non-GitHub bootstrap source as well.

## Development

The smoke test uses an isolated mise data/config/cache/state directory and the
`buildkite/test-files` registry. It authenticates with the token environment
variables above or the local `bk` CLI:

```sh
mise run test
```

## License

MIT
