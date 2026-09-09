# Pi-hole + Unbound + Squid Installation Script

A simple, self-contained installer for deploying **Pi-hole, Unbound, and Squid** on a Linux system using Docker or Podman.

The installer automatically detects the available container runtime, generates the required configuration, creates the service directories, validates the Compose configuration, and starts the complete stack.

It is designed to be **safe to re-run**, keeping existing configuration such as the Pi-hole password.

---

## Features

* 🛡️ **Pi-hole** network-wide DNS filtering
* 🔐 **Unbound** recursive DNS resolver
* 🌐 **Squid** HTTP proxy/cache
* 🐳 Docker + Docker Compose support
* 🦭 Podman + `podman compose` support
* 🦭 Podman + `podman-compose` support
* 🔄 Safe to re-run and update
* 🔑 Automatically generates a secure Pi-hole admin password
* 💾 Preserves existing configuration when re-running the installer
* 🌐 Automatically detects the host's IPv4 address and LAN subnet
* 🔒 Binds DNS and web services to the detected server address
* 🧹 Project-scoped cleanup with the included uninstaller
* 🧪 Validates the Compose configuration before deployment
* 📁 Keeps configuration and persistent data inside the project directory
* 🚫 Does not install or remove Docker/Podman itself
* 🚫 Does not modify unrelated containers, images, networks, or services

---

## Services

The installation creates three services:

| Service     | Purpose                          |            Port |
| ----------- | -------------------------------- | --------------: |
| **Pi-hole** | DNS filtering and administration |    `53`, `8080` |
| **Unbound** | Recursive DNS resolution         | `5335` internal |
| **Squid**   | HTTP proxy/cache                 |          `3128` |

### DNS flow

```text
Client
  │
  ▼
Pi-hole :53
  │
  ▼
Unbound :5335
  │
  ▼
Internet DNS Root Servers
```

Pi-hole handles filtering and forwards DNS queries to the local Unbound resolver.

Unbound performs recursive DNS resolution rather than relying on a third-party upstream DNS provider.

---

# Requirements

The host system should have:

* Linux
* Bash
* `ip`
* `awk`
* `cut`
* `od`
* `tr`
* Docker + Compose

**or**

* Podman + `podman compose`

**or**

* Podman + `podman-compose`

`openssl` is recommended for secure password generation, although the installer has a `/dev/urandom` fallback.

The installer does **not** install Docker or Podman for you.

---

# Installation

Clone the repository:

```bash
git clone https://github.com/siafulinux/Pi-Hole-Unbound-and-Squid-install-script.git
```

Enter the project directory:

```bash
cd Pi-Hole-Unbound-and-Squid-install-script
```

Make the installer executable:

```bash
chmod +x install.sh
```

Run it:

```bash
./install.sh
```

If your Docker/Podman installation requires root privileges:

```bash
sudo ./install.sh
```

That's it.

The installer will:

1. Detect the available container runtime.
2. Detect the active network interface.
3. Detect the server's IPv4 address.
4. Detect the local LAN subnet.
5. Generate a Pi-hole administrator password if one does not already exist.
6. Create the required configuration files.
7. Validate the Compose configuration.
8. Pull the required container images.
9. Start the services.

---

# Configuration

The installer is designed so that you **do not need to edit the script itself**.

Configuration is stored in:

```text
.env
```

The initial configuration is automatically generated from the detected system settings.

The generated `.env` contains:

```text
TZ=America/New_York
SERVER_IP=192.168.1.10
LAN_SUBNET=192.168.1.0/24
LOCAL_DOMAIN=home.arpa
PIHOLE_PASSWORD=generated-password
SQUID_PORT=3128
COMPOSE_PROJECT_NAME=pihole-unbound-squid
```

The `.env` file is created with restrictive permissions.

```text
chmod 600 .env
```

---

## Changing Configuration

After installation, configuration can be changed by editing:

```bash
nano .env
```

For example:

```text
TZ=America/New_York
SERVER_IP=192.168.1.10
LAN_SUBNET=192.168.1.0/24
LOCAL_DOMAIN=home.arpa
PIHOLE_PASSWORD=your-password
SQUID_PORT=3128
```

After changing configuration, run:

```bash
./install.sh
```

The installer will regenerate the required configuration and recreate the affected services.

---

# Network Configuration

By default, the installer attempts to automatically determine:

* Active network interface
* Host IPv4 address
* Local LAN subnet

For example:

```text
Network interface: eth0
Host IPv4:         192.168.1.10
Server address:    192.168.1.10
LAN subnet:        192.168.1.0/24
```

You can override these values in `.env` if necessary.

### Example

```text
SERVER_IP=192.168.1.10
LAN_SUBNET=192.168.1.0/24
```

The `SERVER_IP` should be the LAN address of the machine running the containers.

---

# Pi-hole

After installation, open:

```text
http://SERVER_IP:8080/admin/
```

For example:

```text
http://192.168.1.10:8080/admin/
```

Use the Pi-hole administrator password displayed by the installer.

The password is also stored in:

```text
.env
```

Keep this file private.

---

# Squid

Squid listens on:

```text
SERVER_IP:3128
```

The default port is:

```text
3128
```

You can change this with:

```text
SQUID_PORT=3128
```

For example:

```text
SQUID_PORT=8081
```

After changing the port, run:

```bash
./install.sh
```

---

# Unbound

Unbound runs internally on:

```text
5335
```

It is intentionally not published directly to the LAN.

Pi-hole communicates with Unbound over the internal Docker/Podman network:

