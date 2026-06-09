# Bastion Containerizado (Opção A) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar um pacote de deploy reproduzível de jump host SSH (OpenSSH custom, autenticação por senha, só TCP forwarding) para acessar IPs privados em um cliente teste, sem alterar o `service-netmiko`.

**Architecture:** Imagem Alpine + OpenSSH com `sshd` configurado para apenas encaminhar conexões (`AllowTcpForwarding yes`), usuário sem shell (`nologin`), sem root. O `service-netmiko` conecta com usuário+senha exatamente como nos bastions atuais e abre um canal `direct-tcpip` (`forwardOut`) até o equipamento privado. Empacotado em `docker-compose` parametrizável por `.env`.

**Tech Stack:** Docker, Docker Compose, Alpine Linux, OpenSSH (`sshd`), shell POSIX.

**Spec de referência:** `docs/specs/2026-06-09-bastion-container-opcao-a-design.md`

---

## Ambiente de execução (ler antes de começar)

- **Repositório:** `/Users/suporte/Projetos/bastion-deploy` (já inicializado com git, branch `main`).
- **VM de staging:** `192.145.216.144` (Ubuntu 24.04, Docker instalado). Já existe um bastion legado (`binlab/bastion`) na porta **22222** — **não mexer nele**. Usaremos a porta **22223** para o container de teste.
- **Acesso à VM:** chave SSH `~/.ssh/id_ed25519` já instalada para o usuário `nocia`. Docker exige `sudo`. Há um helper em `/tmp/sshsudo.exp` que roda comandos remotos com `sudo` (uso: `/tmp/sshsudo.exp '<comando>'`). Comandos SSH simples (sem sudo): `ssh nocia@192.145.216.144 '<comando>'`.
- **Gateway Docker na VM:** `172.17.0.1` (usado como alvo SSH conhecido no smoke test do túnel — é o próprio `sshd` da VM, porta 22).

---

## Estrutura de arquivos

| Arquivo | Responsabilidade |
|---|---|
| `Dockerfile` | Imagem Alpine + OpenSSH, copia config e entrypoint |
| `sshd_config` | Hardening do `sshd`: só forwarding, sem shell interativo |
| `entrypoint.sh` | Gera/persiste host keys, cria usuário sem shell, aplica senha, sobe `sshd` |
| `docker-compose.yml` | Sobe o serviço lendo parâmetros do `.env` |
| `.env.example` | Parâmetros por cliente (porta, usuário, senha, PermitOpen) |
| `README.md` | Runbook de deploy no cliente + smoke test + allowlist de firewall |

---

## Fase 1 — Criar o pacote (local)

### Task 1: `sshd_config`

**Files:**
- Create: `/Users/suporte/Projetos/bastion-deploy/sshd_config`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```sshd_config
# Bastion jump host — somente TCP forwarding, sem shell.
Port 2222
PermitRootLogin no

PasswordAuthentication yes
PubkeyAuthentication yes

AllowTcpForwarding yes
PermitTunnel no
AllowAgentForwarding no
X11Forwarding no
GatewayPorts no
PrintMotd no
PermitTTY no

ClientAliveInterval 30
ClientAliveCountMax 3
MaxAuthTries 3
LoginGraceTime 20

HostKey /etc/ssh/keys/ssh_host_ed25519_key
HostKey /etc/ssh/keys/ssh_host_rsa_key
```

> `AllowUsers` e `PermitOpen` NÃO ficam aqui — são injetados em runtime pelo `entrypoint.sh` a partir do `.env` (para serem parametrizáveis por cliente).

- [ ] **Step 2: Commit**

```bash
cd /Users/suporte/Projetos/bastion-deploy
git add sshd_config
git commit -m "feat: sshd_config travado para jump host (só forwarding)"
```

---

### Task 2: `entrypoint.sh`

**Files:**
- Create: `/Users/suporte/Projetos/bastion-deploy/entrypoint.sh`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```sh
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
```

- [ ] **Step 2: Commit**

```bash
cd /Users/suporte/Projetos/bastion-deploy
chmod +x entrypoint.sh
git add entrypoint.sh
git commit -m "feat: entrypoint gera host keys, cria user sem shell e sobe sshd"
```

---

### Task 3: `Dockerfile`

