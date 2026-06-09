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

    cp .env.example .env
    # editar .env: definir BASTION_PASSWORD forte, ajustar BASTION_PORT e
    # BASTION_PERMITOPEN conforme a rede do cliente.
    docker compose up -d --build
    docker compose logs --no-log-prefix bastion   # deve mostrar "Server listening on ..."

## Allowlist de firewall (recomendado)

Restringir a porta do bastion ao IP do `service-netmiko` reduz drasticamente
brute force. Ex. (ufw):

    sudo ufw allow from <IP_DO_SERVICE_NETMIKO> to any port <BASTION_PORT> proto tcp
    sudo ufw deny <BASTION_PORT>/tcp

## Smoke test do túnel (antes de cadastrar no app)

A partir do host do `service-netmiko`:

    # abre um túnel local 2200 -> <IP_PRIVADO>:22 através do bastion
    ssh -p <BASTION_PORT> -N -L 2200:<IP_PRIVADO_EQUIP>:22 bastion@<IP_BASTION>
    # em outro terminal: deve cair no equipamento
    ssh -p 2200 admin@127.0.0.1

Confirmar que **shell direto no bastion é negado**:

    ssh -p <BASTION_PORT> bastion@<IP_BASTION>
    # esperado: conexão aceita mas SEM shell (PTY negado / sessão encerra)

## Cadastro no app (Kuanticks → gerenciamento de bastion)

- `public_ip` = IP da VM do bastion
- `username`  = valor de `BASTION_USER` (default `bastion`)
- `password`  = valor de `BASTION_PASSWORD`
- `port`      = valor de `BASTION_PORT`

## Plano B de roteamento

Se a LAN exigir, trocar a seção `ports`/rede por `network_mode: host` no
`docker-compose.yml` (o container herda a rede da VM diretamente).
