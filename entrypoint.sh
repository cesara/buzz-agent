#!/bin/bash
set -euo pipefail

# ── Runtime ──────────────────────────────────────────────────────────────────
#
# Which coding agent buzz-acp spawns. The image carries two, and they differ in
# every part of the setup below — how they are authenticated, and where their
# MCP servers are configured — so the rest of this script branches on it.
#
# The command is the single source of truth; `runtime` in the snapshot and
# BUZZ_AGENT_RUNTIME are shorthands for it, and an explicit
# BUZZ_ACP_AGENT_COMMAND beats both.
runtime_command_for() {
    case "$1" in
        claude)   echo claude-agent-acp ;;
        opencode) echo opencode ;;
        *)        echo "$1" ;;   # anything else: a command, passed through
    esac
}

# Reverse direction: classify whatever command we ended up with. `other` means
# "a runtime this script has no opinion about" — no credential check, no MCP
# config written, and buzz-acp left to talk to it over plain ACP.
runtime_kind_for() {
    case "$(basename "$1")" in
        claude-agent-acp|claude-code-acp|claude-code|claude) echo claude ;;
        opencode)                                            echo opencode ;;
        kimi)                                                echo kimi ;;
        *)                                                   echo other ;;
    esac
}

# Claude Code: auth comes from CLAUDE_CODE_OAUTH_TOKEN, minted on a machine with
# a browser:
#
#   claude setup-token
#
# That is the supported path for a headless subscription login — no copying of
# ~/.claude onto the server, no SSH-forwarded OAuth callback.
check_claude_auth() {
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
        echo "ERROR: no Claude credentials." >&2
        echo "Set CLAUDE_CODE_OAUTH_TOKEN (from 'claude setup-token') or ANTHROPIC_API_KEY." >&2
        exit 1
    fi

    # Fail fast and loudly rather than looping on a bad token.
    if ! claude auth status >/dev/null 2>&1; then
        echo "WARNING: 'claude auth status' did not report an authenticated session." >&2
        echo "Continuing anyway — the adapter may still authenticate via the token." >&2
    fi
}

# opencode: a provider API key in the environment *is* the login. opencode loads
# every models.dev provider whose declared env key is present (provider.ts,
# `source: "env"`), so OPENCODE_API_KEY alone is enough — no `opencode auth
# login`, and no auth.json to persist on a volume.
#
# Hence the shape of this check: any *_API_KEY rather than a hardcoded list, so
# an agent on a different provider needs no change here.
check_opencode_auth() {
    local v
    for v in $(compgen -v); do
        [[ "$v" == *_API_KEY && -n "${!v}" ]] && return 0
    done
    echo "ERROR: no provider API key for opencode." >&2
    echo "Set the key your provider declares on models.dev — e.g. OPENCODE_API_KEY." >&2
    exit 1
}

