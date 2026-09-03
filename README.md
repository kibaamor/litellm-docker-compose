# LiteLLM Proxy with Docker Compose

A LiteLLM proxy deployment using Docker Compose:

- **LiteLLM proxy** (`litellm`): OpenAI-compatible API gateway with a web admin UI
- **PostgreSQL** (`postgres`): database for usage, virtual keys, and audit logs
- **Config bootstrap** (`litellm-init`): one-shot job that merges config fragments into the final LiteLLM config

## Features

- ✅ OpenAI-compatible proxy API on port 4000 with bearer token authentication
- ✅ PostgreSQL backend for usage tracking, virtual keys, and audit logs
- ✅ Automatic config assembly from `base.yaml` + `credentials/*.yaml` + `models/*.yaml`
- ✅ Credentials resolved from environment variables, never hardcoded in config files
- ✅ `store_model_in_db` enabled — manage models through the admin UI or database
- ✅ Health checks for PostgreSQL (gates proxy startup) and the proxy liveness endpoint
- ✅ Data persistence
- ✅ Log rotation configuration
- ✅ Configurable proxy bind address via `LITELLM_BIND_ADDRESS`
- ✅ Smoke-test script covering model listing, chat, streaming, and tool calls

## Quick Start

### Prerequisites

- Docker
- Docker Compose v2 (`docker compose`)
- `curl` and `jq` (used by the test script and the documented commands)

### Configure

Copy the environment variable file and edit it:

```bash
cp .env.example .env
```

At minimum, set `LITELLM_MASTER_KEY`. Then add credentials for your LLM providers, for example:

```dotenv
DATABRICKS_API_BASE=https://<your-workspace>.azuredatabricks.net/serving-endpoints
DATABRICKS_API_KEY=<your-key>
```

> Tip:
> `.env` is gitignored, so provider keys stay local to your checkout.

### Add Credentials and Models

LiteLLM configuration is assembled from fragments under `litellm_config/`:

```
litellm_config/
├── base.yaml          # tracked in git — global litellm_settings / general_settings
├── credentials/       # local only — credential definitions (gitignored)
│   └── *.yaml
└── models/            # local only — model_list definitions (gitignored)
    └── *.yaml
```

Create one credentials file per provider, for example `litellm_config/credentials/databricks.yaml`:

```yaml
credential_list:
- credential_name: databricks
  credential_values:
    api_key: os.environ/DATABRICKS_API_KEY
    api_base: os.environ/DATABRICKS_API_BASE
  credential_info:
    custom_llm_provider: databricks
    description: Databricks credential
```

Then list the models to expose, for example `litellm_config/models/databricks.yaml`:

```yaml
model_list:
- model_name: my-model
  litellm_params:
    model: databricks/my-model
    litellm_credential_name: databricks
```

> Note:
> Every `*.yaml` file found in `credentials/` and `models/` is merged into the final config at startup. There is no central file to edit. Both directories are gitignored; if they are empty or missing, the proxy still starts with `base.yaml` only and models can be added through the admin UI.

### Start

```bash
docker compose up -d
```

On first startup, `litellm-init` assembles the merged config while PostgreSQL initializes, then the proxy starts once PostgreSQL is healthy and the config has been written.

### Verify

```bash
# Check config assembly output
docker compose logs litellm-init

# Check proxy startup
docker compose logs -f litellm

# List available models
source .env
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq
```

### Open the Admin UI

With the default configuration, open <http://localhost:4000/ui> and sign in with username `admin` and your `LITELLM_MASTER_KEY` as the password.

