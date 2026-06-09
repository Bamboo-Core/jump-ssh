# Design — Bastion containerizado (Opção A) para cliente teste

**Data:** 2026-06-09
**Autor:** phoffmann@nocai.io (com Claude Code)
**Status:** Aprovado para planejamento

---

## 1. Contexto

O **bastion** (jump host SSH) é usado pelo `service-netmiko` para alcançar equipamentos de
rede em **IPs privados**, via túnel SSH (`ssh2.forwardOut()` — modelo two-hop). As credenciais
de cada bastion ficam na tabela `bastion` do PostgreSQL (`public_ip`, `username`, `password`
criptografada, `port`) e o `service-netmiko` autentica nele com **usuário + senha**.

Na VM atual (`192.145.216.144`, gerenciada por EasyPanel) o bastion roda a imagem
`binlab/bastion` (compose em `/home/nocia/bastion/docker-compose.yml`), porta `22222→22`,
com autenticação **apenas por chave pública** (`PUBKEY_AUTHENTICATION=true`).

### Divergência que motivou esta decisão

O entrypoint do `binlab/bastion` sobe o `sshd` com `-o "PasswordAuthentication=no"`
**hardcoded** — não há variável de ambiente para habilitar senha, e o modelo da imagem é
todo baseado em chave (o usuário não tem senha). Logo, o código atual (que usa senha) **não
conseguiria autenticar** nesse bastion. Para o cliente teste, optou-se por **não** alterar o
código de aplicação; portanto trocamos a imagem por um OpenSSH configurado por nós, que
suporta senha nativamente.

## 2. Objetivo e escopo

Entregar um **pacote de deploy reproduzível** de um jump host SSH baseado em OpenSSH com
autenticação por senha, que:

- roda como container numa VM **dentro da rede do cliente** (com rota até os IPs privados);
- é alcançado pelo `service-netmiko` exatamente como os bastions atuais
  (`bastion_username` + `bastion_password`) → **zero mudança de código de aplicação**;
- permite **apenas TCP forwarding** (o túnel), **sem shell** e **sem privilégios**;
- é parametrizável por cliente (porta, usuário, senha, restrições de rede) via `.env`.

**Fora de escopo:** alterar `service-netmiko`, schema do banco, ou o EasyPanel/bastion da VM
atual. Este é um artefato novo e isolado, no diretório `bastion-deploy/`.

## 3. Decisões tomadas

| Decisão | Escolha | Motivo |
|---|---|---|
| Onde roda | VM/servidor na **rede do cliente** | Único lugar com rota até os IPs privados |
| Autenticação | **Senha** | Bate com o código/DB atuais → zero mudança de código |
| Imagem | **Custom (Alpine + OpenSSH)**, Dockerfile próprio | Controle total do `sshd_config`; hardening auditável |
| Allowlist de IP | **Incluída** no design | Bastion com senha exposto exige mitigação de brute force |

## 4. Arquitetura e fluxo

```
Kuanticks/Chatbot backend
   └─▶ service-netmiko (:4001)        [conecta com user+senha — igual hoje]
          └─▶ [SSH público :22222] ──▶ BASTION (container, VM na rede do cliente)
                                          │  sshd: só forwarding, sem shell, sem root
                                          └─▶ forwardOut() ──▶ equipamento (IP privado:22)
```

O `service-netmiko` abre no bastion um canal `direct-tcpip` (`forwardOut`) — **não pede
shell**. Por isso o shell do usuário pode ser bloqueado (`nologin`) sem quebrar o túnel.

## 5. Estrutura do pacote

```
bastion-deploy/
├── Dockerfile            # Alpine + openssh, mínimo
├── sshd_config           # config travado (núcleo do hardening)
├── entrypoint.sh         # gera/persiste host keys, cria user, aplica senha do env
├── docker-compose.yml    # sobe o serviço, lê parâmetros do .env
├── .env.example          # parâmetros por cliente (porta, user, senha)
├── README.md             # deploy no cliente + smoke test do túnel
└── docs/specs/           # este design
```

### 5.1 `Dockerfile` (esboço)

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache openssh-server shadow \
    && mkdir -p /etc/ssh/keys
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 5.2 `sshd_config` (núcleo do hardening)

```sshd_config
Port 2222
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AllowUsers bastion

AllowTcpForwarding yes            # permite o túnel (forwardOut)
PermitTunnel no
AllowAgentForwarding no
X11Forwarding no
GatewayPorts no

ClientAliveInterval 30
ClientAliveCountMax 3
MaxAuthTries 3
LoginGraceTime 20

# Host keys persistidos em volume (fingerprint estável):
HostKey /etc/ssh/keys/ssh_host_ed25519_key
HostKey /etc/ssh/keys/ssh_host_rsa_key

# Recomendado: restringir destinos do túnel à sub-rede do cliente.
# Definir conforme a rede de cada cliente, ex.:
# PermitOpen 192.168.0.0:22 10.0.0.0:22
```

