# Kubernetes 핵심 가이드

## 1. 아키텍처 개요

```
┌──────────────────────────── Control Plane ──────────────────────────────┐
│                                                                          │
│   ┌─────────────────┐   ┌──────┐   ┌──────────────┐   ┌─────────────┐  │
│   │  kube-apiserver │   │ etcd │   │  kube-       │   │   kube-     │  │
│   │  (API 진입점)    │   │(DB)  │   │  scheduler   │   │  controller │  │
│   └─────────────────┘   └──────┘   └──────────────┘   └─────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
                │
     ┌──────────┼──────────┐
     │          │          │
┌────▼────┐ ┌───▼────┐ ┌───▼────┐   Worker Nodes
│ kubelet │ │kubelet │ │kubelet │
│kube-proxy│ │kube-proxy│ │kube-proxy│
│ Pods    │ │ Pods   │ │ Pods   │
└─────────┘ └────────┘ └────────┘
```

| 구성요소 | 위치 | 역할 |
|---|---|---|
| **kube-apiserver** | Control Plane | 모든 API 요청의 진입점. kubectl 통신 대상 |
| **etcd** | Control Plane | 클러스터 상태 저장 분산 KV DB |
| **kube-scheduler** | Control Plane | Pod를 어느 노드에 배치할지 결정 |
| **kube-controller-manager** | Control Plane | Deployment/ReplicaSet 등 상태 조정 루프 |
| **kubelet** | Worker Node | 노드에서 Pod 실행/상태 관리 |
| **kube-proxy** | Worker Node | 네트워크 규칙 관리, Service 트래픽 라우팅 |

---

## 2. 핵심 오브젝트 YAML 예시

### Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
  namespace: default
  labels:
    app: my-app
spec:
  containers:
    - name: app
      image: nginx:1.25
      ports:
        - containerPort: 80
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
```

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # 최대 초과 Pod 수
      maxUnavailable: 0  # 최대 불가용 Pod 수
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: app
          image: my-app:1.0.0
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: my-config
            - secretRef:
                name: my-secret
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
      terminationGracePeriodSeconds: 30
```

### Service

```yaml
# ClusterIP - 클러스터 내부 통신
apiVersion: v1
kind: Service
metadata:
  name: my-app-svc
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080

---
# NodePort - 외부 접근 (테스트용)
apiVersion: v1
kind: Service
metadata:
  name: my-app-nodeport
spec:
  type: NodePort
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 30080    # 30000~32767 범위

---
# LoadBalancer - 클라우드 환경 외부 노출
apiVersion: v1
kind: Service
metadata:
  name: my-app-lb
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

### Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - myapp.example.com
      secretName: tls-secret
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-svc
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-svc
                port:
                  number: 80
```

### ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-config
data:
  APP_ENV: "production"
  LOG_LEVEL: "info"
  DATABASE_HOST: "postgres-svc"
  config.yaml: |
    server:
      port: 8080
      timeout: 30s
```

### Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
type: Opaque
stringData:           # 평문 입력 (자동으로 base64 인코딩)
  DATABASE_PASSWORD: "supersecret"
  API_KEY: "my-api-key"
```

> Secret은 base64 인코딩이지 암호화가 아닙니다. 프로덕션에서는 Vault, AWS Secrets Manager, Sealed Secrets 사용을 권장합니다.

### PersistentVolume / PersistentVolumeClaim

```yaml
# PersistentVolume (관리자가 생성)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce      # RWO: 단일 노드 읽기/쓰기
    # ReadOnlyMany       # ROX: 다수 노드 읽기 전용
    # ReadWriteMany      # RWX: 다수 노드 읽기/쓰기 (NFS 등)
  reclaimPolicy: Retain  # Delete | Recycle | Retain
  storageClassName: standard
  hostPath:
    path: /data/my-pv

---
# PersistentVolumeClaim (개발자가 생성)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: standard
```

```yaml
# PVC를 Pod에 마운트
spec:
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: my-pvc
  containers:
    - name: app
      volumeMounts:
        - mountPath: /data
          name: data
```

---

## 3. kubectl 명령어 모음

