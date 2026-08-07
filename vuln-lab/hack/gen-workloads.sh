#!/usr/bin/env bash
# Gera os manifests de workload a partir de hack/images.txt.
# Uso:  ./hack/gen-workloads.sh
#
# Cada imagem vira um Deployment de 1 replica que apenas dorme.
# O runtime scanner do Sysdig analisa o filesystem da imagem, nao o processo,
# entao um container ocioso produz o mesmo resultado de VM que a app real
# — com ~5MB de RSS em vez de centenas.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/manifests"
SRC="${ROOT}/hack/images.txt"

declare -A TIER_NAME=(
  [0]="tier0-eol-distros"
  [1]="tier1-language-runtimes"
  [2]="tier2-services"
  [3]="tier3-kev-showcase"
)
declare -A TIER_DESC=(
  [0]="Distros EOL — base de CVEs de sistema operacional"
  [1]="Runtimes de linguagem — CVEs de app-level e bibliotecas"
  [2]="Servicos e app servers — CVEs nomeados e conhecidos"
  [3]="Showcase CISA KEV / actually exploitable (opt-in, mais pesado)"
)
# sync-wave por tier: o Argo aplica um tier por vez, escalonando os image pulls
declare -A TIER_WAVE=([0]=1 [1]=2 [2]=3 [3]=4)

for t in 0 1 2 3; do
  f="${OUT}/${TIER_NAME[$t]}.yaml"
  {
    echo "# GERADO POR hack/gen-workloads.sh — NAO EDITE A MAO."
    echo "# Fonte: hack/images.txt   |   Tier ${t}: ${TIER_DESC[$t]}"
  } > "$f"
done

while IFS='|' read -r tier name image disk note; do
  [[ -z "${tier// }" || "${tier:0:1}" == "#" ]] && continue
  f="${OUT}/${TIER_NAME[$tier]}.yaml"
  cat >> "$f" <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/name: ${name}
    app.kubernetes.io/part-of: vuln-lab
    vuln-lab/tier: "${tier}"
  annotations:
    argocd.argoproj.io/sync-wave: "${TIER_WAVE[$tier]}"
    vuln-lab/image-size: "${disk}"
    vuln-lab/note: "${note}"
spec:
  replicas: 1
  revisionHistoryLimit: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: ${name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${name}
        app.kubernetes.io/part-of: vuln-lab
        vuln-lab/tier: "${tier}"
    spec:
      priorityClassName: vuln-lab-low
      terminationGracePeriodSeconds: 1
      automountServiceAccountToken: false
      enableServiceLinks: false
      containers:
        - name: idle
          image: ${image}
          imagePullPolicy: IfNotPresent
          # 'sleep infinity' nao existe no busybox de imagens antigas; este loop
          # funciona em qualquer /bin/sh (glibc, musl, dash).
          command: ["/bin/sh", "-c", "while :; do sleep 3600; done"]
          resources:
            requests:
              cpu: 1m
              memory: 8Mi
            limits:
              cpu: 50m
              memory: 48Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF
done < "$SRC"

echo "Manifests regenerados em ${OUT}:"
for t in 0 1 2 3; do
  n=$(grep -c '^kind: Deployment' "${OUT}/${TIER_NAME[$t]}.yaml" || true)
  printf '  %-28s %s workloads\n' "${TIER_NAME[$t]}.yaml" "$n"
done