> Tip:
> If you customize `LITELLM_BIND_ADDRESS` or `LITELLM_PORT`, open the admin UI at the reachable host address and configured port. See [Networking](#networking) for bind address behavior.

### Test the API

```bash
# Run with the default test model (databricks-gpt-5-5)
./test.sh

# Or test a specific model
MODEL=databricks-glm-5-3 ./test.sh
```

The script lists models and exercises chat, streaming, and tool-augmented completions.

> Note:
> `test.sh` reads the test model from the `MODEL` environment variable and falls back to `databricks-gpt-5-5` when it is unset. Set `MODEL` to a model exposed by your proxy.

### Stop

```bash
docker compose down
```

### Stop and Remove Data

```bash
docker compose down -v
```

## Common Commands

The commands below assume the default proxy bind address and port:

- `LITELLM_BIND_ADDRESS=127.0.0.1`
- `LITELLM_PORT=4000`

> Tip:
> If you customize those values, replace URLs and ports with a reachable proxy address and port. See [Networking](#networking) for bind address behavior.

```bash
# Chat completion
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "my-model",
    "messages": [{ "role": "user", "content": "Hello" }]
  }' | jq

# List models
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq

# Connect to the PostgreSQL database
docker compose exec postgres psql -U litellm -d litellm

# View the config assembled at startup
docker compose logs litellm-init
```

### Monitoring

```bash
# View all service status
docker compose ps

# View service logs
docker compose logs -f

# View specific service logs
docker compose logs -f litellm

# View resource usage
docker stats
```

## Architecture

### Services

| Service | Description |
| ------- | ----------- |
| `postgres` | PostgreSQL database for usage, keys, and audit logs |
| `litellm-init` | One-shot job that assembles the final LiteLLM config |
| `litellm` | OpenAI-compatible proxy and admin UI |

`postgres` and `litellm-init` start in parallel; `litellm` is gated on both by `depends_on` conditions:

1. `postgres` becomes healthy (`pg_isready` health check)
2. `litellm-init` completes and writes `/config/litellm_config.yaml`
3. Once both conditions hold, `litellm` starts with `--config /config/litellm_config.yaml`

### Config Assembly

The `litellm-init` service scans `/source` (the mounted `litellm_config/` directory) and generates a single config file:

```yaml
include:
  - /source/base.yaml
  - /source/credentials/databricks.yaml
  - /source/models/databricks.yaml
  - /source/models/openai.yaml
  # ... every *.yaml found in credentials/ and models/
```

LiteLLM resolves the `include` entries and merges `credential_list` and `model_list` fragments into one configuration. The result is stored in the `litellm-config` volume and rebuilt on every startup.

`base.yaml` sets request/stream timeouts, `drop_params`, and `store_model_in_db: true`, so models can also be added through the admin UI or database instead of files.

### Ports

Only the proxy port is published to the host. PostgreSQL is reachable only inside the compose network.

| Service | Default Port | Environment Variable | Published |
| ------- | ------------ | -------------------- | --------- |
| `litellm` | `4000` | `LITELLM_PORT` | Host |
| `postgres` | `5432` | — | Internal only |

### Networking

The compose file publishes the proxy port with a configurable bind address. The default binds to `127.0.0.1`, which keeps the proxy accessible only from the local machine.

`LITELLM_BIND_ADDRESS` controls where the proxy listens on the host. When the proxy binds to `127.0.0.1`, use `localhost` or `127.0.0.1` locally. When it binds to a LAN address, use that reachable host address. If it binds to `0.0.0.0`, do not use `0.0.0.0` as the client address; use `127.0.0.1` locally or the host IP remotely. `test.sh` applies this mapping automatically.

## Configuration

All configurations can be customized through the `.env` file. Refer to `.env.example` for the full list.

### PostgreSQL Configuration

| Environment Variable | Default Value | Description |
| --------- | ----- | ------ |
| `POSTGRES_VERSION` | `18.6` | PostgreSQL image version |
| `POSTGRES_DB` | `litellm` | Database name |
| `POSTGRES_USER` | `litellm` | Database user |
| `POSTGRES_PASSWORD` | `pgpass4litellm` | Database password (change in production; avoid `@` `:` `/` characters) |

### LiteLLM Proxy Configuration

| Environment Variable | Default Value | Description |
| --------- | ----- | ------ |
| `LITELLM_VERSION` | `latest` | LiteLLM image version |
| `LITELLM_BIND_ADDRESS` | `127.0.0.1` | Network interface the proxy port binds to on the host |
| `LITELLM_PORT` | `4000` | Port exposed on the host (the container always listens on 4000 internally) |
| `LITELLM_MASTER_KEY` | `admin` | Master key used to authenticate proxy requests and admin UI sign-in (change in production, required) |
| `LITELLM_LOG` | `INFO` | LiteLLM log level: `DEBUG`, `INFO`, `WARNING`, `ERROR` |

> Tip:
> The whole `.env` file is passed into the `litellm` container, so any additional variables you define — such as `DATABRICKS_API_KEY` — are available to `os.environ/...` references in `credentials/*.yaml`.

### Logging Configuration

| Environment Variable | Default Value | Description |
| --------- | ----- | ------ |
| `MAX_LOG_FILE_SIZE` | `10m` | Maximum size of a single log file |
| `MAX_LOG_FILE_COUNT` | `3` | Number of log files to keep |

## Data Persistence

The deployment uses Docker named volumes:

- `postgres-data` — all database data (usage, keys, audit logs)
- `litellm-config` — the merged config generated by `litellm-init` (rebuilt on every startup, no need to back up)

> Warning:
> Docker named volumes are preserved across container restarts. Use `docker compose down -v` only when you want to remove the persisted data volumes.

## Production Notes

These compose files are intended for local development, testing, and controlled environments.

- Change `LITELLM_MASTER_KEY` and `POSTGRES_PASSWORD` before any real deployment.
- `POSTGRES_*` credentials take effect only when the `postgres-data` volume is first initialized. To change them later, use `ALTER ROLE` inside postgres, or re-initialize the volume with `docker compose down -v` (destroys all database data).
- Keep `LITELLM_BIND_ADDRESS` set to `127.0.0.1` for local-only access.
- If you bind the proxy to a LAN interface or `0.0.0.0`, restrict access with host firewall rules or a trusted network boundary, since the master key grants full proxy control.
- Avoid `@` `:` `/` characters in `POSTGRES_PASSWORD`; the value is embedded in the database connection URL.
- Pin `LITELLM_VERSION` and `POSTGRES_VERSION` instead of using `latest` when you need repeatable deployments.
- Provider API keys live in `.env`, which is gitignored. Never commit credentials or `credentials/*.yaml` files containing secrets.
- Use `docker compose down -v` only when you want to remove named volumes.

## Troubleshooting

### Proxy Fails to Start

```bash
# Check config assembly
docker compose logs litellm-init

# Check proxy startup
docker compose logs litellm

# Check database startup
docker compose logs postgres
```

If a fragment in `litellm_config/credentials/` or `litellm_config/models/` contains invalid YAML, fix the file and restart.

### Cannot Connect to the Proxy

```bash
# Check proxy status
docker compose ps litellm

# Check proxy logs
docker compose logs -f litellm
```

> Tip:
> If you changed `LITELLM_BIND_ADDRESS` or `LITELLM_PORT`, use a reachable host address and the configured port in your clients. See [Networking](#networking) for details.

### Database Errors

```bash
# Check database logs
docker compose logs postgres

# Connect to the database
docker compose exec postgres psql -U litellm -d litellm
```

If the proxy reports database connection failures, verify that `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` in `.env` are consistent and contain no `@` `:` `/` characters. If you changed these credentials in `.env` after the first startup, note that the values apply only when the `postgres-data` volume is first initialized — update them inside postgres with `ALTER ROLE` or re-initialize the volume.

### Model Requests Fail

```bash
# List the models the proxy exposes
source .env
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq
```

- If requests return 401, check that the provider credential variables (for example `DATABRICKS_API_KEY` and `DATABRICKS_API_BASE`) are set in `.env`.
- If a model is missing, add it through the admin UI (takes effect without a restart), or add it to a file under `litellm_config/models/` and apply it with `docker compose up -d --force-recreate litellm-init litellm`.
- If `test.sh` fails, set `MODEL` to an available model when running it, for example `MODEL=databricks-glm-5-3 ./test.sh`.

## License

[MIT License](LICENSE)

## Contributing

Issues and pull requests are welcome.

Before submitting a change, verify the compose configuration:

```bash
docker compose config
```

For README changes, check that documented service names, ports, and environment variables still match `docker-compose.yml` and `.env.example`.
