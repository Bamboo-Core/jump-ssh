# Bastion Deploy — jump host SSH containerizado

Jump host SSH (OpenSSH em container) para o `service-netmiko` alcançar
equipamentos em IPs privados. Autenticação por **senha**, somente **TCP
forwarding** (sem shell, sem root).

## Pré-requisitos de rede (críticos)

1. **service-netmiko → bastion:** a porta `BASTION_PORT` da VM precisa estar
   acessível de onde o `service-netmiko` roda (IP público + firewall, ou VPN).
2. **bastion → equipamento:** a VM precisa ter **rota até os IPs privados**
   (mesma LAN/VLAN ou roteamento).

### ⚠️ Colisão de sub-rede do Docker (causa comum de "No route to host")

O Docker cria bridges auto-atribuindo sub-redes do seu pool padrão
(`172.17.0.0/16`, `172.18…`, `172.19…`, …). Se **alguma bridge do Docker cair na
mesma faixa que a rede de gerência do cliente** (ex.: cliente em `172.19.x`), o
host passa a tratar essa faixa como bridge **local** — e o bastion **nunca roteia
até o device real** (ARP na bridge → *"No route to host"*), mesmo com a VPN certa.
Foi exatamente isso que quebrou um cliente em `172.19.x`.

**Fix host-level (PRIMÁRIO — vale para deploy via imagem E via compose):** fixe o
pool do Docker fora das faixas RFC1918 dos clientes. Em `/etc/docker/daemon.json`:

```json
{ "default-address-pools": [ { "base": "100.64.0.0/10", "size": 24 } ] }
```

Depois, **numa janela de manutenção** (isto recria as bridges e reinicia os
containers da VM):

```bash
sudo systemctl restart docker
# recrie as stacks/containers da VM (docker run/compose up) para pegarem a nova faixa
```

`100.64.0.0/10` é espaço CGNAT (RFC 6598), praticamente nunca usado em LAN de
device — confirme que **nenhum cliente** dessa VM o utiliza antes de aplicar.

> Correção sem bounce (paliativo, por-cliente): uma rota **mais específica** vence
> a `/16` do Docker, ex.: `sudo ip route add 172.19.0.0/24 via <gw-vpn> dev <if-vpn>`.
> Resolve na hora sem reiniciar nada, mas não é durável (some no restart e não vale
> se o container estiver NA faixa colidida — nesse caso só o fix acima resolve).

**Defesa em profundidade (deploy via compose):** o `docker-compose.yml` já pina a
rede do bastion via `BASTION_NET_SUBNET` (default `100.64.250.0/24`). Isso protege
a rede DO bastion, mas **não** impede outra stack da mesma VM de pegar a faixa do
cliente — por isso o fix host-level acima é o que resolve de vez.

## Deploy via imagem publicada (recomendado)

A imagem é publicada automaticamente no GHCR em `ghcr.io/bamboo-core/bastion`.
No cliente, basta um `docker run` (não precisa clonar o repo nem buildar):

    docker run -d --name bastion --restart unless-stopped \
      -p 22222:2222 \
      -e BASTION_PASSWORD='<senha-forte>' \
      -v bastion_hostkeys:/etc/ssh/keys \
      ghcr.io/bamboo-core/bastion:latest

    docker logs bastion        # deve mostrar "Server listening on ... port 2222"

Esse é o modo **múltiplos equipamentos** (padrão): sem `BASTION_PERMITOPEN`, o
bastion tunela para **qualquer IP que a VM enxergar** na rede do cliente — é o
modelo clássico de jump host. A segurança vem da **allowlist de firewall**
(ver seção abaixo): só o IP do `service-netmiko` pode conectar no bastion.

Variáveis de ambiente aceitas:

| Var | Default | Descrição |
|---|---|---|
| `BASTION_PASSWORD` | (obrigatória) | senha do usuário do bastion (= a cadastrada no Kuanticks) |
| `BASTION_USER` | `bastion` | usuário usado pelo `service-netmiko` |
| `BASTION_PERMITOPEN` | (vazio = qualquer destino) | **opcional**; restringe o túnel a `host:port` **literais** (NÃO aceita CIDR/sub-rede), separados por espaço. Use só quando o conjunto de equipamentos é pequeno e fixo. |

> A porta interna é sempre `2222`; mapeie a externa que quiser (`-p 22222:2222`).
> O volume `bastion_hostkeys` mantém as host keys estáveis entre restarts.
> **Para vários equipamentos / rede inteira:** omita `BASTION_PERMITOPEN` (como
> no comando acima) e proteja o acesso pela allowlist de firewall.

## Deploy via build local (alternativa)

Se preferir buildar a partir do código (sem usar a imagem publicada):

    cp .env.example .env
    # editar .env: definir BASTION_PASSWORD forte, ajustar BASTION_PORT e
    # BASTION_PERMITOPEN conforme a rede do cliente.
    docker compose up -d --build
    docker compose logs --no-log-prefix bastion   # deve mostrar "Server listening on ..."

## Publicação da imagem (mantenedores)

O workflow `.github/workflows/publicar-imagem.yml` builda e publica no GHCR a
cada push na `main` e a cada tag `v*`. Para uma release versionada:

    git tag v1.0.0 && git push origin v1.0.0
    # publica ghcr.io/bamboo-core/bastion:v1.0.0 + :latest

## Allowlist de firewall (ESSENCIAL no modo múltiplos equipamentos)

Sem `BASTION_PERMITOPEN`, o bastion tunela para qualquer host da rede interna —
então a proteção passa a ser **quem consegue conectar nele**. Restrinja a porta
do bastion **apenas ao IP do `service-netmiko`**. Ex. (ufw):

    sudo ufw allow from <IP_DO_SERVICE_NETMIKO> to any port <BASTION_PORT> proto tcp
    sudo ufw deny <BASTION_PORT>/tcp

Resultado: ninguém de fora alcança o bastion; só o `service-netmiko`
(autenticado com a senha) entra, e a partir dele chega-se a todos os
equipamentos da rede. Demais camadas ativas: senha forte, `MaxAuthTries 3`,
sem shell, sem root.

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