O usuário `bastion` tem shell **`/usr/sbin/nologin`** → não obtém terminal, apenas tunela.

### 5.3 `entrypoint.sh` (responsabilidades)

1. Se não existirem host keys em `/etc/ssh/keys`, gerá-las (`ssh-keygen -A` apontando para o
   diretório persistido).
2. Criar o usuário `${BASTION_USER}` com shell `/usr/sbin/nologin` (idempotente).
3. Definir a senha do usuário a partir de `${BASTION_PASSWORD}` (via `chpasswd`).
4. `exec /usr/sbin/sshd -D -e`.

### 5.4 `docker-compose.yml`

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
      BASTION_PASSWORD: ${BASTION_PASSWORD:?defina no .env}
    volumes:
      - bastion_hostkeys:/etc/ssh/keys
volumes:
  bastion_hostkeys:
```

### 5.5 `.env.example`

```env
BASTION_PORT=22222
BASTION_USER=bastion
BASTION_PASSWORD=trocar-por-senha-forte
```

## 6. Pré-requisitos de rede (crítico)

Dois caminhos de rede precisam existir:

1. **service-netmiko → bastion:** a porta `${BASTION_PORT}` (22222) da VM do cliente
   precisa estar acessível de onde o `service-netmiko` roda (IP público + firewall liberado,
   ou VPN entre os dois).
2. **bastion → equipamento privado:** a VM do cliente precisa ter **rota até os IPs
   privados** (mesma LAN/VLAN ou roteamento). Container em rede bridge já alcança a LAN do
   host via NAT; basta a VM enxergar os equipamentos.

**Plano B de roteamento:** se a LAN exigir, usar `network_mode: host` no compose (o container
herda a rede da VM diretamente). Documentado no README.

## 7. Registro no app + teste ponta-a-ponta

Sem migração de banco. Fluxo de validação:

1. **Subir:** na VM do cliente, `cp .env.example .env`, preencher senha forte,
   `docker compose up -d --build`.
2. **Smoke test manual do túnel** (antes do app), do host do `service-netmiko`:
   ```bash
   ssh -p 22222 -N -L 2200:<IP_PRIVADO_EQUIP>:22 bastion@<IP_BASTION>
   # noutro terminal:
   ssh -p 2200 admin@127.0.0.1     # deve cair no equipamento
   ```
3. **Cadastrar na UI** (Kuanticks → gerenciamento de bastion): `public_ip` da VM,
   `username=bastion`, a senha, `port=22222`.
4. **Teste pelo app:** `POST /api/ssh/test-ssh` (ou botão "testar conexão") com
   `bastion_host/username/password` → esperar `{ success: true, via_bastion: true }`.
5. **Teste real:** rodar um comando num equipamento privado via Kuanticks e conferir a saída.

## 8. Segurança

Senha num bastion exposto é mais frágil que chave. Mitigações que fazem parte do design:

- **Senha forte** gerada (não reutilizar credenciais de outras máquinas).
- **Porta não-padrão** (22222) — reduz scan automático.
- **`MaxAuthTries 3` + `LoginGraceTime 20`** contra brute force.
- **Allowlist de IP** no firewall da VM do cliente — somente o IP do `service-netmiko`
  conecta na porta do bastion. Mitiga drasticamente brute force.
- **`PermitOpen`** restringindo o túnel à sub-rede dos equipamentos — impede o bastion virar
  pivô para a rede inteira.
- **Shell bloqueado** (`nologin`) e **sem root** (`PermitRootLogin no`).

## 9. Critérios de sucesso

- [ ] `docker compose up -d --build` sobe o bastion na VM do cliente.
- [ ] Smoke test manual do túnel chega no equipamento privado.
- [ ] `POST /api/ssh/test-ssh` retorna `success: true, via_bastion: true`.
- [ ] Um comando real via Kuanticks retorna saída do equipamento.
- [ ] Tentar abrir shell no bastion (`ssh bastion@host`) é **negado** (sem terminal).
- [ ] O pacote sobe noutra VM idêntica apenas alterando o `.env`.

## 10. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Brute force na senha (porta exposta) | Allowlist de IP + `MaxAuthTries` + senha forte |
| VM do cliente sem rota até os IPs privados | Validar pré-requisito de rede **antes** do deploy; smoke test manual (passo 7.2) |
| Bastion usado como pivô para a rede | `PermitOpen` restrito à sub-rede dos equipamentos |
| `forwardOut` falhar por shell bloqueado | Confirmado: `direct-tcpip` não exige shell; `nologin` é seguro |
| Fingerprint mudar a cada restart | Host keys persistidas em volume `bastion_hostkeys` |
```
