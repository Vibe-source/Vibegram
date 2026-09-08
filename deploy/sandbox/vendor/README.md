# Sandbox vendor drop

Binaries baked into `vibe-sandbox` that are not on apt. Kept out of git — the Dockerfile
installs whatever it finds here and skips silently when the directory is empty.

| File | What | Where it comes from |
|---|---|---|
| `agix-linux-x86_64.tar.gz` | `agix` code-intelligence CLI, `linux-x86_64`, tar with a single `agix` binary | `dist/agix-<version>-linux-x86_64-*.tar.gz` from the agix tree |

Refresh: copy the newer tarball over the same name and rebuild the image. Nothing else
references the version, so a stale copy only means the agent runs an older `agix`.
