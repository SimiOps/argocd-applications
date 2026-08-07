# vuln-lab

Workloads descartáveis que enchem o Vulnerability Management da Sysdig com dados
reais, dimensionados para um cluster de **1 node / 4GB RAM / 2 cores**.

O event-generator resolve Threat Detection porque eventos são baratos: um syscall
e pronto. VM é o oposto — o dado só existe se houver uma imagem de verdade, com
um SBOM de verdade, presente no cluster. Este repo resolve isso com 24 imagens
públicas notoriamente vulneráveis rodando **ociosas**.

## A ideia central

O scanner do Sysdig analisa o **filesystem da imagem**, não o processo em
execução. Um container que só dorme produz exatamente o mesmo resultado de
Vulnerability Management que a aplicação rodando de verdade — com ~5MB de RSS em
vez de centenas de MB.

Por isso todo Deployment aqui sobrescreve o entrypoint:

```yaml
command: ["/bin/sh", "-c", "while :; do sleep 3600; done"]
```

Custo total com os 3 primeiros tiers ligados: **~190MB de RAM** e **~1.6GB de
disco**. O gargalo é disco, não memória.

> `sleep infinity` não funciona no busybox das imagens mais antigas (o applet só
> aceita argumento numérico). O loop acima roda em qualquer `/bin/sh`.

## Estrutura no repo

```
argocd-applications/
├── root-application/
│   ├── application.yaml          # + bloco da Application vuln-lab no final
│   └── kustomization.yaml         (inalterado)
├── sysdig-agent/
│   ├── values.yaml               # merge de values-vm-patch.yaml aqui
│   └── values-vm-patch.yaml      # as chaves de VM do chart shield
└── vuln-lab/
    ├── manifests/
    │   ├── kustomization.yaml    # <- é aqui que você liga/desliga tiers
    │   ├── namespace.yaml        # Namespace + ResourceQuota
    │   ├── priorityclass.yaml    # prioridade negativa
    │   ├── tier0-eol-distros.yaml        # 7 workloads  ~465MB disco
    │   ├── tier1-language-runtimes.yaml  # 7 workloads  ~585MB
    │   ├── tier2-services.yaml           # 7 workloads  ~600MB
    │   └── tier3-kev-showcase.yaml       # 3 workloads  ~1.1GB (opt-in)
    └── hack/
        ├── images.txt            # catálogo — a fonte da verdade
        └── gen-workloads.sh      # regenera os manifests
```

Os arquivos de tier são **gerados**. Para mudar o conjunto de imagens, edite
`hack/images.txt` e rode `./hack/gen-workloads.sh`.

## Instalação

```bash
cp -r vuln-lab/ /caminho/do/seu/clone/
cp sysdig-agent/values-vm-patch.yaml /caminho/do/seu/clone/sysdig-agent/
# aplique o bloco vuln-lab no final de root-application/application.yaml
git add . && git commit -m "add vuln-lab" && git push
```

### Ative o scanning de containers

Isto não é opcional. O shield **não faz VM de container por default** — sem as
chaves abaixo o lab sobe 24 pods e a UI continua vazia. Faça o merge de
`sysdig-agent/values-vm-patch.yaml` no seu `values.yaml`:

```yaml
features:
  vulnerability_management:
    container_vulnerability_management:
      enabled: true
      target_workloads:
        kubernetes:
          enabled: true
          image_source: node      # <- leia a próxima seção
    host_vulnerability_management:
      enabled: true
```

### `image_source: node` — a pegadinha que vai te custar tempo

O default do chart é `registry`, que faz o Sysdig **baixar cada imagem de novo**
do Docker Hub só para escanear. No seu caso: 24 pulls extras, ~1.6GB de tráfego.
E pull anônimo no Docker Hub tem limite de 100 por 6h por IP — você bate o teto e
os scans falham com `429 TooManyRequests`, sem mensagem clara na UI.

Com `node`, o host shield lê as imagens do containerd local, que já as tem. Zero
tráfego extra, zero rate limit. Para um homelab é sempre a escolha certa.

### Cache do raw.githubusercontent

Seu Application do shield lê o values por URL raw do GitHub. O CDN do GitHub
cacheia isso por alguns minutos, então depois do push o Argo pode sincronizar
ainda com o values velho. Se o patch parecer não ter surtido efeito, espere ~5min
e force um refresh:

