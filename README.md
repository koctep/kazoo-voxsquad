# Vox Squad

## 0. What it is

Vox Squad puts an AI voicebot on a Kazoo call. A callflow action hands the
caller to a provider, which talks to the caller and then returns the call to
the flow.

Supported providers:

- [OpenAI](doc/providers/OpenAI.md) Realtime over SIP

## 1. Versions

Built for openkazoo 4.4. It should be compatible with Kazoo 5.

## 2. Install

Add Vox Squad in `rebar.config` of the Kazoo tree. Two entries are required.

In `{deps, [...]}`:

```erlang
{voxsquad, {git, "https://github.com/koctep/kazoo-voxsquad.git", {branch, "master"}}}
```

In the relx `applications` list, in the Applications section:

```erlang
{voxsquad, none}
```

`none` packs the beams into the release and leaves the application stopped.
Kazoo starts it with the command in [Start](#3-start). Do not give it a boot
type such as `permanent`.

Rebuild from the repository root and install the release the same way as the
rest of the node:

```sh
make build-release
```

## 3. Start

### Application

To start the application:

```sh
sup kazoo_apps_maintenance start voxsquad
```

On start the application loads `callflows.voxsquad` into the schema database.

### Crossbar module

To start the Crossbar module:

```sh
sup crossbar_maintenance start_module cb_voxsquad
```

That binds `POST /v2/voxsquad/openai`, which providers use for webhooks. The
callflow action `cf_voxsquad` needs no separate start: Callflow loads it when
a flow reaches the action.

## 4. Callflow

Add an action with module `voxsquad`. `mode` and `provider` are required.
The object under the provider name is documented per provider.

```json
{
  "module": "voxsquad",
  "data": {
    "mode": "bridge",
    "provider": "{{provider-name}}",
    "{{provider-name}}": { ... }
  }
}
```

| Field | Required | Description |
| ----- | :------: | ----------- |
| `mode` | yes | `bridge` or `vox-in-the-middle`. Default `bridge`. |
| `provider` | yes | Provider name. See [Providers](#5-providers). |
| `skip_module` | no | When `true`, this action is skipped. |

`bridge` keeps the call on this action until the voicebot leg ends, then the
flow continues. `vox-in-the-middle` returns `ready` at once and continues the
flow without placing the provider bridge.

## 5. Providers

| Provider | Settings |
| -------- | -------- |
| `openai` | [doc/providers/OpenAI.md](doc/providers/OpenAI.md) |
