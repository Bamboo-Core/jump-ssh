#!/bin/sh
set -eu

BASTION_USER="${BASTION_USER:-bastion}"
: "${BASTION_PASSWORD:?BASTION_PASSWORD nao definido (configure no .env)}"

# 1. Host keys persistentes (volume montado em /etc/ssh/keys)
if [ ! -f /etc/ssh/keys/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/keys/ssh_host_ed25519_key
fi
if [ ! -f /etc/ssh/keys/ssh_host_rsa_key ]; then
    ssh-keygen -q -t rsa -b 4096 -N "" -f /etc/ssh/keys/ssh_host_rsa_key
fi

# 2. Usuario sem shell (idempotente)
if ! id "$BASTION_USER" >/dev/null 2>&1; then
    adduser -D -s /sbin/nologin "$BASTION_USER"
fi

# 3. Senha a partir do ambiente
echo "${BASTION_USER}:${BASTION_PASSWORD}" | chpasswd

# 4. Diretorio de privilege separation
mkdir -p /var/empty

# 5. Monta argumentos dinamicos (AllowUsers sempre; PermitOpen se definido)
set -- -D -e -o "AllowUsers ${BASTION_USER}"
if [ -n "${BASTION_PERMITOPEN:-}" ]; then
    set -- "$@" -o "PermitOpen ${BASTION_PERMITOPEN}"
fi

exec /usr/sbin/sshd "$@"
