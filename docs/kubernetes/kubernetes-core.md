# Kubernetes 핵심 개념 및 실무 가이드

> 최종 업데이트: 2026-03-10
> 기준 버전: Kubernetes v1.32+

---

## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [핵심 오브젝트 개념 및 YAML 예시](#2-핵심-오브젝트-개념-및-yaml-예시)
3. [자주 쓰는 kubectl 명령어 모음](#3-자주-쓰는-kubectl-명령어-모음)
4. [Namespace 관리](#4-namespace-관리)
5. [리소스 요청/제한 (requests/limits)](#5-리소스-요청제한-requestslimits)
6. [Health Check (Probe)](#6-health-check-probe)
7. [HPA (Horizontal Pod Autoscaler)](#7-hpa-horizontal-pod-autoscaler)
8. [ConfigMap / Secret 활용 패턴](#8-configmap--secret-활용-패턴)
9. [실무 트러블슈팅 명령어](#9-실무-트러블슈팅-명령어)
10. [실무 팁 및 주의사항](#10-실무-팁-및-주의사항)

---

## 1. 아키텍처 개요

Kubernetes 클러스터는 **Control Plane**과 **Worker Node** 두 영역으로 구성됩니다.

```
┌─────────────────────────────────────────────────────────────┐
│                        Control Plane                        │
│  ┌─────────────┐  ┌───────┐  ┌──────────┐  ┌───────────┐  │
│  │  API Server │  │ etcd  │  │Scheduler │  │Controller │  │
│  │  (kube-api) │  │       │  │          │  │  Manager  │  │
│  └─────────────┘  └───────┘  └──────────┘  └───────────┘  │
└─────────────────────────────────────────────────────────────┘
          │                │                │
┌─────────┴──┐   ┌─────────┴──┐   ┌────────┴───┐
│ Worker Node│   │ Worker Node│   │ Worker Node│
│  ┌───────┐ │   │  ┌───────┐ │   │  ┌───────┐ │
│  │kubelet│ │   │  │kubelet│ │   │  │kubelet│ │
│  │k-proxy│ │   │  │k-proxy│ │   │  │k-proxy│ │
│  │runtime│ │   │  │runtime│ │   │  │runtime│ │
│  └───────┘ │   │  └───────┘ │   │  └───────┘ │
└────────────┘   └────────────┘   └────────────┘
```

### Control Plane 구성요소

| 구성요소 | 역할 |
|---|---|
| **kube-apiserver** | 모든 API 요청의 진입점. kubectl, 내부 컴포넌트 모두 API Server를 통해 통신 |
| **etcd** | 클러스터의 모든 상태를 저장하는 분산 key-value 스토어. 가용성이 매우 중요 |
| **kube-scheduler** | 새로운 Pod를 어느 노드에 배치할지 결정 (리소스, affinity, taint 등 고려) |
| **kube-controller-manager** | Deployment, ReplicaSet, Node 등 각종 컨트롤러를 실행하는 프로세스 |
| **cloud-controller-manager** | 클라우드 공급자(AWS, GCP, Azure 등)와의 연동 처리 (LoadBalancer, Volume 등) |

### Worker Node 구성요소

| 구성요소 | 역할 |
|---|---|
| **kubelet** | 노드에서 Pod 실행을 보장하는 에이전트. API Server와 통신하며 컨테이너 상태 관리 |
| **kube-proxy** | 노드의 네트워크 규칙(iptables/IPVS)을 관리하여 Service 트래픽 라우팅 처리 |
| **Container Runtime** | 실제 컨테이너를 실행하는 소프트웨어 (containerd, CRI-O 등. Docker는 v1.24부터 제거) |

---

## 2. 핵심 오브젝트 개념 및 YAML 예시

### Pod

가장 작은 배포 단위. 하나 이상의 컨테이너를 포함하며 동일한 네트워크/스토리지를 공유합니다.
일반적으로 Pod를 직접 생성하지 않고 Deployment 등 상위 오브젝트를 사용합니다.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app-pod
  namespace: default
  labels:
    app: my-app
    version: "1.0"
spec:
  containers:
    - name: my-app
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
      env:
        - name: ENV
          value: "production"
  restartPolicy: Always
```

### Deployment

Pod의 선언적 업데이트와 롤링 배포를 관리합니다. ReplicaSet을 내부적으로 관리합니다.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default
  labels:
    app: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # 최대 추가 생성 Pod 수
      maxUnavailable: 0  # 업데이트 중 최대 불가용 Pod 수
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: my-registry/my-app:v1.2.0
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
```

### Service

Pod에 안정적인 네트워크 엔드포인트를 제공합니다. Pod IP는 변동되지만 Service IP는 고정됩니다.

```yaml
# ClusterIP - 클러스터 내부 통신 (기본값)
apiVersion: v1
kind: Service
metadata:
  name: my-app-service
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: my-app       # 이 레이블을 가진 Pod에 트래픽 라우팅
  ports:
    - protocol: TCP
      port: 80        # Service 포트
      targetPort: 8080  # Pod 포트

---
# NodePort - 노드의 특정 포트로 외부 노출
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
      nodePort: 30080   # 30000-32767 범위

---
# LoadBalancer - 클라우드 LB를 통한 외부 노출
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

### ConfigMap

애플리케이션 설정 데이터를 컨테이너 이미지와 분리하여 관리합니다.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-config
  namespace: default
data:
  # 단일 값
  LOG_LEVEL: "info"
  DB_HOST: "postgres-service"
  DB_PORT: "5432"
  # 파일 형태
  app.properties: |
    server.port=8080
    logging.level=INFO
    feature.flag=true
```

### Secret

민감한 데이터(비밀번호, 토큰, 인증서 등)를 base64 인코딩으로 저장합니다.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-app-secret
  namespace: default
type: Opaque
data:
  # echo -n "mypassword" | base64
  DB_PASSWORD: bXlwYXNzd29yZA==
  API_KEY: c3VwZXItc2VjcmV0LWtleQ==
stringData:
  # stringData는 평문으로 작성 가능 (자동으로 base64 인코딩됨)
  EXTRA_KEY: "plain-text-value"
```

### Ingress

HTTP/HTTPS 트래픽을 클러스터 내부 Service로 라우팅하는 규칙을 정의합니다.
동작하려면 Ingress Controller(Nginx, Traefik 등)가 설치되어 있어야 합니다.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - myapp.example.com
      secretName: myapp-tls-secret  # TLS 인증서가 담긴 Secret
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-service
                port:
                  number: 80
```

### PersistentVolume (PV) / PersistentVolumeClaim (PVC)

PV는 클러스터 레벨의 스토리지 리소스, PVC는 사용자의 스토리지 요청입니다.

```yaml
# PersistentVolume - 관리자가 생성 (또는 StorageClass로 동적 프로비저닝)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce    # RWO: 단일 노드 R/W, RWX: 다중 노드 R/W, ROX: 다중 노드 RO
  persistentVolumeReclaimPolicy: Retain  # Retain / Delete / Recycle
  storageClassName: standard
  hostPath:
    path: /data/my-app

---
# PersistentVolumeClaim - 개발자가 생성
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: standard

---
# Pod에서 PVC 사용
apiVersion: v1
kind: Pod
metadata:
  name: my-app-with-storage
spec:
  containers:
    - name: my-app
      image: nginx:1.25
      volumeMounts:
        - mountPath: /data
          name: my-storage
  volumes:
    - name: my-storage
      persistentVolumeClaim:
        claimName: my-pvc
```

---

## 3. 자주 쓰는 kubectl 명령어 모음

### 기본 조회

```bash
# 리소스 목록 조회
kubectl get pods                          # Pod 목록
kubectl get pods -o wide                  # 노드 정보 포함
kubectl get pods -A                       # 모든 네임스페이스
kubectl get pods -n my-namespace          # 특정 네임스페이스
kubectl get all -n my-namespace           # 모든 리소스 조회
kubectl get pod my-pod -o yaml            # YAML 출력
kubectl get pod my-pod -o json            # JSON 출력

# 상세 정보 조회
kubectl describe pod my-pod
kubectl describe node my-node
kubectl describe deployment my-deployment

# 레이블 기반 조회
kubectl get pods -l app=my-app
kubectl get pods -l app=my-app,env=prod
```

### 리소스 생성/수정/삭제

```bash
# 파일 기반
kubectl apply -f deployment.yaml          # 생성 또는 업데이트 (권장)
kubectl apply -f ./manifests/             # 디렉토리 내 모든 YAML 적용
kubectl delete -f deployment.yaml         # 파일 기반 삭제

# 직접 명령
kubectl create deployment my-app --image=nginx:1.25 --replicas=3
kubectl expose deployment my-app --port=80 --target-port=8080 --type=ClusterIP
kubectl delete pod my-pod
kubectl delete pod my-pod --force --grace-period=0  # 강제 삭제

# 수정
kubectl edit deployment my-app            # 에디터로 직접 수정
kubectl set image deployment/my-app my-app=nginx:1.26  # 이미지 변경
kubectl scale deployment my-app --replicas=5           # 레플리카 수 조정
```

### 로그 및 디버깅

```bash
# 로그 조회
kubectl logs my-pod                       # Pod 로그
kubectl logs my-pod -c my-container       # 멀티 컨테이너 Pod
kubectl logs my-pod --previous            # 이전 컨테이너 로그 (재시작된 경우)
kubectl logs my-pod -f                    # 실시간 스트리밍
kubectl logs my-pod --tail=100            # 마지막 100줄
kubectl logs -l app=my-app --all-pods     # 레이블 기반 전체 Pod 로그

# 컨테이너 접속
kubectl exec -it my-pod -- /bin/sh
kubectl exec -it my-pod -c my-container -- /bin/bash

# 포트 포워딩
kubectl port-forward pod/my-pod 8080:80
kubectl port-forward svc/my-service 8080:80
kubectl port-forward deployment/my-app 8080:80
```

### 롤아웃 관리

```bash
# 롤아웃 상태 확인
kubectl rollout status deployment/my-app
kubectl rollout history deployment/my-app
kubectl rollout history deployment/my-app --revision=3

# 롤백
kubectl rollout undo deployment/my-app
kubectl rollout undo deployment/my-app --to-revision=2

# 롤아웃 일시 정지/재개
kubectl rollout pause deployment/my-app
kubectl rollout resume deployment/my-app
```

### 리소스 사용량 조회

```bash
kubectl top pods                          # Pod CPU/메모리 사용량
kubectl top pods -n my-namespace
kubectl top pods --sort-by=memory         # 메모리 기준 정렬
kubectl top nodes                         # 노드 리소스 사용량
```

---

## 4. Namespace 관리

Namespace는 클러스터 내 논리적 격리 단위입니다. 팀, 환경(dev/stage/prod), 서비스 단위로 분리합니다.

### 기본 Namespace

| Namespace | 용도 |
|---|---|
| `default` | 별도 지정 없을 때 사용되는 기본 Namespace |
| `kube-system` | Kubernetes 시스템 컴포넌트 (CoreDNS, kube-proxy 등) |
| `kube-public` | 클러스터 전체 공개 리소스 |
| `kube-node-lease` | 노드 Heartbeat용 Lease 오브젝트 저장 |

### Namespace 생성 및 관리

```bash
# Namespace 생성
kubectl create namespace my-namespace

# YAML로 생성 (권장)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: my-namespace
  labels:
    team: backend
    env: production
EOF

# Namespace 목록 조회
kubectl get namespaces
kubectl get ns   # 축약형

# 기본 Namespace 변경 (컨텍스트)
kubectl config set-context --current --namespace=my-namespace

# Namespace 삭제 (내부 리소스 모두 삭제됨 - 주의!)
kubectl delete namespace my-namespace
```

### ResourceQuota - Namespace 리소스 제한

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: my-namespace-quota
  namespace: my-namespace
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    services: "10"
    persistentvolumeclaims: "5"
```

### LimitRange - Pod 기본값 설정

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: my-namespace-limitrange
  namespace: my-namespace
spec:
  limits:
    - type: Container
      default:          # limits 미지정 시 기본값
        cpu: "500m"
        memory: "256Mi"
      defaultRequest:   # requests 미지정 시 기본값
        cpu: "100m"
        memory: "128Mi"
      max:              # 최대 허용
        cpu: "2"
        memory: "2Gi"
      min:              # 최소 허용
        cpu: "50m"
        memory: "64Mi"
```

---

## 5. 리소스 요청/제한 (requests/limits)

### 개념

| 항목 | 설명 |
|---|---|
| `requests` | Pod를 스케줄링할 때 보장되는 최소 리소스. 노드 선택의 기준 |
| `limits` | Pod가 사용할 수 있는 최대 리소스. 초과 시 CPU는 스로틀링, 메모리는 OOMKill |

### CPU / Memory 단위

- **CPU**: `1` = 1 코어, `500m` = 0.5 코어 (m = millicores)
- **Memory**: `128Mi` = 128 메비바이트, `1Gi` = 1 기비바이트

### 설정 예시

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: my-app:latest
          resources:
            requests:
              cpu: "250m"     # 스케줄러가 노드 선택 시 기준
              memory: "256Mi"
            limits:
              cpu: "1"        # 초과 시 스로틀링 (컨테이너 종료 없음)
              memory: "512Mi" # 초과 시 OOMKill (컨테이너 재시작)
```

### QoS 클래스

Kubernetes는 requests/limits 설정에 따라 Pod의 QoS 클래스를 자동 부여합니다.

| QoS 클래스 | 조건 | 특징 |
|---|---|---|
| **Guaranteed** | requests == limits (모든 컨테이너) | 가장 마지막에 종료됨. 가장 안정적 |
| **Burstable** | requests < limits (일부 컨테이너) | 중간 우선순위 |
| **BestEffort** | requests/limits 모두 미설정 | 리소스 부족 시 가장 먼저 종료됨 |

```bash
# Pod QoS 클래스 확인
kubectl get pod my-pod -o jsonpath='{.status.qosClass}'
```

---

## 6. Health Check (Probe)

### 세 가지 Probe 종류

| Probe | 실패 시 동작 | 용도 |
|---|---|---|
| **livenessProbe** | 컨테이너 재시작 | 앱이 데드락 등으로 응답 불가 상태 감지 |
| **readinessProbe** | Service에서 트래픽 제외 | 앱이 요청 처리 가능 상태인지 확인 |
| **startupProbe** | 실패 시 컨테이너 재시작 | 느린 초기화 앱의 시작 완료 대기 |

> startupProbe가 성공할 때까지 livenessProbe와 readinessProbe는 동작하지 않습니다.

### Probe 방식

```yaml
# 1. HTTP GET - 지정 경로에 HTTP 요청, 2xx/3xx 응답이면 성공
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
    httpHeaders:
      - name: Custom-Header
        value: Awesome

# 2. TCP Socket - 포트 연결 가능 여부 확인
livenessProbe:
  tcpSocket:
    port: 8080

# 3. Exec - 명령어 실행 후 종료 코드 0이면 성공
livenessProbe:
  exec:
    command:
      - cat
      - /tmp/healthy

# 4. gRPC - gRPC 헬스 체크 프로토콜
livenessProbe:
  grpc:
    port: 2379
```

### 실무 권장 설정 예시

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: my-app:latest
          ports:
            - containerPort: 8080

          # 앱 시작 시간이 오래 걸릴 때: 최대 5*60=300초 대기
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            failureThreshold: 60   # 60번 실패 허용
            periodSeconds: 5       # 5초마다 체크

          # 생존 확인: 데드락/응답 불가 감지 후 재시작
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10  # 첫 체크까지 대기 (startupProbe 없을 때)
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 3      # 3번 연속 실패 시 재시작
            successThreshold: 1

          # 준비 확인: 외부 의존성(DB, 캐시 등) 포함 체크
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3      # 3번 실패 시 Service에서 제외
            successThreshold: 1
```

### Probe 주요 파라미터

| 파라미터 | 기본값 | 설명 |
|---|---|---|
| `initialDelaySeconds` | 0 | 컨테이너 시작 후 첫 체크까지 대기 시간 |
| `periodSeconds` | 10 | 체크 주기 (초) |
| `timeoutSeconds` | 1 | 응답 대기 제한 시간 (초) |
| `successThreshold` | 1 | 성공으로 판단하기 위한 연속 성공 횟수 |
| `failureThreshold` | 3 | 실패로 판단하기 위한 연속 실패 횟수 |

---

## 7. HPA (Horizontal Pod Autoscaler)

CPU/메모리 사용률 또는 커스텀 메트릭 기반으로 Pod 수를 자동 조절합니다.
HPA가 동작하려면 **Metrics Server**가 클러스터에 설치되어 있어야 합니다.

### 기본 CPU 기반 HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70  # 평균 CPU 사용률 70% 유지
```

### CPU + 메모리 복합 HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
  namespace: default
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
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: AverageValue
          averageValue: "400Mi"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0    # 즉시 스케일 업
      policies:
        - type: Pods
          value: 4                      # 한 번에 최대 4개 추가
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300  # 5분 안정화 후 스케일 다운
      policies:
        - type: Percent
          value: 10                    # 한 번에 최대 10% 감소
          periodSeconds: 60
```

### HPA 상태 확인

```bash
# HPA 목록 및 현재 상태
kubectl get hpa
kubectl get hpa my-app-hpa
kubectl describe hpa my-app-hpa

# 실시간 모니터링
kubectl get hpa -w

# Metrics Server 설치 확인
kubectl top pods
kubectl top nodes
```

> **주의**: Pod에 `resources.requests.cpu`가 설정되어 있지 않으면 CPU 기반 HPA가 동작하지 않습니다.

---

## 8. ConfigMap / Secret 활용 패턴

### 패턴 1: 환경 변수로 주입

```yaml
spec:
  containers:
    - name: my-app
      image: my-app:latest
      env:
        # ConfigMap 단일 키
        - name: LOG_LEVEL
          valueFrom:
            configMapKeyRef:
              name: my-app-config
              key: LOG_LEVEL
        # Secret 단일 키
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: my-app-secret
              key: DB_PASSWORD
```

### 패턴 2: 전체 키를 환경 변수로 일괄 주입

```yaml
spec:
  containers:
    - name: my-app
      image: my-app:latest
      envFrom:
        - configMapRef:
            name: my-app-config     # ConfigMap의 모든 키를 환경 변수로
        - secretRef:
            name: my-app-secret     # Secret의 모든 키를 환경 변수로
```

### 패턴 3: 볼륨으로 파일 마운트

```yaml
spec:
  containers:
    - name: my-app
      image: my-app:latest
      volumeMounts:
        - name: config-volume
          mountPath: /etc/config    # ConfigMap 파일로 마운트
          readOnly: true
        - name: secret-volume
          mountPath: /etc/secrets   # Secret 파일로 마운트
          readOnly: true
  volumes:
    - name: config-volume
      configMap:
        name: my-app-config
    - name: secret-volume
      secret:
        secretName: my-app-secret
        defaultMode: 0400           # 파일 권한 (소유자만 읽기)
```

### 패턴 4: ConfigMap 특정 파일만 마운트

```yaml
spec:
  containers:
    - name: my-app
      volumeMounts:
        - name: config-volume
          mountPath: /etc/config/app.properties
          subPath: app.properties    # 특정 키만 마운트 (디렉토리 덮어쓰기 방지)
  volumes:
    - name: config-volume
      configMap:
        name: my-app-config
        items:
          - key: app.properties
            path: app.properties
```

### Secret 명령어 관리

```bash
# Secret 생성
kubectl create secret generic my-secret \
  --from-literal=DB_PASSWORD=mypassword \
  --from-literal=API_KEY=my-api-key

# 파일에서 생성
kubectl create secret generic my-secret \
  --from-file=config.json=./config.json

# TLS Secret 생성
kubectl create secret tls my-tls-secret \
  --cert=tls.crt \
  --key=tls.key

# Docker 레지스트리 인증
kubectl create secret docker-registry my-registry-secret \
  --docker-server=my-registry.example.com \
  --docker-username=myuser \
  --docker-password=mypassword

# Secret 값 확인 (base64 디코딩)
kubectl get secret my-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 --decode
```

---

## 9. 실무 트러블슈팅 명령어

### Pod 상태 이상 진단 흐름

```bash
# 1단계: 전체 상태 확인
kubectl get pods -n my-namespace
kubectl get pods -A | grep -v Running | grep -v Completed

# 2단계: 상세 이벤트 확인 (CrashLoopBackOff, OOMKilled, Pending 등)
kubectl describe pod my-pod -n my-namespace

# 3단계: 로그 확인
kubectl logs my-pod -n my-namespace
kubectl logs my-pod -n my-namespace --previous  # 이전 컨테이너 로그

# 4단계: 컨테이너 내부 직접 확인
kubectl exec -it my-pod -n my-namespace -- /bin/sh
```

### 주요 Pod 오류 상태 및 원인

```bash
# Pending: 노드에 스케줄링 안 됨
# -> 리소스 부족, taint/toleration, nodeSelector 문제
kubectl describe pod my-pod | grep -A 10 Events

# CrashLoopBackOff: 컨테이너가 반복 재시작
# -> 애플리케이션 오류, 잘못된 환경 변수, 의존 서비스 미준비
kubectl logs my-pod --previous

# OOMKilled: 메모리 초과
# -> limits.memory 증가 또는 메모리 누수 확인
kubectl describe pod my-pod | grep -i oom

# ImagePullBackOff / ErrImagePull: 이미지 pull 실패
# -> 이미지 이름/태그 오류, 레지스트리 인증 실패
kubectl describe pod my-pod | grep -A 5 "Failed to pull"

# ContainerCreating: 컨테이너 생성 중 멈춤
# -> PVC 마운트 실패, ConfigMap/Secret 없음
kubectl describe pod my-pod | grep -A 10 Events
```

### 네트워크 트러블슈팅

```bash
# Service 엔드포인트 확인 (Pod가 Service에 연결됐는지)
kubectl get endpoints my-service -n my-namespace

# Service 내부 DNS 확인 (임시 디버그 Pod)
kubectl run debug --image=nicolaka/netshoot -it --rm -- /bin/bash
# 내부에서: nslookup my-service.my-namespace.svc.cluster.local
# 내부에서: curl http://my-service.my-namespace.svc.cluster.local

# 네트워크 정책 확인
kubectl get networkpolicy -n my-namespace
kubectl describe networkpolicy my-policy -n my-namespace
```

### 노드 트러블슈팅

```bash
# 노드 상태 확인
kubectl get nodes
kubectl describe node my-node

# 노드 리소스 사용량
kubectl top nodes
kubectl top pods --all-namespaces --sort-by=memory

# 노드 cordon (신규 Pod 스케줄링 중지)
kubectl cordon my-node

# 노드 drain (Pod 안전하게 이동 후 유지보수)
kubectl drain my-node --ignore-daemonsets --delete-emptydir-data

# 노드 복구 후 uncordon
kubectl uncordon my-node
```

### 기타 유용한 진단 명령어

```bash
# 클러스터 이벤트 실시간 조회
kubectl get events -n my-namespace --sort-by='.lastTimestamp'
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# 특정 리소스의 YAML 전체 출력
kubectl get pod my-pod -o yaml
kubectl get deployment my-app -o yaml > backup.yaml

# 리소스 용량 및 할당 현황
kubectl describe nodes | grep -A 5 "Allocated resources"

# 임시 디버그 Pod 실행 (종료 시 자동 삭제)
kubectl run debug-pod --image=busybox -it --rm --restart=Never -- /bin/sh

# Pod의 특정 필드만 출력 (jsonpath)
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

# 모든 컨텍스트 목록
kubectl config get-contexts
kubectl config use-context my-cluster
```

---

## 10. 실무 팁 및 주의사항

### 배포 안전성

```yaml
# PodDisruptionBudget: 노드 드레인 시 최소 가용 Pod 수 보장
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 2       # 최소 2개 Pod는 항상 실행 (또는 maxUnavailable 사용)
  selector:
    matchLabels:
      app: my-app
```

```yaml
# Deployment에 terminationGracePeriodSeconds 설정
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 60  # 기본값 30초. graceful shutdown 시간 확보
      containers:
        - name: my-app
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]  # kube-proxy 업데이트 대기
```

### 보안 설정

```yaml
# SecurityContext: 컨테이너 보안 강화
spec:
  securityContext:
    runAsNonRoot: true     # root 실행 방지
    runAsUser: 1000
    fsGroup: 2000
  containers:
    - name: my-app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true    # 파일시스템 읽기 전용
        capabilities:
          drop:
            - ALL                        # 모든 Linux capabilities 제거
```

### 레이블 및 어노테이션 관리

```bash
# 레이블 추가/수정
kubectl label pod my-pod env=production
kubectl label pod my-pod env=staging --overwrite

# 레이블 제거
kubectl label pod my-pod env-

# 어노테이션 추가
kubectl annotate deployment my-app kubernetes.io/change-cause="v1.2.0 배포"
```

### kubectl 생산성 향상

```bash
# 자주 쓰는 alias 설정 (~/.bashrc 또는 ~/.zshrc)
alias k='kubectl'
alias kga='kubectl get all'
alias kgp='kubectl get pods'
alias kd='kubectl describe'
alias kl='kubectl logs'

# kubectl 자동완성 설정
source <(kubectl completion bash)   # bash
source <(kubectl completion zsh)    # zsh

# kubens / kubectx 도구 설치 (Namespace/Context 전환 편의)
# https://github.com/ahmetb/kubectx
kubens my-namespace     # Namespace 전환
kubectx my-cluster      # Context 전환

# stern: 여러 Pod 로그 동시 스트리밍
# https://github.com/stern/stern
stern my-app -n my-namespace
```

### 주의사항 체크리스트

| 항목 | 주의 내용 |
|---|---|
| `kubectl delete namespace` | Namespace 내 모든 리소스가 삭제됨. 반드시 확인 후 실행 |
| `kubectl delete pod --force` | graceful termination 없이 즉시 삭제. 데이터 손실 위험 |
| `latest` 태그 사용 금지 | `imagePullPolicy: Always` 와 조합 시 예상치 못한 버전 배포 가능 |
| `requests` 미설정 | HPA가 동작하지 않고, BestEffort QoS로 분류되어 먼저 종료됨 |
| Secret을 Git에 커밋 금지 | base64는 암호화가 아님. Sealed Secrets, External Secrets Operator 등 사용 |
| `edit` 명령어 주의 | 운영 환경에서는 `apply -f` 방식의 GitOps를 사용하고 직접 edit 지양 |
| PVC 삭제 주의 | `Delete` 정책의 PV는 PVC 삭제 시 데이터도 삭제됨 |
| `--all-namespaces` | 전체 클러스터 조회 시 API Server 부하 주의 |

---

## 참고 자료

- [Kubernetes 공식 문서](https://kubernetes.io/docs/)
- [kubectl Quick Reference](https://kubernetes.io/docs/reference/kubectl/quick-reference/)
- [Horizontal Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/)