# kimi: auth is OAuth state under $KIMI_CODE_HOME (on the work volume, per the
# compose), written once by an interactive `kimi login` — there is no env-var
# credential to check here. What this script *can* do is warn when the login
# has never happened (otherwise the boot looks healthy and only the first
# session/new fails with "Authentication required"), and pin two settings on
# the persisted config.
#
# Why the permission mode has to be set here: buzz-acp's
# permission_mode=bypassPermissions never reaches kimi. Kimi's ACP modes are
# default/plan/auto/yolo — there is no bypassPermissions — and buzz only
# applies the mode when the session/new response advertises it, so sessions
# run in kimi's "default" (manual approvals) with buzz auto-approving every
# tool call over the wire. Writing yolo into config.toml makes that approval
# internal instead: same effective behavior, without the per-tool round trip.
#
# default_model is *enforced*, not just defaulted: buzz-acp cannot switch
# models on kimi over ACP — kimi's configOptions carry `id`, buzz matches
# `configId`, the same mismatch the README documents for opencode — so the
# persisted default IS the model every session runs, and the snapshot's model
# (BUZZ_ACP_MODEL, already exported by apply_snapshot at this point) is the
# source of truth.
setup_kimi() {
    local home="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
    local cfg="$home/config.toml"
    if [[ ! -f "$cfg" ]]; then
        echo "WARNING: no kimi config at $cfg — the agent is not logged in." >&2
        echo "Run 'docker exec -it <container> kimi login' once; credentials" >&2
        echo "persist on the work volume. Until then every session/new fails" >&2
        echo "with 'Authentication required'." >&2
        return 0
    fi

    local model="${BUZZ_ACP_MODEL:-kimi-code/k3}"
    if grep -q '^default_model' "$cfg"; then
        sed -i "s|^default_model *=.*|default_model = \"${model}\"|" "$cfg"
        echo "kimi: default_model = $model in $cfg"
    fi

    # Prepend whatever top-level keys are missing — they must precede the
    # first [table]. An existing default_permission_mode wins: it is
    # someone's explicit choice on a persisted file, not a default to be
    # corrected.
    local -a missing=()
    grep -q '^default_model' "$cfg" || missing+=("default_model = \"${model}\"")
    grep -q '^default_permission_mode' "$cfg" || missing+=('default_permission_mode = "yolo"')
    ((${#missing[@]} == 0)) && return 0

    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "${missing[@]}" | cat - "$cfg" > "$tmp" && cat "$tmp" > "$cfg"
    rm -f "$tmp"
    echo "kimi: set ${missing[*]} in $cfg"
}

# Register MCP servers on every boot. ~/.claude.json lives in the container
# filesystem, not a volume, so it is lost whenever the container is recreated;
# rebuilding it here keeps the config declarative and the token out of the image.
#
# buzz-acp cannot carry these itself — its McpServer struct is stdio-only
# (name/command/args/env, no url or type) and it passes at most one server, so
# HTTP MCPs have to be configured on the agent's own side instead.
#
# --scope user is load-bearing. The default scope is "local", which files the
# server under the *current directory* in ~/.claude.json. This script runs from
# the image WORKDIR, buzz-acp runs its sessions in /var/lib/buzz/work, and a
# server registered under one directory is invisible from the other — the agent
# starts with no tools while `claude mcp list`, run from here, reports it
# connected. User scope applies everywhere and sidesteps the question.
#
# The remove is what makes this idempotent: `restart: unless-stopped` restarts
# the same container, so ~/.claude.json survives and a second `add` of the same
# name fails. Without it every restart logged a registration warning that meant
# nothing, which is precisely when a warning that means something gets missed.
register_mcp() {
    local name="$1"; shift
    claude mcp remove --scope user "$name" >/dev/null 2>&1 || true
    claude mcp add --scope user "$name" "$@" >/dev/null 2>&1
}

register_http_mcp() {
    local name="$1" url="$2" token="$3"
    [[ -z "$name" || -z "$url" || -z "$token" ]] && return 0
    # Accept a bare token as well as a full header value.
    [[ "$token" != *" "* ]] && token="Bearer ${token}"
    if register_mcp "$name" --transport http "$url" \
            --header "Authorization: ${token}"; then
        echo "registered MCP server: ${name} -> ${url}"
    else
        echo "WARNING: failed to register MCP server ${name}" >&2
    fi
}

# stdio MCP servers. The spawned process inherits this container's environment,
# so credentials are plain env vars rather than per-server --env flags.
register_stdio_mcp() {
    local name="$1" cmd="$2"
    [[ -z "$name" || -z "$cmd" ]] && return 0
    # shellcheck disable=SC2086 — cmd is a command plus args, split intentionally.
    if register_mcp "$name" -- $cmd; then
        echo "registered MCP server (stdio): ${name} -> ${cmd}"
    else
        echo "WARNING: failed to register stdio MCP server ${name}" >&2
    fi
}

# Indexed MCP slots, so one image serves agents with different toolsets and no
# MCP is special-cased by name here:
#   MCP1_NAME=executor MCP1_URL=https://... MCP1_TOKEN=...
#   MCP2_NAME=other    MCP2_URL=https://... MCP2_TOKEN=...
register_claude_mcps() {
    local i n u t c
    for i in 1 2 3 4 5; do
        n="MCP${i}_NAME"; u="MCP${i}_URL"; t="MCP${i}_TOKEN"
        register_http_mcp "${!n:-}" "${!u:-}" "${!t:-}"
    done
    for i in 1 2 3; do
        n="MCPS${i}_NAME"; c="MCPS${i}_CMD"
        register_stdio_mcp "${!n:-}" "${!c:-}"
    done
}

# The same slots, for opencode. It has no `mcp add` subcommand — MCP servers are
# declared in its config file — so this writes the whole file rather than
# appending to it. Same reasoning as the Claude path: the config lives in the
# container filesystem, not on a volume, so it is rebuilt from the environment on
# every boot and no token is baked into the image.
#
# A `local` server inherits this container's environment, so its credentials are
# plain env vars here too and the `environment` key stays unused.
#
# The model is written here too, rather than left to buzz-acp. buzz-acp switches
# models through a `session/new` configOption keyed on `configId`, and opencode
# names that field `id` — so the switch silently never matches and the agent
# keeps whatever it defaulted to, which is a Zen model rather than the one the
# snapshot asked for. Set through opencode's own config, it lands.
write_opencode_config() {
    local cfg="${HOME}/.config/opencode/opencode.json"
    mkdir -p "$(dirname "$cfg")"
    node -e '
        const fs = require("fs");
        const [out, model] = process.argv.slice(1);
        const mcp = {};
        for (let i = 1; i <= 5; i++) {
            const name = process.env[`MCP${i}_NAME`];
            const url = process.env[`MCP${i}_URL`];
            let token = process.env[`MCP${i}_TOKEN`];
            if (!name || !url || !token) continue;
            // Accept a bare token as well as a full header value.
            if (!token.includes(" ")) token = `Bearer ${token}`;
            mcp[name] = { type: "remote", url, enabled: true, headers: { Authorization: token } };
        }
        for (let i = 1; i <= 3; i++) {
            const name = process.env[`MCPS${i}_NAME`];
            const cmd = process.env[`MCPS${i}_CMD`];
            if (!name || !cmd) continue;
            mcp[name] = { type: "local", command: cmd.trim().split(/\s+/), enabled: true };
        }
        const config = { $schema: "https://opencode.ai/config.json", mcp };
        if (model) config.model = model;
        fs.writeFileSync(out, JSON.stringify(config, null, 2) + "\n");
        const names = Object.keys(mcp);
        console.log(`wrote ${out}: model=${model || "opencode default"}, ` +
            `${names.length ? names.join(", ") : "no MCP servers"}`);
    ' "$cfg" "$1"
}

# Agent snapshot — Buzz's own portable agent definition (`.agent.json`, the
# format Buzz Desktop exports and imports). buzz-acp does not read it, so this
# translates the parts that map onto its flags.
#
# Keeping the persona here rather than in an environment variable means it is
# reviewable in git, and the same file can be imported by Buzz Desktop or
# published to a registry. Explicit environment always wins, so a resource can
# override any single field without editing the snapshot.
apply_snapshot() {
    local file="$1"
    [[ -z "$file" ]] && return 0
    if [[ ! -r "$file" ]]; then
        echo "ERROR: BUZZ_AGENT_SNAPSHOT=$file is not readable." >&2
        exit 1
    fi

    local dir
    dir="$(mktemp -d)"

    # node is in the base image, so parsing JSON costs no extra dependency.
    # The prompt goes to a file rather than a variable: it is multi-line, and
    # BUZZ_ACP_SYSTEM_PROMPT_FILE exists precisely for this.
    #
    # The base template (identity + the shared behavior contract) is always
    # prepended, with {{NAME}} filled in from the same name the profile
    # publishes — one source of truth, so the prompt and the displayed name
    # can never drift apart. A snapshot's own systemPrompt is additional,
    # persona-specific material layered on top, not a replacement for it.
    if ! node -e '
        const fs = require("fs");
        const [src, out, basePath] = process.argv.slice(1);
        const s = JSON.parse(fs.readFileSync(src, "utf8"));
        if (s.format !== "buzz-agent-snapshot") {
            throw new Error(`not an agent snapshot: format=${JSON.stringify(s.format)}`);
        }
        if (s.version !== 1) {
            throw new Error(`unsupported snapshot version ${s.version}`);
        }
        const d = s.definition || {};
        const p = s.profile || {};
        const name = p.displayName || d.name || "This agent";
        const base = fs.readFileSync(basePath, "utf8").replace(/\{\{NAME\}\}/g, name);
        const prompt = d.systemPrompt ? `${base}\n\n${d.systemPrompt}` : base;
        fs.writeFileSync(`${out}/system-prompt.md`, prompt);
        // Profile fields go to their own file: they are published with the
        // buzz CLI, not passed to buzz-acp.
        fs.writeFileSync(`${out}/profile.json`, JSON.stringify({
            name,
            about: p.about || null,
            avatar: p.avatarUrl || null,
            nip05: p.nip05 || null,
        }));
        const kv = [];
        if (d.runtime) kv.push(`runtime=${d.runtime}`);
        if (d.model) kv.push(`model=${d.model}`);
        if (d.respondTo) kv.push(`respond_to=${d.respondTo}`);
        if (d.parallelism) kv.push(`parallelism=${d.parallelism}`);
        if (Array.isArray(d.respondToAllowlist) && d.respondToAllowlist.length) {
            kv.push(`allowlist=${d.respondToAllowlist.join(",")}`);
        }
        if (d.idleTimeoutSeconds) kv.push(`idle_timeout=${d.idleTimeoutSeconds}`);
        if (d.maxTurnDurationSeconds) kv.push(`max_turn=${d.maxTurnDurationSeconds}`);
        fs.writeFileSync(`${out}/vars`, kv.join("\n") + "\n");
        console.log(`snapshot: ${name}${d.systemPrompt ? " (with system prompt)" : " (base prompt only)"}`);
    ' "$file" "$dir" "/etc/buzz/base-system-prompt.md"; then
        echo "ERROR: could not apply snapshot $file" >&2
        exit 1
    fi

    if [[ -f "$dir/system-prompt.md" ]]; then
        export BUZZ_ACP_SYSTEM_PROMPT_FILE="${BUZZ_ACP_SYSTEM_PROMPT_FILE:-$dir/system-prompt.md}"
    fi

    local k v
    while IFS='=' read -r k v; do
        [[ -z "$k" ]] && continue
        case "$k" in
            runtime)      export BUZZ_AGENT_RUNTIME="${BUZZ_AGENT_RUNTIME:-$v}" ;;
            model)        export BUZZ_ACP_MODEL="${BUZZ_ACP_MODEL:-$v}" ;;
            respond_to)   export BUZZ_ACP_RESPOND_TO="${BUZZ_ACP_RESPOND_TO:-$v}" ;;
            parallelism)  export BUZZ_ACP_AGENTS="${BUZZ_ACP_AGENTS:-$v}" ;;
            allowlist)    export BUZZ_ACP_RESPOND_TO_ALLOWLIST="${BUZZ_ACP_RESPOND_TO_ALLOWLIST:-$v}" ;;
            idle_timeout) export BUZZ_ACP_IDLE_TIMEOUT="${BUZZ_ACP_IDLE_TIMEOUT:-$v}" ;;
            max_turn)     export BUZZ_ACP_MAX_TURN_DURATION="${BUZZ_ACP_MAX_TURN_DURATION:-$v}" ;;
        esac
    done < "$dir/vars"

    SNAPSHOT_PROFILE="$dir/profile.json"
}

