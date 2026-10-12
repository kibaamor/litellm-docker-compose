# LiteLLM Proxy with Docker Compose

Docker Compose setup for a local LiteLLM proxy backed by PostgreSQL.

Services:

- `litellm`: OpenAI-compatible proxy and admin UI
- `postgres`: database for usage, keys, and audit logs
- `litellm-init`: one-shot config assembly job

## Quick Start

Prerequisites:

- Docker with Compose v2 (`docker compose`)
- `curl` and `jq` for the test script and examples

Create your local environment file:

```bash
cp .env.example .env
```

Edit `.env` and set at least:

```dotenv
LITELLM_MASTER_KEY=<change-me>
EXAMPLE_PROVIDER_API_BASE=<provider-api-base>
EXAMPLE_PROVIDER_API_KEY=<provider-api-key>
```

The provider variable names above are examples. Use the exact names referenced by your private credential YAML.

`.env` is gitignored. Do not put real tokens, private endpoint names, or private model names in README files.

Start the stack:

```bash
docker compose up -d
```

Open the admin UI at <http://localhost:4000/ui>. The default username is `admin`; the password is `LITELLM_MASTER_KEY`.

Verify the proxy:

```bash
source .env
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq
```

Run the smoke test with one of your configured model aliases:

```bash
MODEL=<your-model-alias> ./test.sh
```

`test.sh` covers model listing, chat, streaming, and tool calls.

Stop the stack:

```bash
docker compose down
```

Remove persisted data as well:

```bash
docker compose down -v
```

## Configuration

LiteLLM config is assembled at startup from `litellm_config/`:

```text
litellm_config/
├── base.yaml
├── credentials/
│   └── <credential-fragment>.yaml
└── models/
    └── <model-fragment>.yaml
```

`litellm-init` writes a generated include file into the `litellm-config` Docker volume:

```yaml
include:
  - /source/base.yaml
  - /source/credentials/<credential-fragment>.yaml
  - /source/models/<model-fragment>.yaml
```

Every `*.yaml` under `credentials/` and `models/` is included automatically, so new private credential or model fragments do not need a central registry edit.

Credential files should reference environment variables rather than inline secrets:

```yaml
credential_list:
- credential_name: example-credential
  credential_values:
    api_key: os.environ/EXAMPLE_PROVIDER_API_KEY
    api_base: os.environ/EXAMPLE_PROVIDER_API_BASE
  credential_info:
    custom_llm_provider: example-provider
```

Model files should reference the credential by name:

```yaml
model_list:
- model_name: example-model-alias
  litellm_params:
    model: example-provider/example-model-id
    litellm_credential_name: example-credential
```

`base.yaml` enables `store_model_in_db`, so models can also be managed through the LiteLLM admin UI or database.

## Environment Variables

Defined in `.env.example`:

| Variable | Default | Description |
| --- | --- | --- |
| `MAX_LOG_FILE_SIZE` | `10m` | Docker log file size limit |
| `MAX_LOG_FILE_COUNT` | `3` | Docker log file count |
| `POSTGRES_VERSION` | `18.6` | PostgreSQL image tag |
| `POSTGRES_DB` | `litellm` | Database name |
| `POSTGRES_USER` | `litellm` | Database user |
| `POSTGRES_PASSWORD` | `pgpass4litellm` | Database password |
| `LITELLM_VERSION` | `latest` | LiteLLM image tag |
| `LITELLM_BIND_ADDRESS` | `127.0.0.1` | Host interface for the proxy port |
| `LITELLM_PORT` | `4000` | Host port mapped to container port 4000 |
| `LITELLM_MASTER_KEY` | `admin` | Proxy and admin UI authentication key |
| `LITELLM_LOG` | `INFO` | LiteLLM log level |

Provider-specific variables are read from `.env` by your private credential YAML files.

## Common Commands

```bash
# View status
docker compose ps

# View logs
docker compose logs -f
docker compose logs -f litellm
docker compose logs litellm-init

# List models
source .env
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq

# Chat completion
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<your-model-alias>",
    "messages": [{"role": "user", "content": "Hello"}]
  }' | jq

# Connect to PostgreSQL
docker compose exec postgres psql -U litellm -d litellm
```

If `LITELLM_BIND_ADDRESS` is not `127.0.0.1`, use the reachable host address instead of `localhost`. Do not use `0.0.0.0` as a client address.

## Persistence

Docker named volumes:

- `postgres-data`: persistent database data
- `litellm-config`: generated LiteLLM config, rebuilt on startup

`docker compose down -v` deletes both volumes.

## Security Notes

- Treat `litellm_config/credentials/*.yaml` and `litellm_config/models/*.yaml` as confidential.
- Do not copy private credential names, endpoint names, model aliases, model IDs, or provider-specific environment variable names into public docs.
- Change `LITELLM_MASTER_KEY` and `POSTGRES_PASSWORD` before using this outside local testing.
- Keep `LITELLM_BIND_ADDRESS=127.0.0.1` unless the host network is protected.
- If exposing the proxy on a LAN or `0.0.0.0`, use firewall rules or another trusted network boundary.
- Do not commit `.env` or real provider tokens.
- Avoid `@`, `:`, and `/` in `POSTGRES_PASSWORD`; it is embedded in `DATABASE_URL`.
- Pin `LITELLM_VERSION` and `POSTGRES_VERSION` for repeatable deployments.

## Troubleshooting

Proxy startup:

```bash
docker compose logs litellm-init
docker compose logs litellm
docker compose logs postgres
```

Model requests:

```bash
source .env
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq
```

Checks:

- `401`: verify `LITELLM_MASTER_KEY` and the provider variables referenced by your private credential YAML.
- Missing model: check your private files under `litellm_config/models/`, then recreate the init and proxy services with `docker compose up -d --force-recreate litellm-init litellm`.
- Database auth errors after changing `POSTGRES_*`: update the existing database user or recreate volumes with `docker compose down -v`.

## Validation

Before committing changes:

```bash
docker compose config --quiet
MODEL=<your-model-alias> ./test.sh
```

## License

[MIT License](LICENSE)
