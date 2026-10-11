# OpenAI

OpenAI Realtime is reached over SIP. Vox Squad dials the project SIP URI.
OpenAI posts `realtime.call.incoming` to Kazoo, and Vox Squad accepts the
session with the callflow prompt.

## 1. Callflow configuration

Put these fields under `data.openai`. `api_key`, `project_id`, `prompt`, and
`webhook_secret` are required.

```json
{
  "module": "voxsquad",
  "data": {
    "mode": "bridge",
    "provider": "openai",
    "openai": {
      "api_key": "sk-...",
      "project_id": "proj_...",
      "prompt": "You are a helpful phone agent.",
      "region": "us",
      "webhook_secret": "whsec_..."
    }
  }
}
```

| Field | Required | Description |
| ----- | :------: | ----------- |
| `api_key` | yes | Bearer token used to accept the realtime call. |
| `project_id` | yes | OpenAI project id. Used as the SIP user. |
| `prompt` | yes | Instructions sent when the session is accepted. |
| `region` | no | `us` or `eu`. Default `us`. |
| `webhook_secret` | yes | Project webhook signing secret. Must start with `whsec_`. |

A secret that does not decode ends the action with `invalid_config`.

`region` selects the host Vox Squad dials:

| Region | SIP URI |
| ------ | ------- |
| `us` | `sip:{project_id}@sip.api.openai.com;transport=tls` |
| `eu` | `sip:{project_id}@sip-eu.api.openai.com;transport=tls` |

The outbound leg sets the SIP header `X-VSQ-Call-ID` to the Kazoo call id.
That header is how the webhook is matched back to the call.

After the webhook signature matches, Vox Squad accepts the session with model
`gpt-realtime` and `prompt` as the instructions:

```text
POST https://api.openai.com/v1/realtime/calls/{call_id}/accept
Authorization: Bearer {api_key}
```

## 2. OpenAI Platform account

Create the project values in [platform.openai.com](https://platform.openai.com),
then copy them into the callflow fields above.

1. Open the project, or create one. Realtime SIP must be enabled for it.
2. In **Project settings**, **General**, copy the project id (`proj_...`) into
   `project_id`.
3. Create a secret API key in that project and put it in `api_key`.
4. In **Project settings**, **Webhooks**, create a webhook:
   - URL: `https://{crossbar}/v2/voxsquad/openai`
   - Event: `realtime.call.incoming`
   - Copy the signing secret (`whsec_...`) into `webhook_secret`. The secret
     is shown once, when the webhook is created.

The URL must be HTTPS and reachable from the internet. The path takes an
unauthenticated POST. Only `realtime.call.incoming` is forwarded to the call.
Any other event type is acknowledged and ignored.

OpenAI signs each delivery. The signature is a Standard Webhooks HMAC-SHA256
over `{webhook-id}.{webhook-timestamp}.{raw body}`, using the base64 key from
`webhook_secret`. A second webhook for a call that is already accepted is
ignored.

For a project in the EU, set the callflow `region` to `eu`.
