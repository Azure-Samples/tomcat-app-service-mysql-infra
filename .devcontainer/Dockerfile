FROM mcr.microsoft.com/devcontainers/java:25-bookworm

# Install a MySQL-compatible command-line client from Debian repos to avoid external GPG key issues.
RUN apt-get update \
  && apt-get install -y --no-install-recommends inetutils-tools default-mysql-client \
  && rm -rf /var/lib/apt/lists/*