**Files:**
- Create: `/Users/suporte/Projetos/bastion-deploy/Dockerfile`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```dockerfile
FROM alpine:3.20

RUN apk add --no-cache openssh shadow \
    && mkdir -p /etc/ssh/keys /var/empty

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 2: Commit**

```bash
cd /Users/suporte/Projetos/bastion-deploy
git add Dockerfile
git commit -m "feat: Dockerfile Alpine + OpenSSH para o bastion"
```

---

### Task 4: `docker-compose.yml`

**Files:**
- Create: `/Users/suporte/Projetos/bastion-deploy/docker-compose.yml`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```yaml
services:
  bastion:
    build: .
    container_name: bastion
    restart: unless-stopped
    ports:
      - "${BASTION_PORT:-22222}:2222"
    environment:
      BASTION_USER: ${BASTION_USER:-bastion}
      BASTION_PASSWORD: ${BASTION_PASSWORD:?defina BASTION_PASSWORD no .env}
      BASTION_PERMITOPEN: ${BASTION_PERMITOPEN:-}
    volumes:
      - bastion_hostkeys:/etc/ssh/keys

volumes:
  bastion_hostkeys:
```

- [ ] **Step 2: Commit**

```bash
cd /Users/suporte/Projetos/bastion-deploy
git add docker-compose.yml
git commit -m "feat: docker-compose parametrizavel por .env"
```

---

### Task 5: `.env.example`

**Files:**
- Create: `/Users/suporte/Projetos/bastion-deploy/.env.example`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

```env
# Porta externa do bastion na VM do cliente
BASTION_PORT=22222

# Usuario que o service-netmiko usara para conectar
BASTION_USER=bastion

# Senha forte (NAO reutilizar credenciais de outras maquinas)
BASTION_PASSWORD=trocar-por-senha-forte

# (Opcional, recomendado) restringe os destinos do tunel. O sshd PermitOpen
# aceita apenas pares host:port LITERAIS (NAO aceita CIDR/mascara). Liste os
# IPs:porta dos equipamentos, separados por espaco. Ex.:
#   BASTION_PERMITOPEN=192.168.1.10:22 192.168.1.11:22
# Para restricao por sub-rede inteira, use regras de firewall de saida na VM.
# Deixe vazio para permitir qualquer destino.
BASTION_PERMITOPEN=
```

- [ ] **Step 2: Commit**

```bash
cd /Users/suporte/Projetos/bastion-deploy
git add .env.example
git commit -m "docs: .env.example com parametros por cliente"
```

---

### Task 6: `README.md` (runbook)

**Files:**
- Create: `/Users/suporte/Projetos/bastion-deploy/README.md`

- [ ] **Step 1: Criar o arquivo com o conteúdo exato**

````markdown
# Bastion Deploy — jump host SSH containerizado

Jump host SSH (OpenSSH em container) para o `service-netmiko` alcançar
equipamentos em IPs privados. Autenticação por **senha**, somente **TCP
forwarding** (sem shell, sem root).

## Pré-requisitos de rede (críticos)

1. **service-netmiko → bastion:** a porta `BASTION_PORT` da VM precisa estar
   acessível de onde o `service-netmiko` roda (IP público + firewall, ou VPN).
2. **bastion → equipamento:** a VM precisa ter **rota até os IPs privados**
   (mesma LAN/VLAN ou roteamento).

## Deploy

```bash
cp .env.example .env
# editar .env: definir BASTION_PASSWORD forte, ajustar BASTION_PORT e
# BASTION_PERMITOPEN conforme a rede do cliente.
docker compose up -d --build
docker compose logs --no-log-prefix bastion   # deve mostrar "Server listening on ..."
```

## Allowlist de firewall (recomendado)

Restringir a porta do bastion ao IP do `service-netmiko` reduz drasticamente
brute force. Ex. (ufw):

```bash
sudo ufw allow from <IP_DO_SERVICE_NETMIKO> to any port <BASTION_PORT> proto tcp
sudo ufw deny <BASTION_PORT>/tcp
```

## Smoke test do túnel (antes de cadastrar no app)

A partir do host do `service-netmiko`:

```bash
# abre um túnel local 2200 -> <IP_PRIVADO>:22 através do bastion
ssh -p <BASTION_PORT> -N -L 2200:<IP_PRIVADO_EQUIP>:22 bastion@<IP_BASTION>
# em outro terminal: deve cair no equipamento
ssh -p 2200 admin@127.0.0.1
```

Confirmar que **shell direto no bastion é negado**:

```bash
ssh -p <BASTION_PORT> bastion@<IP_BASTION>
# esperado: conexão aceita mas SEM shell (PTY negado / sessão encerra)
```

## Cadastro no app (Kuanticks → gerenciamento de bastion)

- `public_ip` = IP da VM do bastion
- `username`  = valor de `BASTION_USER` (default `bastion`)
- `password`  = valor de `BASTION_PASSWORD`
- `port`      = valor de `BASTION_PORT`

## Plano B de roteamento

Se a LAN exigir, trocar a seção `ports`/rede por `network_mode: host` no
`docker-compose.yml` (o container herda a rede da VM diretamente).
````

- [ ] **Step 2: Commit**

```bash
cd /Users/suporte/Projetos/bastion-deploy
git add README.md
git commit -m "docs: README com runbook de deploy, firewall e smoke test"
```

---

## Fase 2 — Validar na VM de staging (192.145.216.144)

Objetivo: provar que a imagem builda, sobe e **o túnel funciona ponta-a-ponta**, sem tocar no bastion legado (porta 22222). Usamos a porta **22223** e o `sshd` da própria VM (`172.17.0.1:22`) como alvo conhecido.

### Task 7: Copiar o pacote para a VM

**Files:** nenhum (operação de transferência)

- [ ] **Step 1: Criar diretório de teste na VM**

```bash
ssh nocia@192.145.216.144 'mkdir -p /home/nocia/bastion-test'
```

- [ ] **Step 2: Copiar os arquivos do pacote (sem .git/docs)**

```bash
cd /Users/suporte/Projetos/bastion-deploy
scp Dockerfile sshd_config entrypoint.sh docker-compose.yml .env.example \
    nocia@192.145.216.144:/home/nocia/bastion-test/
