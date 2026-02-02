# XTDB Docker Setup

Recipes for running XTDB in development.

## Quick Start (Ephemeral)

For quick testing without persistence:

```bash
docker run -it --pull=always \
  -p 5432:5432 \
  ghcr.io/xtdb/xtdb
```

Data is lost when the container stops.

## Persistent Setup (Recommended for Dev)

### 1. Create a data directory with correct permissions

XTDB runs as UID 20000 inside the container:

```bash
mkdir -p ~/.xtdb/data
sudo chown -R 20000:20000 ~/.xtdb/data
```

### 2. Run with volume mount

```bash
docker run -d \
  --name xtdb \
  -p 5432:5432 \
  -p 8080:8080 \
  -v ~/.xtdb/data:/var/lib/xtdb \
  ghcr.io/xtdb/xtdb
```

### 3. Verify it's running

```bash
# Check container status
docker ps | grep xtdb

# Check health endpoint
curl http://localhost:8080/healthz

# Connect via psql
psql -h localhost -p 5432 -d xtdb -c "SELECT 1"
```

## Updating XTDB

### Pull the latest image

```bash
docker pull ghcr.io/xtdb/xtdb
```

### Update a running container

```bash
# Pull latest image
docker pull ghcr.io/xtdb/xtdb

# Stop and remove current container (data persists in volume)
docker stop xtdb && docker rm xtdb

# Start with new image
docker run -d \
  --name xtdb \
  -p 5433:5432 \
  -p 8080:8080 \
  -v ~/.xtdb/data:/var/lib/xtdb \
  ghcr.io/xtdb/xtdb
```

### Check current version

```bash
# Via health endpoint
curl -s http://localhost:8080/healthz | jq .

# Or check image digest
docker inspect ghcr.io/xtdb/xtdb --format='{{.Id}}'
```

## Creating Databases

XTDB has one primary database (`xtdb`) that always exists. For project isolation,
attach secondary databases.

### Connect to the primary database

```bash
psql -h localhost -p 5432 -d xtdb
```

### Attach a new database for your project

```sql
-- Create a database for your project
ATTACH DATABASE my_project WITH $$
  log: !Local
    path: '/var/lib/xtdb/my_project/log'
  storage: !Local
    path: '/var/lib/xtdb/my_project/storage'
$$;

-- Verify it exists
SELECT * FROM information_schema.schemata;
```

### Connect to your project database

```bash
psql -h localhost -p 5432 -d my_project
```

Or in Elixir config:

```elixir
config :my_app, MyApp.XTDBRepo,
  hostname: "localhost",
  port: 5432,
  database: "my_project"
```

## Managing Databases

### Verify a database exists

```bash
# Try connecting to the database
psql -h localhost -p 5432 -d my_project -c "SELECT 1"
```

### Detach a database (keeps data)

```sql
-- From the primary 'xtdb' database
DETACH DATABASE my_project;
```

### Re-attach a database

```sql
ATTACH DATABASE my_project WITH $$
  log: !Local
    path: '/var/lib/xtdb/my_project/log'
  storage: !Local
    path: '/var/lib/xtdb/my_project/storage'
$$;
```

## Wiping Data

### Option 1: Wipe a single project database

```bash
# 1. Detach the database
psql -h localhost -p 5432 -d xtdb -c "DETACH DATABASE my_project"

# 2. Delete its storage (inside the container)
docker exec xtdb rm -rf /var/lib/xtdb/my_project

# 3. Re-attach with fresh storage
psql -h localhost -p 5432 -d xtdb -c "
ATTACH DATABASE my_project WITH \$\$
  log: !Local
    path: '/var/lib/xtdb/my_project/log'
  storage: !Local
    path: '/var/lib/xtdb/my_project/storage'
\$\$
"
```

### Option 2: Wipe everything (nuclear option)

```bash
# Stop and remove the container
docker stop xtdb && docker rm xtdb

# Delete all data
sudo rm -rf ~/.xtdb/data/*

# Re-create with correct permissions
sudo chown -R 20000:20000 ~/.xtdb/data

# Start fresh
docker run -d \
  --name xtdb \
  -p 5432:5432 \
  -p 8080:8080 \
  -v ~/.xtdb/data:/var/lib/xtdb \
  ghcr.io/xtdb/xtdb
```

### Option 3: Use a helper script

Create `scripts/xtdb-reset.sh`:

```bash
#!/bin/bash
set -e

CONTAINER_NAME="xtdb"
DATA_DIR="$HOME/.xtdb/data"

echo "Stopping XTDB..."
docker stop $CONTAINER_NAME 2>/dev/null || true
docker rm $CONTAINER_NAME 2>/dev/null || true

echo "Wiping data..."
sudo rm -rf "$DATA_DIR"/*
sudo chown -R 20000:20000 "$DATA_DIR"

echo "Starting fresh XTDB..."
docker run -d \
  --name $CONTAINER_NAME \
  -p 5432:5432 \
  -p 8080:8080 \
  -v "$DATA_DIR":/var/lib/xtdb \
  ghcr.io/xtdb/xtdb

echo "Waiting for XTDB to be ready..."
sleep 3

# Re-create project databases if needed
# psql -h localhost -p 5432 -d xtdb -c "ATTACH DATABASE my_project WITH ..."

echo "XTDB reset complete!"
```

Make it executable:

```bash
chmod +x scripts/xtdb-reset.sh
```

## Docker Compose (Alternative)

Create `docker-compose.yml`:

```yaml
services:
  xtdb:
    image: ghcr.io/xtdb/xtdb
    container_name: xtdb
    ports:
      - "5432:5432"
      - "8080:8080"
    volumes:
      - xtdb-data:/var/lib/xtdb
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/healthz"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  xtdb-data:
```

Commands:

```bash
# Start
docker compose up -d

# Stop (keeps data)
docker compose down

# Wipe everything
docker compose down -v
```

## Connecting from Elixir

### Test connection

```elixir
# In iex -S mix
{:ok, conn} = Postgrex.start_link(
  hostname: "localhost",
  port: 5432,
  database: "xtdb",
  username: "xtdb",
  password: ""
)

Postgrex.query!(conn, "SELECT 1", [])
```

### Repo configuration

```elixir
# config/dev.exs
config :my_app, MyApp.XTDBRepo,
  hostname: "localhost",
  port: 5432,
  database: "my_project",  # Your attached database
  username: "xtdb",
  password: "",
  pool_size: 10
```

## Troubleshooting

### Permission denied on volume

```bash
sudo chown -R 20000:20000 ~/.xtdb/data
```

### Port already in use

```bash
# Find what's using port 5432
lsof -i :5432

# Use a different port
docker run -d -p 5433:5432 ...
```

### Container won't start

```bash
# Check logs
docker logs xtdb

# Run interactively to see errors
docker run -it --rm \
  -v ~/.xtdb/data:/var/lib/xtdb \
  ghcr.io/xtdb/xtdb
```

### Can't connect from Elixir

```bash
# Verify XTDB is listening
nc -zv localhost 5432

# Test with psql first
psql -h localhost -p 5432 -d xtdb -c "SELECT 1"
```