# Publish the snapshot's profile as this identity's kind:0.
#
# Nothing else will: buzz-acp only ever *reads* kind:0 (to identify authors and
# check NIP-OA tags), and Nostr profiles are self-asserted — a relay can accept
# or reject the write but cannot assign a name. So an agent with a fresh key
# appears nameless until it publishes for itself.
#
# kind:0 is replaceable, so this is idempotent and runs every boot: editing the
# snapshot and redeploying is how you rename an agent. Never fatal — a relay
# with BUZZ_REQUIRE_RELAY_MEMBERSHIP will 403 this until the agent is added as
# a member, and being nameless is no reason to refuse to start.
publish_profile() {
    local file="${1:-}"
    [[ -z "$file" || ! -r "$file" ]] && return 0
    [[ "${BUZZ_AGENT_PUBLISH_PROFILE:-true}" != "true" ]] && return 0

    # NUL-separated via a file, so an `about` containing spaces arrives as a
    # single argument instead of being re-split by the shell.
    local argfile="${file}.args"
    if ! node -e '
        const fs = require("fs");
        const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (!p.name) process.exit(2);
        const out = [];
        for (const [flag, key] of [["--name","name"],["--about","about"],["--avatar","avatar"],["--nip05","nip05"]]) {
            if (p[key]) out.push(flag, p[key]);
        }
        // Trailing NUL too: `read -d ""` needs each field terminated, not
        // merely separated, or it drops the last one.
        fs.writeFileSync(process.argv[2], out.map((x) => x + "\0").join(""));
    ' "$file" "$argfile"; then
        return 0   # exit 2 — no name in the snapshot, nothing to publish
    fi

    local -a argv=()
    while IFS= read -r -d "" a; do argv+=("$a"); done < "$argfile"

    if buzz users set-profile "${argv[@]}" >/dev/null 2>&1; then
        echo "published profile: ${argv[1]}"
    else
        echo "WARNING: could not publish profile (relay membership required?)" >&2
    fi
}

