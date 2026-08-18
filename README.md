# mise-buildkite-packages

A [mise backend plugin](https://mise.jdx.dev/backend-plugin-development.html)
that installs tools from a Buildkite Packages
[Files registry](https://buildkite.com/docs/package-registries/ecosystems/files).

The plugin uses the Buildkite Packages REST API to list package versions and the
registry's authenticated `/files/{filename}` endpoint to install the selected
version. It supports raw executables and `.zip`, `.tar.gz`, `.tar.xz`, and
`.tar.bz2` archives, and verifies downloads against the SHA-256 digest returned
by the API.

## Try the local checkout

```sh
mise plugins link --force buildkite-packages ~/bk/mise-buildkite-packages
```

Then add a tool to `mise.toml`:

```toml
[settings]
experimental = true

[tools."buildkite-packages:bktec"]
version = "3.0.0"
organization = "buildkite"
registry = "bktec"
package = "bktec-{os}-{arch}"
bin = "bktec"
```

```sh
mise ls-remote buildkite-packages:bktec
mise install buildkite-packages:bktec@3.0.0
mise exec buildkite-packages:bktec@3.0.0 -- bktec --version
```

The example installs the Test Engine client from the public
[`buildkite/bktec`](https://buildkite.com/organizations/buildkite/packages/registries/bktec)
registry. The registry is public, but listing versions goes through the REST
API, which always needs a token — see [Authentication](#authentication).

## Configure a tool

Buildkite Files package names and versions are parsed from filenames of the
form `{BASENAME}-{SEMVER}.{EXT}`. For platform-specific tools, put the platform
in the basename and publish one package per platform, as `buildkite/bktec`
does:

```text
bktec-darwin-arm64-3.0.0.bin
bktec-linux-amd64-3.0.0.bin
bktec-windows-amd64-3.0.0.exe
```

A package name template collapses those into one logical mise tool:

```toml
[tools."buildkite-packages:bktec"]
version = "3.0.0"
organization = "buildkite"
registry = "bktec"
package = "bktec-{os}-{arch}"
bin = "bktec"
```

`{tool}`, `{os}`, `{arch}`, and `{exe_ext}` are expanded by the plugin. `{os}`
and `{arch}` use mise's runtime names, such as `darwin`, `linux`, `arm64`, and
`amd64`. `{exe_ext}` is `exe` on Windows and `bin` elsewhere.

Note that the example above sets no extension. The registry records each
published file's extension as the package's *variant* and returns it from the
API, so the plugin reconstructs `bktec-darwin-arm64-3.0.0.bin` on macOS and
`bktec-windows-amd64-3.0.0.exe` on Windows without being told which is which.

Available options:

| Option | Default | Purpose |
| --- | --- | --- |
| `organization` | `$BUILDKITE_ORGANIZATION_SLUG` | Buildkite organization slug |
| `registry` | `$BUILDKITE_PACKAGES_REGISTRY` | Files registry slug |
| `package` | mise tool name | Files package name; supports `{tool}`, `{os}`, `{arch}`, and `{exe_ext}` |
| `extension` | the package's variant | Select one variant when a version has several; supports the same placeholders as `package` |
| `filename` | derived from the variant | Exact filename, which also selects a variant; supports the same placeholders plus `{package}` and `{version}` |
| `bin` | mise tool name | Installed name for a raw executable |
| `extract` | inferred from extension | Force or disable archive extraction |
| `strip_components` | `0` | Strip zero or one leading archive path component |

Raw files are installed as `bin/<bin>` and made executable. Archives are
extracted into the tool installation directory; both that directory and its
`bin` child are added to `PATH`.

### Choosing between variants

A Files package is identified by its name, version *and* variant, so one
version can be published in several formats. Publishing a detached checksum
next to a binary produces exactly that:

```text
bktec-linux-amd64-3.0.0.bin           variant "bin"
bktec-linux-amd64-3.0.0.bin.sha256    variant "bin.sha256"
```

The plugin will not guess between them. It fails with the available variants
listed, and `extension` picks one:

```toml
extension = "bin"
```

An exact `filename` selects a variant too, since it already names one of the
published files, so it does not need an `extension` alongside it.

Set one of the two up front if a registry publishes more than one format per
version. Leaving both out is the concise choice, but it resolves against
whatever the registry holds at install time, so publishing a second variant
later turns a working configuration into that error.

`extension` additionally narrows `ls-remote` to versions published in that
format. `filename` cannot: listing has no version to expand `{version}`
against.

Legacy Packagecloud-backed Files registries report no variant at all. There,
`filename` or `extension` is required, and the plugin says so.

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

The `bk` fallback requires `bk` to be on the backend hook's `PATH`. If a local
mise configuration manages `bk` but does not expose it there, export its token
for the install instead:

```sh
BUILDKITE_PACKAGES_TOKEN="$(bk auth token)" mise install
```

## Making the plugin available

Vendoring this small plugin in the consuming repository removes a network
bootstrap dependency. Mise 2026.7.18 and newer contain the local-plugin fix from
[mise#11487](https://github.com/jdx/mise/pull/11487), so they can link it during
`mise install`:

```toml
[plugins]
buildkite-packages = "./vendor/mise-buildkite-packages"
```

Older versions need an explicit link before installation:

```sh
mise plugins link --force buildkite-packages ./vendor/mise-buildkite-packages
mise install
```

The Buildkite mise plugin has no pre-install hook for that link. For CI, either
bake the backend into the agent image under
`$MISE_DATA_DIR/plugins/buildkite-packages`, upgrade mise and vendor the plugin,
or add backend-plugin bootstrapping to the Buildkite mise plugin.

Once this prototype is published, consumers that accept a Git bootstrap
dependency can pin its repository and tag instead:

```toml
[plugins]
buildkite-packages = "https://github.com/buildkite/mise-buildkite-packages.git#v0.1.0"
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
`buildkite/mise-buildkite-packages-test` registry. It authenticates with the
token environment variables above or the local `bk` CLI:

```sh
mise run test
```

CI runs the same task in the public
[mise-buildkite-packages](https://buildkite.com/buildkite/mise-buildkite-packages)
pipeline on the Open Source cluster. It configures no credentials: inside a
Buildkite job the plugin exchanges an agent OIDC token for registry access, so
the fixture registry carries a `read_packages` OIDC policy for this pipeline.
Builds from forks start with a block step, because a fork's pull request can
rewrite these steps and so mint that token.

## License

MIT
