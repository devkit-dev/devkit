# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026  Alexey Gladkov <gladkov.alexey@gmail.com>

HOMEURL = https://opencode.ai/v2/docs/
INST    = scr
LINK    = https://opencode.ai/v2/install
BIN     = opencode
WRITABLE_DIRS = .config/opencode .local/share/opencode .local/state/opencode
READABLE_DIRS =
SCR_ENV =

ENVS += OPENCODE_BROWSER_AGENT_SOCKET=/tmp/opencode.sock

RELEASE_URL = https://github.com/anomalyco/opencode/tags.atom
RELEASE_CMD = $(CURL) -fsSL $(RELEASE_URL) | grep -m1 -oP '<title>\Kv[^<]+'