### 조회

```bash
# 기본 조회
kubectl get pods
kubectl get pods -n kube-system        # 특정 네임스페이스
kubectl get pods -A                    # 전체 네임스페이스
kubectl get pods -o wide               # 노드 정보 포함
kubectl get pods -o yaml               # YAML 전체 출력
kubectl get pods -w                    # 실시간 감시 (watch)

# 상세 조회
kubectl describe pod <pod-name>
kubectl describe node <node-name>

# 여러 리소스 동시 조회
kubectl get pod,svc,ingress -n my-ns

# 레이블 필터
kubectl get pods -l app=my-app
kubectl get pods --field-selector=status.phase=Running
```

### 생성 / 수정 / 삭제

```bash
# 생성 및 적용
kubectl apply -f deployment.yaml
kubectl apply -f ./k8s/            # 디렉토리 전체 적용

# 즉시 생성 (YAML 없이)
kubectl create deployment my-app --image=nginx:1.25 --replicas=3
kubectl expose deployment my-app --port=80 --type=ClusterIP

# 수정
kubectl edit deployment my-app     # 에디터 열어서 직접 수정
kubectl set image deployment/my-app app=nginx:1.26   # 이미지 업데이트
kubectl scale deployment my-app --replicas=5

# 삭제
kubectl delete pod <pod-name>
kubectl delete -f deployment.yaml
kubectl delete deployment,svc my-app   # 여러 리소스 동시 삭제
```

### 로그 / 디버깅

```bash
# 로그
kubectl logs <pod-name>
kubectl logs <pod-name> -c <container-name>   # 멀티 컨테이너
kubectl logs <pod-name> -f                    # 실시간 스트림
kubectl logs <pod-name> --previous            # 이전 컨테이너 로그
kubectl logs -l app=my-app --tail=100         # 레이블로 묶어서

# 컨테이너 접속
kubectl exec -it <pod-name> -- /bin/bash
kubectl exec -it <pod-name> -c <container> -- sh

# 포트 포워딩 (로컬 테스트용)
kubectl port-forward pod/<pod-name> 8080:8080
kubectl port-forward svc/<svc-name> 8080:80

# 임시 디버그 Pod 실행
kubectl run debug --image=busybox --rm -it --restart=Never -- sh

# 이벤트 확인
kubectl get events --sort-by=.metadata.creationTimestamp
kubectl get events -n my-ns --field-selector=type=Warning
```

### 롤아웃 관리

```bash
# 배포 상태 확인
kubectl rollout status deployment/my-app

# 롤아웃 히스토리
kubectl rollout history deployment/my-app
kubectl rollout history deployment/my-app --revision=2

# 롤백
kubectl rollout undo deployment/my-app
kubectl rollout undo deployment/my-app --to-revision=2

# 배포 일시 중지 / 재개
kubectl rollout pause deployment/my-app
kubectl rollout resume deployment/my-app
```

### 리소스 사용량

```bash
kubectl top nodes
kubectl top pods
kubectl top pods -n my-ns --sort-by=memory
```

---

## 4. Namespace 관리

```bash
# Namespace 생성
kubectl create namespace my-ns

# 기본 Namespace 설정 (컨텍스트에 저장)
kubectl config set-context --current --namespace=my-ns
```

### ResourceQuota - 네임스페이스 리소스 제한

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: my-ns-quota
  namespace: my-ns
spec:
  hard:
    pods: "20"
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    persistentvolumeclaims: "10"
```

### LimitRange - Pod 기본값 설정

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: my-ns-limits
  namespace: my-ns
spec:
  limits:
    - type: Container
      default:          # limits 미설정 시 자동 적용
        cpu: "500m"
        memory: "256Mi"
      defaultRequest:   # requests 미설정 시 자동 적용
        cpu: "100m"
        memory: "128Mi"
      max:
        cpu: "2"
        memory: "1Gi"
      min:
        cpu: "50m"
        memory: "64Mi"
```

---

## 5. 리소스 요청 / 제한 (Requests / Limits)