```text
Pi-hole
   │
   ▼
Unbound :5335
```

Unbound is configured with several security and privacy-oriented options, including:

* DNSSEC trust anchor support
* QNAME minimisation
* Hardened DNSSEC handling
* Hidden version information
* Hidden resolver identity
* Prefetching
* DNS caching
* Restricted access controls

IPv6 DNS resolution is disabled by default in the included Unbound configuration.

---

# Project Directory

After installation, the project will contain the service configuration and persistent data:

```text
Pi-Hole-Unbound-and-Squid-install-script/
│
├── install.sh
├── uninstall.sh
├── docker-compose.yml
├── .env
├── .pihole-unbound-manifest
│
├── etc-pihole/
│   └── Pi-hole data
│
├── unbound/
│   └── unbound.conf
│
├── squid-conf/
│   └── squid.conf
│
├── squid-cache/
│   └── Squid cache
│
└── squid-logs/
    └── Squid logs
```

This keeps the deployment self-contained rather than scattering configuration across the host filesystem.

---

# Updating / Re-running

The installer is designed to be safely re-run.

```bash
./install.sh
```

When an existing `.env` is detected, the installer preserves the existing configuration.

This means an existing Pi-hole password will not normally be replaced with a new password.

The installer will regenerate the service configuration and ensure the stack is running.

---

# Checking the Services

View the running containers:

### Docker

```bash
docker ps
```

### Podman

```bash
podman ps
```

Or use Compose:

```bash
docker compose ps
```

or:

```bash
podman compose ps
```

View service logs:

```bash
docker compose logs
```

or:

```bash
podman compose logs
```

Follow the logs:

```bash
docker compose logs -f
```

---

# Stopping the Stack

To stop the services without uninstalling them:

```bash
docker compose down
```

or:

```bash
podman compose down
```

Start them again with:

```bash
docker compose up -d
```

or:

```bash
podman compose up -d
```

---

# Uninstallation

The repository includes a dedicated `uninstall.sh`.

Make it executable:

```bash
chmod +x uninstall.sh
```

Run it:

```bash
./uninstall.sh
```

The normal uninstall removes:

* Containers
* Project networks
* Generated Compose configuration
* Generated `.env`
* Generated Squid configuration

Persistent application data is preserved.

---

## Complete Removal

To remove the containers, networks, configuration, cache, logs, and persistent Pi-hole/Unbound data:

```bash
./uninstall.sh --purge-data
```

You will be asked for confirmation before anything is removed.

To skip the confirmation:

```bash
./uninstall.sh --purge-data --yes
```

---

# Dry Run

You can see what the uninstaller would remove without changing anything:

```bash
./uninstall.sh --dry-run
```

For a complete purge dry run:

```bash
./uninstall.sh --purge-data --dry-run
```

This is useful for verifying exactly what will happen before performing the cleanup.

---

# Uninstall Options

```text
--purge-data
    Remove persistent Pi-hole, Unbound, and Squid data.

--dry-run
    Show what would be removed without making changes.

--yes
    Skip confirmation prompts.

--help
    Display the help message.
```

---

# Safety

The installer and uninstaller are designed to operate within the project's own deployment scope.

The uninstaller does **not** attempt to remove:

* Docker
* Podman
* Docker images unrelated to this project
* Podman images unrelated to this project
* Unrelated containers
* Unrelated networks
* System packages
* Host DNS configuration
* Other applications

The cleanup process is tied to the Compose project and its project-specific resources rather than blindly removing containers based only on generic names such as `pihole`, `unbound`, or `squid`.

---

# Container Images

The deployment currently uses:

```text
pihole/pihole:latest
alpinelinux/unbound:latest
ubuntu/squid:latest
```

Images are pulled automatically during installation.

You can view the images with:

```bash
docker images
```

or:

```bash
podman images
```

---

# Ports

The default port configuration is:

```text
53/tcp       Pi-hole DNS
53/udp       Pi-hole DNS
8080/tcp     Pi-hole Web Interface
3128/tcp     Squid Proxy
5335/tcp     Unbound internal
5335/udp     Unbound internal
```

Only the services intended to be accessible from the LAN are published on the host.

Unbound remains internal to the container network.

---

# Example

A typical installation might look like:

```text
Server IP:     192.168.1.10
LAN subnet:    192.168.1.0/24
Pi-hole:       http://192.168.1.10:8080/admin/
DNS:           192.168.1.10:53
Squid:         192.168.1.10:3128
Unbound:       internal :5335
```

Configure clients on the LAN to use:

```text
Primary DNS:
192.168.1.10
```

Pi-hole will filter DNS requests and forward permitted requests to Unbound.

---

# Troubleshooting

## Check container status

```bash
docker compose ps
```

or:

```bash
podman compose ps
```

## View logs

```bash
docker compose logs --tail=100
```

or:

```bash
podman compose logs --tail=100
```

## Check Pi-hole

```bash
docker compose logs pihole
```

## Check Unbound

```bash
docker compose logs unbound
```

## Check Squid

```bash
docker compose logs squid
```

## Validate Compose configuration

```bash
docker compose config
```

or:

```bash
podman compose config
```

---

# License

Add your preferred license here.

For example:

```text
MIT License
```

---

## Disclaimer

This project is provided as-is. Review the generated configuration and network exposure before deploying it on a production or untrusted network.

---

## Author

**Siafulinux**

GitHub:

https://github.com/siafulinux/Pi-Hole-Unbound-and-Squid-install-script