# First-boot introduction.
#
# A headless agent with a generated key is a stranger to the community. It has
# no way in on its own: BUZZ_ACP_CHANNELS only filters what it subscribes to —
# it cannot create the kind:39002 membership that makes a channel visible — and
# there is no desktop session to attach it to one. So on first boot it joins
# whatever channels it was told about and opens a DM to its owner, which always
# works and leaves somewhere to talk.
#
# Once only, guarded by a marker on the work volume. Not because `buzz dms
# open` would create duplicate threads — the relay dedupes on a participant-set
# hash and hands back the existing channel (buzz-db/src/dm.rs:377) — but
# because that same call *unhides* the DM, and re-greeting the owner on every
# restart would be obnoxious.
bootstrap() {
    local marker="/var/lib/buzz/work/.bootstrap-done"
    [[ "${BUZZ_AGENT_BOOTSTRAP:-true}" != "true" ]] && return 0
    [[ -f "$marker" ]] && return 0
    [[ -z "${BUZZ_ACP_AGENT_OWNER:-}" ]] && return 0

    # Via a local with a default: bash 5 treats ${UNSET//,/ } as an unbound
    # variable under `set -u` and aborts, where bash 3.2 quietly yields empty.
    local channels="${BUZZ_ACP_CHANNELS:-}" ch
    for ch in ${channels//,/ }; do
        [[ -z "$ch" ]] && continue
        if buzz channels join --channel "$ch" >/dev/null 2>&1; then
            echo "joined channel ${ch}"
        else
            echo "WARNING: could not join channel ${ch} (invite-only, or not a member yet)" >&2
        fi
    done

    local out dm
    if ! out=$(buzz dms open --pubkey "$BUZZ_ACP_AGENT_OWNER" 2>/dev/null); then
        echo "WARNING: could not open owner DM — will retry next boot" >&2
        return 0
    fi
    dm=$(node -e '
        const v = JSON.parse(process.argv[1]);
        if (!v.dm_id) process.exit(1);
        process.stdout.write(v.dm_id);
    ' "$out" 2>/dev/null) || { echo "WARNING: no dm_id in response — will retry next boot" >&2; return 0; }

    local hello="${BUZZ_AGENT_HELLO:-}"
    if [[ -z "$hello" && -r "${SNAPSHOT_PROFILE:-/nonexistent}" ]]; then
        hello=$(node -e '
            const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
            process.stdout.write(`${p.name || "This agent"} is online.` + (p.about ? ` ${p.about}` : ""));
        ' "$SNAPSHOT_PROFILE" 2>/dev/null) || hello=""
    fi

    if [[ -n "$hello" ]] && buzz messages send --channel "$dm" --content "$hello" >/dev/null 2>&1; then
        echo "opened owner DM ${dm} and said hello"
    else
        echo "opened owner DM ${dm}"
    fi

    # Only mark done once the DM exists, so a relay that was not ready yet
    # gets another attempt rather than the agent silently never introducing itself.
    touch "$marker" 2>/dev/null || true
}

# A URL wins over a path: it is how you change a persona without rebuilding.
snapshot_path="${BUZZ_AGENT_SNAPSHOT:-}"
if [[ -n "${BUZZ_AGENT_SNAPSHOT_URL:-}" ]]; then
    snapshot_path=/tmp/agent-snapshot.json
    if ! curl -fsSL --max-time 20 "$BUZZ_AGENT_SNAPSHOT_URL" -o "$snapshot_path"; then
        echo "ERROR: could not fetch BUZZ_AGENT_SNAPSHOT_URL=${BUZZ_AGENT_SNAPSHOT_URL}" >&2
        exit 1
    fi
    echo "fetched snapshot from ${BUZZ_AGENT_SNAPSHOT_URL}"
fi

# Before anything runtime-specific: the snapshot is what names the runtime.
apply_snapshot "$snapshot_path"

export BUZZ_ACP_AGENT_COMMAND="${BUZZ_ACP_AGENT_COMMAND:-$(runtime_command_for "${BUZZ_AGENT_RUNTIME:-claude}")}"
runtime="$(runtime_kind_for "$BUZZ_ACP_AGENT_COMMAND")"
echo "runtime: ${runtime} (${BUZZ_ACP_AGENT_COMMAND})"

case "$runtime" in
    claude)
        check_claude_auth
        register_claude_mcps
        ;;
    opencode)
        check_opencode_auth
        # opencode model ids are provider-qualified — `opencode-go/kimi-k2.7-code`,
        # not `kimi`. A bare name is dropped rather than guessed at: the agent
        # then runs on opencode's own default, which is loud in the log and
        # recoverable, where a wrong-but-plausible guess would not be.
        oc_model="${BUZZ_ACP_MODEL:-}"
        if [[ -n "$oc_model" && "$oc_model" != */* ]]; then
            echo "WARNING: model '${oc_model}' is not an opencode model id — ignoring it." >&2
            echo "Use provider/model, e.g. opencode-go/kimi-k2.7-code." >&2
            oc_model=""
        fi
        if [[ -z "$oc_model" ]]; then
            echo "WARNING: no model set for opencode. It falls back to a default on" >&2
            echo "its own hosted Zen provider — not the model you meant, and not" >&2
            echo "necessarily one your key covers. Set the snapshot's model or" >&2
            echo "BUZZ_ACP_MODEL to provider/model." >&2
        fi
        write_opencode_config "$oc_model"
        ;;
    kimi)
        setup_kimi
        ;;
esac

publish_profile "${SNAPSHOT_PROFILE:-}"
bootstrap

# buzz-acp's own default is EnvFilter::new("buzz_acp=info"), which matches on the
# target — and its most useful lines set an explicit one: `pool::prompt` carries
# "turn complete … end_turn", "turn refused" and both turn-timeout warnings,
# with `pool::session`, `engram::core` and `observer` doing the same elsewhere.
# None of those begin with "buzz_acp", so the stock default discards every one
# of them: a healthy container falls silent after "presence set to online", and
# a turn that ran and then said nothing is indistinguishable from a message that
# never arrived.
#
# So name the targets. Left at info, which is where the outcome lines are —
# `acp::wire` logs the raw ACP JSON of every message but does so at debug, so
# the protocol dump stays opt-in. RUST_LOG on the resource overrides all of it.
export RUST_LOG="${RUST_LOG:-buzz_acp=info,pool=info,acp=info,engram=info,observer=info,canvas=info}"

# Stock buzz-acp only subscribes to stream kinds (9, 46010, 40007). Forum posts
# and comments are 45001/45003 — without them an @mention in Coding is invisible.
# Mention filter stays on: forum composers emit `p` tags for @mentions, so we
# do not need BUZZ_ACP_NO_MENTION_FILTER (which would wake the agent on every
# stream message). Override with BUZZ_ACP_KINDS on the resource if needed.
export BUZZ_ACP_KINDS="${BUZZ_ACP_KINDS:-9,46010,40007,45001,45002,45003}"

# buzz-acp's own default is BUZZ_ACP_RELAY_OBSERVER=false — the flag exists
# because a plain CLI invocation has no viewer for the telemetry, so publishing
# it would just be encrypted writes nobody reads. Desktop flips it to `true`
# unconditionally for every agent it spawns itself (managed_agents/runtime.rs),
# which is exactly why a Desktop-launched agent shows live activity — thoughts,
# tool calls, diffs, turn lifecycle — while an agent deployed by this repo,
# never having had the flag set, stays invisible to that same feed even though
# BUZZ_ACP_AGENT_OWNER already makes it eligible. A persistent agent's whole
# point is to be watched, so default this on rather than making every resource
# remember the flag; override with BUZZ_ACP_RELAY_OBSERVER=false to opt out.
export BUZZ_ACP_RELAY_OBSERVER="${BUZZ_ACP_RELAY_OBSERVER:-true}"

exec buzz-acp "$@"