```

- [ ] **Step 3: Verificar que chegaram**

```bash
ssh nocia@192.145.216.144 'ls -1 /home/nocia/bastion-test/'
```
Expected: lista com `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `sshd_config`, `.env.example`.

---

### Task 8: Configurar `.env` de teste e subir o container

**Files:** `/home/nocia/bastion-test/.env` (na VM)

- [ ] **Step 1: Criar `.env` de teste (porta 22223, alvo = sshd da VM)**

```bash
ssh nocia@192.145.216.144 'cat > /home/nocia/bastion-test/.env <<EOF
BASTION_PORT=22223
BASTION_USER=bastion
BASTION_PASSWORD=Teste-Bastion-2026!
BASTION_PERMITOPEN=172.17.0.1:22
EOF'
```

- [ ] **Step 2: Build + up (requer sudo → usar helper)**

```bash
/tmp/sshsudo.exp 'cd /home/nocia/bastion-test && docker compose up -d --build'
```
Expected: build conclui e `Container bastion ... Started`.

- [ ] **Step 3: Verificar que está rodando e escutando**

```bash
/tmp/sshsudo.exp 'docker ps --filter name=^/bastion$ --format "{{.Names}} {{.Status}} {{.Ports}}"'
```
Expected: `bastion Up ... 0.0.0.0:22223->2222/tcp`.

- [ ] **Step 4: Conferir log do sshd**

```bash
/tmp/sshsudo.exp 'docker logs bastion 2>&1 | tail -5'
```
Expected: linha `Server listening on 0.0.0.0 port 2222`.

---

### Task 9: Smoke test do túnel (o teste que prova o conceito)

**Files:** nenhum

Usamos `sshpass` para abrir o túnel de forma não-interativa (senha do usuário `bastion`), tunelando até o `sshd` da própria VM (`172.17.0.1:22`) como alvo conhecido.

- [ ] **Step 1: Instalar `sshpass` na VM (cliente SSH com senha não-interativa)**

```bash
/tmp/sshsudo.exp 'apt-get install -y sshpass'
```
Expected: `sshpass` instalado (ou já presente).

- [ ] **Step 2: Abrir o túnel via bastion (22223) → alvo 172.17.0.1:22, em background**

```bash
ssh nocia@192.145.216.144 'sshpass -p "Teste-Bastion-2026!" \
  ssh -f -N -p 22223 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -L 127.0.0.1:2200:172.17.0.1:22 bastion@127.0.0.1 && echo TUNEL_ABERTO'
```
Expected: `TUNEL_ABERTO`.

- [ ] **Step 3: Provar que o túnel chega no sshd alvo (banner SSH na porta 2200 local)**

```bash
ssh nocia@192.145.216.144 'echo | nc -w 3 127.0.0.1 2200 | head -1'
```
Expected: banner começando com `SSH-2.0-OpenSSH` (veio do `sshd` da VM, através do bastion). Isso prova o caminho `cliente → bastion → forwardOut → alvo:22`.

- [ ] **Step 4: Fechar o túnel de teste**

```bash
ssh nocia@192.145.216.144 'pkill -f "127.0.0.1:2200:172.17.0.1:22" || true; echo fechado'
```

---

### Task 10: Verificar hardening (shell negado)

**Files:** nenhum

