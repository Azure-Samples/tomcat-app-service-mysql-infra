FROM mcr.microsoft.com/devcontainers/java:1-17-bullseye

# Install MySQL command-line client -- see https://dev.mysql.com/doc/refman/8.0/en/mysql.html
RUN apt-get update && apt-get install -y gnupg lsb-release inetutils-tools \
  && wget https://dev.mysql.com/get/mysql-apt-config_0.8.29-1_all.deb \
  && DEBIAN_FRONTEND=noninteractive dpkg -i mysql-apt-config_0.8.29-1_all.deb \
  && apt-get update \
  && apt install -y mysql-client