# Remediação dos bastions — pendências (2026-07-21)

Runbook das correções de rede que faltam nos bastions, a partir do diagnóstico feito ao vivo em
2026-07-21. **Nada aqui altera código/imagem** — é operação nas VMs (+ merge do PR que previne o
problema em instalações novas). Cada item foi confirmado testando o alcance bastion→device.

## Contexto (o que quebrou e por quê)

O `service-netmiko` entra no bastion e pede pra encaminhar até o IP do equipamento. Se o bastion
**não rotear** até esse IP, a conexão pendura e a coleta da correlação dá timeout. Dois casos
quebrados, por motivos diferentes; um terceiro bastion serve de referência do que é "saudável".

| Bastion | VM | Situação | Causa |
|---|---|---|---|
| **Powerserv** | `45.5.72.32` | ✅ OK (referência) | alcança os devices (`10.200.64.x`) pela rede real |
| **Wlan** | `167.249.209.18` (BBC-VSS-05-VBGP) | ❌ PONTOCOM `172.19.x` inalcançável | **bridge do Docker colidiu com a faixa do cliente** |
| **RFS** | `192.145.216.140` (proxy-athos) | ❌ `10.254.x` inalcançável | **sem VPN/rota** até a rede dos equipamentos |

---

## 1. Wlan — colisão de sub-rede do Docker (PONTOCOM `172.19.x`)

**Diagnóstico (confirmado na VM `167.249.209.18`):**
- O Docker criou a bridge `br-eaaa16351eba` em `172.19.0.0/16` — a **mesma faixa** dos switches do
  PONTOCOM (`172.19.0.240–253`). O kernel manda `172.19.x` pra bridge local → `No route to host`.
- A VPN do cliente está em `ens192` (`10.52.52.6/29`), com rotas para os OUTROS clientes
  (`172.16.5.0/24`, `172.16.7.0/24`, `172.20.1.0/24` via `10.52.52.1`) — esses funcionam. **Faltava
  rota para `172.19.x`**, e o Docker ainda estava sombreando a faixa.

**Passo 0 — confirmar onde está o container do bastion (decide se dá fix rápido):**
```bash
sudo docker ps --format '{{.Names}}\t{{.Networks}}'
sudo docker network inspect $(sudo docker network ls -q) | grep -E 'Name|Subnet'
```
- Se o container do bastion **estiver na bridge `172.19.x`** → rota estática NÃO resolve (ele trata a
  faixa como local). Vá direto pro fix durável (Passo 2).
- Se estiver em outra bridge (ex.: `172.18.x`) → o fix rápido (Passo 1) já resolve.

**Passo 1 — fix rápido, sem downtime (paliativo):**
```bash
sudo ip route add 172.19.0.0/24 via 10.52.52.1 dev ens192
```
Uma rota `/24` vence a `/16` do Docker. Testar em seguida (ver "Validação"). **Não é durável** — some
no restart e não vale se o container estiver na faixa colidida.

**Passo 2 — fix durável (janela de manutenção; recria bridges e reinicia containers da VM):**
Tirar o Docker das faixas de cliente. Em `/etc/docker/daemon.json`:
```json
{ "default-address-pools": [ { "base": "100.64.0.0/10", "size": 24 } ] }
```
```bash
sudo systemctl restart docker
# recriar as stacks/containers da VM (docker run/compose up) para pegarem a nova faixa
```
- `100.64.0.0/10` é espaço CGNAT (RFC 6598), praticamente nunca usado em LAN de device — **confirme
  que nenhum cliente dessa VM o utiliza** antes de aplicar.
- Depois de liberar o `172.19` do Docker, **garantir a rota da VPN** (persistente):
  `172.19.0.0/24 via 10.52.52.1 dev ens192` (como os outros clientes já têm).

---

## 2. RFS — bastion sem conexão com a rede dos equipamentos (`10.254.x`)

**Diagnóstico (confirmado na VM `192.145.216.140` / proxy-athos):**
- A VM só tem `vlan3302` (`/29` público) + bridges do Docker (`172.17`, `172.18`). **Nenhuma
  VPN/túnel** para a rede interna do cliente. `ip route get 10.254.0.4` cai no gateway default
  (internet), que não entrega → inalcançável.

**Fix:** estabelecer a **VPN/rota** do bastion do RFS até `10.254.x` — o equivalente ao que o bastion
do Wlan tem (`ens192`/`10.52.52.x`). Sem esse enlace, os equipamentos privados do RFS não são
alcançados. (Não é colisão de Docker — é conectividade que nunca existiu nessa VM.)

---

## 3. Prevenção em instalações novas — PR no `jump-ssh`

- **Mesclar o PR `fix/bastion-subnet-pin`** (Bamboo-Core/jump-ssh#1): pina a rede do container em
  `100.64.250.0/24` no `docker-compose.yml` (via `BASTION_NET_SUBNET`) e documenta o `daemon.json`.
  Impede o Docker de roubar faixa de cliente em **instalações novas** — **não** conserta as VMs
  atuais (por isso os passos 1 e 2 acima).

---

## 4. Fora do bastion, mas trava a coleta

- **Athos:** 0 credenciais SSH cadastradas → a correlação nunca coleta nesse tenant. Cadastrar as
  credenciais dos equipamentos (independe de bastion).

---

## Validação (rodar após cada fix)

Usar a própria ferramenta da plataforma (ping/traceroute via bastion), o mesmo endpoint do botão de
"testar conexão" ao criar/editar host: `POST <SERVICE_NETMIKO_URL>/api/ssh/reachability` com o IP do
device + os dados do bastion. Esperado após o fix: `tcp.ok: true` (device responde). Alternativa
direta na VM do bastion:
```bash
timeout 5 bash -c 'cat </dev/null >/dev/tcp/<IP_DO_DEVICE>/<PORTA>' && echo OK || echo INALCANCAVEL
```
Devices de referência usados no diagnóstico: Wlan/PONTOCOM `172.19.0.251:5858`; RFS `10.254.0.4:22`.

## Referência do diagnóstico

- Wlan: `ip -br addr`/`ip route` na VM mostraram `br-eaaa16351eba 172.19.0.1/16` (Docker) sombreando
  a faixa; reachability via bastion deu `Porta 5858/tcp inacessível (via bastion)` (timeout 60s).
- RFS: VM sem interface/rota para `10.254.x`; reachability via bastion idem.
- Powerserv: reachability `tcp.ok: true` em 211ms (referência do que é saudável).
- Histórico de produção confirma que a coleta funciona pra maioria (RFS 337 comandos, Wlan 38) — só
  esses subconjuntos de rede estão quebrados.
