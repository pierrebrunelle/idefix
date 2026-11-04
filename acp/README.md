# idefix-acp

Use idefix inside Zed (or any [ACP](https://agentclientprotocol.com) client:
Zed, JetBrains IDEs) as an external agent.

`idefix-acp.py` is a stdlib-only Python shim. It speaks newline-delimited
JSON-RPC 2.0 on stdio, maps each ACP session to a per-session idefix state
dir, and runs each prompt turn as `idefix --events [--continue]`. Tool calls
stream to the editor as they run; cancel kills the idefix process.

## Zed

```json
// ~/.config/zed/settings.json
{
  "agent_servers": {
    "idefix": {
      "command": "/path/to/idefix/acp/idefix-acp.py",
      "args": [],
      "env": {
        "IDEFIX_BASE_URL": "http://127.0.0.1:18099/v1",
        "IDEFIX_MODEL": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        "IDEFIX_BIN": "/path/to/idefix/idefix"
      }
    }
  }
}
```

Then pick "idefix" in the Agent Panel's new-thread menu.

## Notes

- The binary stays unchanged; the shim is the entire integration surface.
- Multi-turn context survives via idefix's own journal (`--continue`), not
  via the shim holding state.
- No permission prompts in v1: idefix's bounds (request/wall/output caps,
  optional `--sandbox`) are the safety contract. Add flags to the `args`
  array to enforce more (e.g. `"--sandbox"`, `"--max-requests"`, "20").
- `session/load` is not implemented; new threads start fresh.
