
# semantic-aqo-lab

semantic-aqo-lab is the development repository and environment for building and testing the Semantic Adaptive Query Optimization (AQO) PostgreSQL extension. It provides a Docker-based workflow, debugging tools, and helper scripts to speed up extension development.

## Overview

Semantic AQO is a PostgreSQL extension designed to optimize query execution by learning from query patterns and adapting optimization strategies based on semantic understanding of the data and workload. This repo focuses on local development, testing, and iteration.

## Features

- Adaptive Query Optimization based on semantic analysis
- Integration with PostgreSQL 16
- Hot-reload capability for rapid development
- Debugging support with GDB
- Supervisor-based process management
- Docker-based development environment

## Prerequisites

- Docker and Docker Compose
- PostgreSQL 16 (handled by Docker)
- Linux-based system (or WSL2 on Windows)
- Basic knowledge of PostgreSQL extensions

## Quick Start

1. Clone the repository:
	```bash
	git clone <repository-url>
	cd semantic-aqo-lab
	```

2. Configure environment:
	```bash
	cp .env.example .env
	# Edit .env with your preferences
	```

3. Start the development environment:
	```bash
	docker compose -f docker-compose-dev.yml up -d
	```

4. Connect to PostgreSQL:
	```bash
	./scripts/psql.sh
	```

5. Enable the extension:
	```sql
	CREATE EXTENSION semantic_aqo;
	```

## Development Setup

### Environment Variables

Create a `.env` file based on `.env.example`:

```bash
POSTGRES_VERSION=16
POSTGRES_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=mysecretpassword
DOCKERHUB_USERNAME=your_dockerhub_username
```

### Docker Compose Profiles

- Development: `docker-compose-dev.yml` - Includes debugging tools, volume mounts for live editing
- Production: `docker-compose-prod.yml` - Optimized for deployment

## Project Structure

```
├── .devcontainer
│   └── devcontainer.json           # VS Code dev container config
├── .docker
│   ├── Dockerfile.dev              # Development Docker image with debug tools
│   └── Dockerfile.prod             # Production deployment image
├── .env                            # Environment configuration (git-ignored)
├── .env.example                    # Example environment configuration
├── .gitignore                      # Git ignore rules
├── README.md                       # Project documentation
├── docker-compose-dev.yml          # Development environment config
├── docker-compose-prod.yml         # Production environment config
├── scripts                         # Helper scripts
│   ├── 00-system-setup.sh          # Install base dependencies for local/WSL dev
│   ├── 01-postgres-clone-and-build.sh # Clone and build PostgreSQL source
│   ├── 02-semantic-aqo-clone-and-build.sh # Clone and build Semantic AQO source
│   ├── setup-all.sh                # Run all setup steps in order
│   ├── build.sh                    # Build and push artifact image
│   ├── psql.sh                     # Connect to PostgreSQL shell
│   └── restart.sh                  # Rebuild and restart extension
├── src
│   └── semantic-aqo                # Main extension source
│       ├── Makefile                # Extension build configuration
│       ├── hooks                   # PostgreSQL hook implementations
│       │   ├── cardinality_hooks.c # Cardinality estimation hooks
│       │   ├── executor_hooks.c    # Query executor hooks
│       │   ├── hooks_manager.c     # Hook management and registration
│       │   └── planner_hook.c      # Query planner hooks
│       ├── model                   # Machine learning model components
│       │   ├── feature_extractor.c # Query feature extraction
│       │   ├── model_loader.c      # Model loading and inference
│       │   ├── model_loader.h      # Model loader header
│       │   └── sensate_model.bin   # Pre-trained ML model binary
│       ├── semantic_aqo--1.0.sql   # Extension SQL definitions
│       ├── semantic_aqo.c          # Main extension entry point
│       ├── semantic_aqo.control    # Extension metadata
│       ├── storage                 # Data persistence layer
│       │   ├── storage.c           # Storage implementation
│       │   └── storage.h           # Storage header file
│       └── utils                   # Utility functions
│           ├── calc.c              # Calculation utilities
│           ├── calc.h              # Calculation header
│           ├── hash.c              # Hash functions
│           ├── utils.c             # General utility functions
│           └── utils.h             # Utils header file
└── tools                           # Development and testing tools
	 ├── benchmarks                  # Performance benchmarking
	 │   ├── analysis                # Benchmark analysis tools
	 │   ├── synthetic               # Synthetic workload generators
	 │   └── tpch                    # TPC-H benchmark suite
	 └── monitoring                  # Monitoring and observability tools
```

## Building the Extension

### Inside the Container

The extension is automatically built during container initialization. To rebuild manually:

```bash
docker compose -f docker-compose-dev.yml exec postgres bash
cd /usr/src/semantic-aqo
make clean && make && make install
```

### Using Make Targets

Available Makefile targets:

- `make` - Build the extension
- `make install` - Install the extension
- `make clean` - Clean build artifacts
- `make debug-check` - Verify debug symbols are present

### Quick Rebuild Script

Use the provided script to rebuild and restart:

```bash
./scripts/restart.sh
```

## Development Workflow

### 1. Make Code Changes

Edit files in `src/semantic-aqo/` on your host machine. Changes are immediately visible in the container via volume mounts.

### 2. Rebuild and Reload

Option A: Using the restart script (from host):

```bash
./scripts/restart.sh
```

Option B: Manual rebuild (inside container):

```bash
docker compose -f docker-compose-dev.yml exec postgres bash
cd /usr/src/semantic-aqo
make dev
```

### 3. Test Changes

Connect to PostgreSQL and test your changes:

```bash
./scripts/psql.sh
```

```sql
DROP EXTENSION IF EXISTS semantic_aqo CASCADE;
CREATE EXTENSION semantic_aqo;
```

## Scripts Reference

All helper scripts are located in the `scripts/` directory.

### scripts/00-system-setup.sh

Installs baseline tooling and dependencies needed for local development (intended for Linux/WSL2).

### scripts/01-postgres-clone-and-build.sh

Clones the PostgreSQL source tree and builds it locally.

### scripts/02-semantic-aqo-clone-and-build.sh

Clones the Semantic AQO source and builds the extension against the local PostgreSQL build.

### scripts/setup-all.sh

Runs the full setup workflow (system setup, PostgreSQL build, and Semantic AQO build) in order.

### scripts/psql.sh

Connects to the PostgreSQL shell inside the container.

### scripts/restart.sh

Rebuilds the extension and restarts PostgreSQL.

### scripts/build.sh

Builds and pushes artifact image to Docker Hub.

## Troubleshooting

### Extension Not Loading

1. Check PostgreSQL logs:
	```bash
	docker compose -f docker-compose-dev.yml logs postgres
	```

2. Verify extension is installed:
	```bash
	docker compose -f docker-compose-dev.yml exec postgres bash
	ls /usr/lib/postgresql/16/lib/ | grep semantic_aqo
	```

### Connection Issues

1. Ensure the container is healthy:
	```bash
	docker compose -f docker-compose-dev.yml ps
	```

2. Check if PostgreSQL is accepting connections:
	```bash
	docker compose -f docker-compose-dev.yml exec postgres pg_isready
	```

## License

Specify your license here.

## Contact

Provide maintainer contact info here.

