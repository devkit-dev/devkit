# devkit

devkit is a makefile-based utility for running AI agents inside isolated podman
containers with project-specific dependencies.

**Disclaimer**: devkit provides process isolation, not security isolation.
Nothing prevents an agent from running destructive commands such as
`rm -rf .git` inside your mounted project directory.

## Design Goals

- zero additional tooling beyond Makefile
- no custom configuration formats
- explicit and inspectable behavior
- easy debugging using podman
- safe execution of AI agents

## Limitations

- Agent conversation history is not shared between containers and the host
  system. Projects are mounted at `/srv` rather than at their original host
  path, so the agent treats them as different projects.

- Images are not portable across hosts. The container user is created with the
  host's UID:GID, so an image built on one machine will not work on another
  with different user IDs.

## Architecture

devkit treats each repository as the owner of its own agent environment. The
environment is described by the repository git-config: selected agent, ubuntu
packages, additional volumes, build customizations and lifecycle hooks. Shared
profiles are ordinary git-config include files, so a repository can inherit a
baseline environment and override only the parts that differ locally.

From that configuration devkit derives a project-image identity. A
tagged agent base contains fixed packages, agent dependencies, and the
selected agent. Compatible repositories using that agent share the base.
Each base has a `latest` tag and an agent-version tag. The project image
adds configured packages, optional services, and build-time
customizations.

If a matching project image already exists, it is reused. Otherwise
devkit builds it from the tagged agent base. Podman may reuse unchanged
intermediate layers within the project build. Changing project packages
or customizations therefore does not reinstall the agent.

At runtime devkit starts a named podman container for the repository. The
project tree is mounted at `/srv/<project-name>`, the selected agent
configuration directory is mounted from the host, and any configured volumes are
added. The image entrypoint runs container `start` hooks and then replaces
itself with the requested command: either the agent or the development shell.

If the named container is already running, `devkit shell` opens another session
inside it instead of creating a second container. This keeps long-running agent
sessions and interactive debugging in the same project environment.

## Requirements

Required utilities:

- `make`
- `git`
- `podman`
- `curl`

## Initial Setup

Initialize configuration:

```
$ devkit.sh init
```

## Usage

Run agent:

```
$ devkit.sh run
```

Open interactive shell. If the container is already running, a second session
will be opened in the container:

```
$ devkit.sh shell
```

Check available and current agent versions:

```
$ devkit.sh check
```

List devkit images:

```
$ devkit.sh list
```

Upgrade container image:

```
$ devkit.sh upgrade
```

An upgrade checks the latest agent release. If a compatible local agent
base already has that version, devkit reuses it without pulling Ubuntu.
If the project configuration and base also match an existing project
image, devkit reuses that image without rebuilding.

When no compatible current agent base exists, devkit pulls the latest
Ubuntu image and builds a new base. Both base and project builds reuse
cached layers. Base compatibility includes the devkit version, base
recipe, agent dependencies, and host UID:GID.

After a successful upgrade that built a new base, devkit removes
replaced project and base images only when unused. Older version-tagged
bases remain while other images or containers reference them. Cleanup
preserves cached parent layers and images with unrelated tags. Failed
upgrades do not perform cleanup.

Other repositories retain their existing project images until explicitly
upgraded. Their upgrades reuse the new shared base. Release lookup
errors abort the upgrade; devkit does not assume a local image is
current.

Remove images for current environment:

```
$ devkit.sh clean
```

Remove all devkit images:

```
$ devkit.sh clean-all
```

`clean` removes the current project image but retains the shared agent base.
`clean-all` removes project images and agent bases. Podman's untagged
intermediate build cache remains under podman cache management.

### Optional Sashiko review service

Sashiko is an agentic Linux kernel code review system. It uses
Linux-kernel-specific prompts and a dedicated protocol to review proposed
kernel changes. It can ingest patches from mailing lists or a local git
repository.

Enable it for a repository:

```
$ git config devkit.sashiko true
```

Start the service and open its CLI:

```
$ devkit.sh sashiko
```

`devkit.sh sashiko-daemon` starts the review daemon, `devkit.sh sashiko-kill`
stops it, and `devkit.sh sashiko-logs` shows its logs.

See [Documentation/sashiko.md](Documentation/sashiko.md) for the commands,
configuration parameters, persistent data, and service defaults.

### Optional Ollama service

Enable Ollama for a repository:

```
$ git config devkit.ollama true
```

Start the service if needed and execute the Ollama client:

```
$ devkit.sh ollama
```

See [Documentation/ollama.md](Documentation/ollama.md) for the commands,
requirements, configuration, and persistent data.

## Configuration

All configuration is stored in `git-config`.

Inspect configuration:

```
$ git config devkit.agent
$ git config --get-all devkit.packages
```

Example of configuration:

```ini
[devkit]
	agent = codex
	editor = /usr/bin/vim
	env-file = .env
	packages = git ripgrep
	packages = build-essential bc flex bison libelf-dev binutils-dev
	packages = libncurses-dev
```

Supported agents:

- [aider](https://aider.chat)
- [antigravity](https://antigravity.google/cli)
- [cecli](https://github.com/cecli-dev/cecli)
- [claude](https://claude.ai)
- [codex](https://github.com/openai/codex)
- [copilot](https://github.com/github/copilot-cli)
- [cursor](https://cursor.com/docs/agent/overview)
- [gemini](https://geminicli.com)
- [goose](https://github.com/aaif-goose/goose)
- [opencode](https://opencode.ai)
- [pi](https://pi.dev)
- [grok (unofficial)](https://grokcli.io)
- [vibe](https://docs.mistral.ai/mistral-vibe/terminal)
- [kimi](https://moonshotai.github.io/kimi-code/en/)

See [Documentation/Parameters.md](Documentation/Parameters.md) for the full
list of supported `devkit.*` parameters. These parameters are read from the
git-config of the project for which the agent is started.

### Shared profiles via git include

Git allows configuration reuse using `include.path`.

A profile usually defines the agent type and dependency packages. Profiles can
be shared between repositories using git configuration includes.

Example shared profile:

```ini
# ~/.config/devkit/basic-c.ini
[devkit]
    packages = gcc make gdb
    packages = clang-format
```

Include inside repository:

```
$ git config devkit.agent codex
$ git config include.path ~/.config/devkit/basic-c.ini
```

Benefits:

- single source of truth
- consistent tooling
- automatic project-image reuse and shared agent bases
- minimal per-repository setup

Local repository configuration may override included values.

An included profile is not a parent-image boundary. Projects using the
same agent share a tagged agent base. Projects that add different
package sets produce different project images while retaining that
common base. Devkit builds a base when a compatible one is unavailable;
`upgrade` also checks the latest agent release. Existing project images
retain their embedded base until rebuilt.

## License

GPL-2.0-or-later