```bash
argocd app get sysdig-agent --hard-refresh
```

## Rollout num node pequeno

Ligue **um tier por vez**. Comece só com o tier0 no `kustomization.yaml`,
confirme os dados na Sysdig, e vá descomentando.

Os tiers têm `argocd.argoproj.io/sync-wave` de 1 a 4, então o Argo aplica um por
vez em vez de disparar 24 pulls simultâneos — o que num node com 2 cores satura o
disco e faz o kubelet reportar `DiskPressure`.

Duas proteções para o shield:

- **`PriorityClass` de valor -10.** Sob pressão de memória o kubelet despeja os
  pods do lab antes do sysdig-agent, do argocd e do voting app.
  `preemptionPolicy: Never` garante que o lab nunca expulse ninguém.
- **`ResourceQuota` no namespace.** Se você adicionar imagens demais, o
  agendamento falha em vez do node cair.

## Cuidado com o image GC do kubelet

Este é o problema que provavelmente vai te morder primeiro. O kubelet apaga
imagens não usadas quando o disco passa de `imageGCHighThresholdPercent` (default
85%). Com ~1.6GB de imagens paradas somadas ao voting app, cert-manager e shield,
isso pode entrar num ciclo de apagar e re-baixar — e o dado de VM some da UI
junto.

```bash
df -h /var/lib/containerd
```

Se estiver acima de ~70% com o lab ligado, mantenha só tier0 e tier2, ou suba o
threshold:

```yaml
# /var/lib/kubelet/config.yaml
imageGCHighThresholdPercent: 90
imageGCLowThresholdPercent: 85
```

## O que cada tier te dá

| Tier | Conteúdo | Serve para |
|---|---|---|
| 0 | debian 8/9, ubuntu 14.04/16.04, alpine 3.9, centos 7, amazonlinux 2018 | Volume bruto de CVEs de OS. Centenas de findings por imagem, várias famílias de pacote (deb, rpm, apk). |
| 1 | python 3.6, node 8/12, ruby 2.5, php 7.2, go 1.13, openjdk 8u212 | CVEs de app-level e de biblioteca. Melhor para testar filtros por tipo de pacote. |
| 2 | nginx 1.14, httpd 2.4.38, redis 5.0.3, postgres 9.6, mysql 5.6, tomcat 8.5.32, haproxy 1.8.8 | CVEs nomeados e reconhecíveis (Ghostcat, HTTP smuggling). Bom para demo com narrativa. |
| 3 | log4shell app, struts2 CVE-2017-5638, DVWA | CVEs na **CISA KEV**. É o que popula os filtros de risco — "Actually Exploitable", scores de EPSS, políticas de aceite de risco. |

Se o objetivo é testar priorização de risco e não só volume, o tier3 é o mais
valioso dos quatro, apesar de ser o mais pesado.

## Verificação

```bash
kubectl -n vuln-lab get pods -o wide
kubectl -n vuln-lab describe quota vuln-lab-quota
kubectl top pods -n vuln-lab                    # confirme o consumo real

# o host shield esta escaneando?
kubectl -n sysdig-agent get pods
kubectl -n sysdig-agent logs -l app.kubernetes.io/component=host --tail=100 | grep -i -E 'scan|sbom|vuln'
```

Na UI: **Vulnerabilities > Runtime**, filtre por `kube_namespace_name = vuln-lab`.
Com `image_source: node` o primeiro ciclo leva alguns minutos por imagem; num
node de 2 cores conte ~15-20 minutos para os 24 workloads aparecerem.

Se um pod ficar em `CrashLoopBackOff`, quase sempre é imagem sem `/bin/sh` no
path esperado. Confira com `kubectl -n vuln-lab logs <pod>` e ajuste ou remova a
linha em `hack/images.txt`.

## Limitação conhecida

Container ocioso não carrega bibliotecas, então o campo **"In Use"** (Risk
Spotlight) fica vazio ou muito pobre para estes workloads. Os CVEs aparecem
todos, mas sem a marcação de pacote efetivamente carregado em runtime. Seu voting
app cobre esse caso melhor, já que roda de verdade.

Se precisar testar o filtro "In Use" com CVEs graves, o tier3 é o candidato para
rodar com entrypoint real — essas imagens sobem serviços HTTP que exercitam boa
parte das libs vulneráveis. Remova o `command:` do Deployment correspondente e
suba os limits para ~512Mi.