```yaml
resources:
  requests:
    cpu: "200m"       # 0.2 코어 (예약 보장)
    memory: "256Mi"
  limits:
    cpu: "1"          # 1 코어 (초과 시 스로틀)
    memory: "512Mi"   # 초과 시 OOMKilled
```

### 단위 정리

| 리소스 | 단위 | 예시 |
|---|---|---|
| CPU | 1 = 1 코어, 1000m = 1 코어 | `500m` = 0.5 코어 |
| Memory | Ki, Mi, Gi | `256Mi` = 268MB |

### QoS 클래스

| QoS | 조건 | 특징 |
|---|---|---|
| **Guaranteed** | requests == limits 모두 설정 | 메모리 부족 시 마지막으로 종료 |
| **Burstable** | requests < limits | 중간 우선순위 |
| **BestEffort** | requests/limits 미설정 | 가장 먼저 종료됨 |

---

## 6. Health Check (Probe)

### 3종 Probe 비교

| Probe | 실패 시 동작 | 용도 |
|---|---|---|
| **livenessProbe** | 컨테이너 재시작 | 데드락, 무한 루프 감지 |
| **readinessProbe** | Service 트래픽 차단 | 초기화 완료 전 트래픽 차단 |
| **startupProbe** | 컨테이너 재시작 | 느린 시작 앱 보호 (liveness 일시 비활성) |

### 설정 예시

```yaml
containers:
  - name: app
    image: my-app:1.0
    startupProbe:                    # 시작 완료 확인 (liveness보다 먼저)
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30          # 30 * 10s = 최대 5분 대기
      periodSeconds: 10

    livenessProbe:                   # 생존 확인
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 0        # startupProbe 사용 시 0으로
      periodSeconds: 10
      failureThreshold: 3           # 3회 실패 시 재시작
      timeoutSeconds: 5

    readinessProbe:                  # 트래픽 수신 준비 확인
      httpGet:
        path: /ready
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 3
      successThreshold: 1
```

### Probe 방식

```yaml
# HTTP GET
httpGet:
  path: /healthz
  port: 8080
  httpHeaders:
    - name: Authorization
      value: Bearer token

# TCP Socket
tcpSocket:
  port: 5432

# Exec (명령어 종료 코드 0 = 정상)
exec:
  command:
    - /bin/sh
    - -c
    - "redis-cli ping | grep PONG"

# gRPC
grpc:
  port: 9090
  service: "liveness"
```

---

## 7. HPA (Horizontal Pod Autoscaler)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70    # requests 대비 70% 초과 시 스케일 아웃
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60     # 스케일 아웃 전 60초 안정화 대기
      policies:
        - type: Pods
          value: 4
          periodSeconds: 60              # 60초당 최대 4개 추가
    scaleDown:
      stabilizationWindowSeconds: 300    # 스케일 인 전 5분 안정화 대기
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60              # 60초당 최대 20% 감소
```

```bash
# HPA 상태 확인
kubectl get hpa
kubectl describe hpa my-app-hpa
```

> HPA가 동작하려면 Metrics Server가 설치되어 있어야 합니다.
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
> ```

---

## 8. ConfigMap / Secret 활용 패턴

### 환경변수로 주입 (단일 키)

```yaml
env:
  - name: DB_HOST
    valueFrom:
      configMapKeyRef:
        name: my-config
        key: DATABASE_HOST
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: my-secret
        key: DATABASE_PASSWORD
```

### 환경변수 일괄 주입 (envFrom)

```yaml
envFrom:
  - configMapRef:
      name: my-config
  - secretRef:
      name: my-secret
```

### 볼륨으로 파일 마운트

```yaml
volumes:
  - name: config-vol
    configMap:
      name: my-config
  - name: secret-vol
    secret:
      secretName: my-secret
      defaultMode: 0400    # 읽기 전용 권한

containers:
  - name: app
    volumeMounts:
      - name: config-vol
        mountPath: /etc/config
      - name: secret-vol
        mountPath: /etc/secret
        readOnly: true
```

### subPath로 단일 파일 마운트