- [ ] **Step 1: Tentar abrir shell interativo no bastion (deve falhar/sem shell)**

```bash
ssh nocia@192.145.216.144 'sshpass -p "Teste-Bastion-2026!" \
  ssh -p 22223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    bastion@127.0.0.1 "echo DEVERIA_FALHAR" 2>&1; echo "rc=$?"'
```
Expected: comando **não** retorna `DEVERIA_FALHAR` (shell/exec negado por `nologin` + `PermitTTY no`); `rc` diferente de 0 ou sessão sem saída de comando. Confirma que o usuário só serve para forwarding.

- [ ] **Step 2: Confirmar que o bastion legado (22222) segue intacto**

```bash
/tmp/sshsudo.exp 'docker ps --filter name=bastion --format "{{.Names}} {{.Ports}}"'
```
Expected: aparecem **dois** containers — o legado (`...->22222`/22) e o de teste (`22223->2222`), ambos `Up`.

---

### Task 11: (Opcional nesta VM) teste via endpoint do app

> Só aplicável se houver um equipamento SSH alcançável a partir da VM para usar como alvo real. Caso contrário, este teste roda no ambiente do cliente (Fase 3). O smoke test da Task 9 já prova o mecanismo do túnel.

**Files:** nenhum

- [ ] **Step 1: Chamar `POST /api/ssh/test-ssh` do `service-netmiko` apontando para o bastion de teste**

```bash
curl -s -X POST http://<HOST_SERVICE_NETMIKO>:4001/api/ssh/test-ssh \
  -H 'Content-Type: application/json' \
  -d '{
    "host": "<IP_PRIVADO_ALVO>", "port": 22,
    "username": "<user_alvo>", "password": "<senha_alvo>",
    "bastion_host": "192.145.216.144", "bastion_port": 22223,
    "bastion_username": "bastion", "bastion_password": "Teste-Bastion-2026!"
  }'
```
Expected: `{"success":true,...,"via_bastion":true}`.

---

### Task 12: Teardown do ambiente de staging

**Files:** nenhum

- [ ] **Step 1: Derrubar e limpar o container/volume de teste**

```bash
/tmp/sshsudo.exp 'cd /home/nocia/bastion-test && docker compose down -v'
```
Expected: container `bastion` (teste) removido, volume `bastion-test_bastion_hostkeys` removido.

- [ ] **Step 2: Confirmar que só o legado permanece**

```bash
/tmp/sshsudo.exp 'docker ps --filter name=bastion --format "{{.Names}} {{.Ports}}"'
```
Expected: apenas o bastion legado (`...->22222`).

---

## Fase 3 — Runbook de deploy no cliente (executar quando a VM do cliente existir)

Esta fase é um **runbook** (não automatizável agora — depende do ambiente do cliente). Está documentada no `README.md`; os passos abaixo são o checklist de execução.

### Task 13: Deploy e validação no cliente

**Files:** nenhum (execução no ambiente do cliente)

- [ ] **Step 1: Confirmar pré-requisitos de rede**
  - [ ] VM do cliente tem rota até os IPs privados dos equipamentos (`ping`/`nc` até `<IP_PRIVADO>:22`).
  - [ ] Porta do bastion acessível a partir do `service-netmiko`.

- [ ] **Step 2: Subir o pacote**

```bash
git clone <repo>/bastion-deploy && cd bastion-deploy
cp .env.example .env
# editar .env: BASTION_PASSWORD forte, BASTION_PORT, BASTION_PERMITOPEN (sub-rede do cliente)
docker compose up -d --build
```

- [ ] **Step 3: Aplicar allowlist de firewall** (seção do README) liberando só o IP do `service-netmiko`.

- [ ] **Step 4: Smoke test do túnel** (seção do README) até um equipamento real.

- [ ] **Step 5: Cadastrar o bastion na UI do Kuanticks** (public_ip, username, password, port).

- [ ] **Step 6: Teste ponta-a-ponta** — rodar um comando real num equipamento privado via Kuanticks e conferir a saída (`via_bastion: true`).

---

## Critérios de sucesso (do spec)

- [ ] `docker compose up -d --build` sobe o bastion (validado na Fase 2).
- [ ] Smoke test do túnel chega no alvo SSH (Task 9 / Task 13.4).
- [ ] `POST /api/ssh/test-ssh` retorna `success: true, via_bastion: true` (Task 11 / Task 13.6).
- [ ] Shell direto no bastion é negado (Task 10).
- [ ] Pacote sobe noutra VM só mudando o `.env` (Fase 3).
- [ ] Bastion legado da VM permanece intacto durante a validação (Task 10.2 / 12.2).
```
