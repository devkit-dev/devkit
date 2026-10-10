# devkit parameters

devkit reads these parameters from the git-config of the project for which the
agent is started.

Devkit tags agent bases as `localhost/devkit/base/<agent>:latest` and
`localhost/devkit/base/<agent>:<version>`. Bases contain fixed packages
and agent dependencies. Compatible repositories share them; project
packages, optional services, and custom build commands belong to project
images. Release strings unsuitable for image tags use a
`version-<sha256>` tag; the original release remains in the image
labels.

The `upgrade` command reuses a compatible base for the latest agent
release, then reuses or builds a matching project image. Compatibility
includes the base recipe, devkit version, and host UID:GID. If no
current compatible base exists, it pulls the latest Ubuntu image before
building the base. All builds retain intermediate-layer caching. An
upgrade fails if the latest agent release cannot be determined.

After successfully building a new base and preparing the project image,
upgrade cleans only replaced, unused images. Referenced older versions,
unrelated image tags, and cached parent layers are preserved. Other
repositories retain their existing images until explicitly upgraded.
`clean` retains shared bases; `clean-all` removes them. Podman's
untagged intermediate cache remains under podman cache management.

Inspect configuration:

```sh
git config devkit.agent
git config --get-all devkit.packages
```

## devkit.agent

Defines which AI agent should be executed.

See [README.md](../README.md) for the list of supported agents.

Example:

```sh
git config devkit.agent codex
```

## devkit.reponame

Overrides the repository name used in the podman container and image
names. The default is the basename of the repository directory. This
parameter does not change the repository mount point or working
directory inside the container.

The value must be at most 238 characters. It must consist of lowercase
letters and digits, optionally separated by a period, one or two
underscores, or one or more hyphens. It must start and end with a letter
or digit.

Example:

```sh
git config devkit.reponame normalized-name
```

## devkit.shell

This variable allows you to override the shell that will be used in the
container (the default is `/bin/bash`). If the user changes this parameter,
user must take care of installing shell package in the container.

## devkit.check-upgrade

Checks for a newer devkit release when `devkit run` starts. The check is
enabled by default. Set the parameter to `false` to disable it.

Example:

```sh
git config devkit.check-upgrade false
```

## devkit.packages

List of Ubuntu packages installed into the container.

Example:

```sh
git config --add devkit.packages gcc
git config --add devkit.packages make
git config --add devkit.packages gdb
```

## devkit.volumes

Additional list of podman volumes to mount into the container.

## devkit.env-file

Additional list of podman-compatible environment files to pass into the
container at runtime.

Example:

```sh
git config --add devkit.env-file .env
git config --add devkit.env-file .env.local
```

## devkit.caps

A list of capabilities to be added or removed. Caps beginning with `+` will be
added, and those beginning with `-` will be removed.

## devkit.hooks-path

Path to a directory with container lifecycle hooks.

When the path exists, devkit mounts it read-only as `/.devkit/hooks.d` and runs
the handlers with `run-parts` from the container entrypoint before starting the
agent or development shell. The current lifecycle stage is passed as the first
argument and is currently always `start`.

Example:

```sh
git config devkit.hooks-path ~/devkit/hooks.d
```

Example hook:

```sh
#!/bin/sh
[ "$1" = start ] || exit 0
echo "container is starting"
```

## devkit.build-command

Shell fragment executed as root while building the project image.

This is intended for project-specific image customization that does not
fit into the package list, such as installing extra tools from a mounted
script. The command value is part of the project-image identity.
Changing it builds a new project image from the existing agent base.
Removing it restores the empty-command identity; devkit reuses an existing
matching project image when one is available.

Example:

```sh
git config devkit.build-command /mnt/devkit-hooks/install-tools.sh
```

## devkit.build-volumes

Additional list of podman volumes to mount only while building the image.

These volumes are passed to `podman image build` and can be used by
`devkit.build-command`.

Example:

```sh
git config --add devkit.build-volumes /home/me/devkit-hooks:/mnt/devkit-hooks:ro,Z
```

## devkit.build-id

Identifier for custom build inputs.

This value is part of the image identity and defaults to `none`. Change it
when files used by `devkit.build-command` change, especially when those files
come from `devkit.build-volumes`. devkit cannot detect content changes inside
arbitrary build volumes automatically. The value also invalidates the cached
custom-build layer.

Example:

```sh
git config devkit.build-id tools-2026-05-03
```

## devkit.sashiko

Enables the optional Sashiko Linux kernel review service. See
[sashiko.md](sashiko.md) for its commands and the `devkit.sashiko-provider` and
`devkit.sashiko-model` parameters.

## devkit.ollama

Enables the optional Ollama service. See [ollama.md](ollama.md) for its
commands, host requirements, and persistent data.