```yaml
volumes:
  - name: config-vol
    configMap:
      name: my-config

containers:
  - name: app
    volumeMounts:
      - name: config-vol
        mountPath: /app/config.yaml   # 기존 디렉토리 덮어쓰지 않음
        subPath: config.yaml
```

---

## 9. 트러블슈팅

### Pod 상태별 원인 및 진단

| 상태 | 원인 | 진단 명령어 |
|---|---|---|
| `Pending` | 노드 리소스 부족, Taint 미설정, PVC 미바인딩 | `kubectl describe pod`, `kubectl get events` |
| `CrashLoopBackOff` | 앱 에러, 설정 오류, OOM | `kubectl logs --previous` |
| `OOMKilled` | 메모리 limits 초과 | `kubectl describe pod` → `Last State: OOMKilled` |
| `ImagePullBackOff` | 이미지 없음, 레지스트리 인증 오류 | `kubectl describe pod` → Events 확인 |
| `Evicted` | 노드 리소스 부족 (디스크/메모리) | `kubectl get events -A \| grep Evicted` |

### 자주 쓰는 디버깅 명령어

```bash
# Pod 이벤트 + 상태 상세 확인
kubectl describe pod <pod-name>

# 이전 컨테이너 로그 (CrashLoopBackOff 시)
kubectl logs <pod-name> --previous

# 노드 리소스 확인 (Pending 원인 파악)
kubectl describe node <node-name>
kubectl top nodes

# 네트워크 연결 테스트 (임시 Pod)
kubectl run nettest --image=busybox --rm -it --restart=Never -- \
  wget -qO- http://my-app-svc.default.svc.cluster.local

# DNS 조회 테스트
kubectl run dnstest --image=busybox --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local

# ConfigMap / Secret 내용 확인
kubectl get configmap my-config -o yaml
kubectl get secret my-secret -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d

# 특정 노드 Pod 목록
kubectl get pods -A --field-selector=spec.nodeName=<node-name>

# 최근 Warning 이벤트 확인
kubectl get events -A --field-selector=type=Warning \
  --sort-by=.metadata.creationTimestamp | tail -20
```

### 네트워크 트러블슈팅

```bash
# Service → Pod 연결 확인
kubectl get endpoints <svc-name>   # Pod IP가 있어야 정상

# Ingress 상태 확인
kubectl describe ingress <ingress-name>
kubectl get ingress -A

# kube-dns 동작 확인
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

---

## 10. 실무 팁

### Alias 설정

```bash
# ~/.bashrc 또는 ~/.zshrc에 추가
alias k=kubectl
alias kg='kubectl get'
alias kd='kubectl describe'
alias kl='kubectl logs'
alias kx='kubectl exec -it'

# kubectl 자동완성
source <(kubectl completion bash)
complete -F __start_kubectl k
```

### PodDisruptionBudget (노드 점검 시 가용성 보장)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 2           # 최소 2개는 항상 유지
  # maxUnavailable: 1       # 또는 최대 1개까지 불가용 허용
  selector:
    matchLabels:
      app: my-app
```

### SecurityContext (보안 강화)

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

### 주의사항 체크리스트

```
□ requests / limits 항상 설정 (BestEffort Pod는 가장 먼저 퇴거)
□ readinessProbe 필수 설정 (없으면 시작 즉시 트래픽 수신)
□ Secret은 base64일 뿐 암호화 아님 → Vault / Sealed Secrets 사용
□ latest 태그 사용 금지 → 명시적 버전 태그 사용
□ PodDisruptionBudget 설정 → 노드 점검 시 서비스 중단 방지
□ terminationGracePeriodSeconds 설정 → 배포 시 graceful shutdown 보장
□ RBAC 최소 권한 원칙 적용
□ HPA 사용 시 requests 반드시 설정 (기준값으로 사용)
```

---

## 참고 링크

- [Kubernetes 공식 문서](https://kubernetes.io/docs/)
- [kubectl 명령어 레퍼런스](https://kubernetes.io/docs/reference/kubectl/quick-reference/)
- [Kubernetes API 레퍼런스](https://kubernetes.io/docs/reference/kubernetes-api/)
- [Awesome Kubernetes](https://github.com/ramitsurana/awesome-kubernetes)
