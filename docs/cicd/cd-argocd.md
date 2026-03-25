# CD 파이프라인 - ArgoCD (GitOps)

## GitOps 개념

ArgoCD는 **Git을 단일 진실 공급원(Single Source of Truth)** 으로 사용합니다.
Jenkins가 `values.yaml`에 이미지 태그를 커밋하면, ArgoCD가 이를 감지해 K8s에 자동 반영합니다.

```
Helm Chart Repo (Git)
      │
      │  Jenkins가 values.yaml 업데이트
      │
      ▼
  [ArgoCD]  ←── 주기적 Git 폴링 (기본 3분) or Webhook
      │
      ▼ sync
  [Kubernetes]  ←── 실제 Deployment, Service, ConfigMap 등 적용
```

---

## ArgoCD 설치 (Helm)

```bash
# ArgoCD 네임스페이스 생성
kubectl create namespace argocd

# 공식 Helm Chart 설치
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=LoadBalancer
```

### 초기 비밀번호 확인

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### ArgoCD CLI 설치

```bash
brew install argocd
argocd login <argocd-server-url>
```

---

## ArgoCD Application 등록

### YAML 방식 (권장)

```yaml
# argocd-app-springboot.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: springboot-app
  namespace: argocd
spec:
  project: default

  source:
    repoURL: https://bitbucket.org/myorg/helm-charts.git
    targetRevision: main
    path: charts/springboot-app          # Helm chart 경로
    helm:
      valueFiles:
        - values.yaml
        - values-prod.yaml               # 환경별 오버라이드

  destination:
    server: https://kubernetes.default.svc
    namespace: app

  syncPolicy:
    automated:
      prune: true        # Git에서 삭제된 리소스 K8s에서도 삭제
      selfHeal: true     # K8s 수동 변경 시 자동 원복
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f argocd-app-springboot.yaml
```

### CLI 방식

```bash
argocd app create springboot-app \
  --repo https://bitbucket.org/myorg/helm-charts.git \
  --path charts/springboot-app \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace app \
  --helm-set image.tag=latest \
  --sync-policy automated
```

---

## Bitbucket Webhook으로 ArgoCD 즉시 동기화

기본 폴링 주기(3분) 대신 Webhook으로 즉시 반영합니다.

### ArgoCD Webhook 엔드포인트

```
https://<argocd-server>/api/webhook
```

### Bitbucket Webhook 설정

1. Helm 차트 저장소 → **Settings → Webhooks**
2. URL: `https://argocd.example.com/api/webhook`
3. Secret: ArgoCD Webhook Secret 값 입력
4. Triggers: `push`

### ArgoCD Webhook Secret 설정

```bash
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"webhook.bitbucket.secret": "my-webhook-secret"}}'
```

---

## 멀티 환경 구성 (dev / staging / prod)

```
helm-charts/
├── charts/
│   └── springboot-app/
│       ├── Chart.yaml
│       ├── templates/
│       └── values.yaml          # 공통 기본값
├── envs/
│   ├── dev/values.yaml          # dev 오버라이드
│   ├── staging/values.yaml      # staging 오버라이드
│   └── prod/values.yaml         # prod 오버라이드
```

```yaml
# ArgoCD App - dev 환경
spec:
  source:
    repoURL: https://bitbucket.org/myorg/helm-charts.git
    path: charts/springboot-app
    helm:
      valueFiles:
        - values.yaml
        - ../../envs/dev/values.yaml
  destination:
    namespace: app-dev
```

---

## ArgoCD App of Apps 패턴 (다수 앱 관리)

```yaml
# parent-app.yaml  (모든 앱을 하나의 Application으로 관리)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: all-apps
  namespace: argocd
spec:
  source:
    repoURL: https://bitbucket.org/myorg/helm-charts.git
    path: argocd-apps          # 각 앱의 Application YAML이 있는 디렉터리
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```
argocd-apps/
├── springboot-app.yaml
├── kafka.yaml
├── airflow.yaml
├── spark.yaml
└── trino.yaml
```

---

## 롤백

### UI 롤백

ArgoCD UI → 앱 선택 → **History and Rollback** → 이전 버전 선택 → **Rollback**

### CLI 롤백

```bash
# 배포 이력 확인
argocd app history springboot-app

# 특정 revision으로 롤백
argocd app rollback springboot-app <revision-id>
```

---

## 주요 ArgoCD 상태

| 상태 | 의미 |
|------|------|
| `Synced` | Git과 K8s 상태 일치 |
| `OutOfSync` | Git 변경 감지, 동기화 대기 |
| `Healthy` | 모든 리소스 정상 |
| `Degraded` | Pod 오류 등 이상 상태 |
| `Progressing` | 배포 진행 중 |

---

## RBAC 설정 예시

```yaml
# argocd-rbac-cm ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    p, role:developer, applications, sync,    */*, allow
    p, role:developer, applications, get,     */*, allow
    p, role:ops,       applications, *,        */*, allow
    g, myteam:developers, role:developer
    g, myteam:ops,        role:ops
```
