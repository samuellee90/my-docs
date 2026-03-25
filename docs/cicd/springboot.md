# Spring Boot - K8s CI/CD

## 전체 흐름 요약

```
Bitbucket Push
  → Jenkins: gradle build → JAR → Docker build → Nexus push
  → values.yaml 이미지 태그 업데이트 → Git push
  → ArgoCD sync → K8s Deployment 롤링 업데이트
```

---

## Gradle 빌드 설정

```groovy
// build.gradle
plugins {
    id 'org.springframework.boot' version '3.3.0'
    id 'io.spring.dependency-management' version '1.1.5'
    id 'java'
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
}

// JAR 이름 고정 (Dockerfile에서 참조)
bootJar {
    archiveFileName = 'app.jar'
}
```

---

## Dockerfile

```dockerfile
# Multi-stage build: 빌드 단계 분리
FROM gradle:8-jdk21-alpine AS builder
WORKDIR /build
COPY . .
RUN gradle bootJar --no-daemon

# 실행 단계 (JRE만 포함 → 이미지 경량화)
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

# non-root 사용자
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=builder /build/build/libs/app.jar app.jar

USER appuser
EXPOSE 8080

ENTRYPOINT ["java", \
    "-XX:+UseContainerSupport", \
    "-XX:MaxRAMPercentage=75.0", \
    "-jar", "app.jar"]
```

> **팁**: Jenkins에서 이미 `gradle build`를 실행했다면 single-stage Dockerfile로 JAR만 COPY해도 됩니다.

---

## Helm Chart 구조

```
charts/springboot-app/
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── values-prod.yaml
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── configmap.yaml
    ├── ingress.yaml
    ├── hpa.yaml
    └── _helpers.tpl
```

### Chart.yaml

```yaml
apiVersion: v2
name: springboot-app
description: Spring Boot Application Helm Chart
type: application
version: 1.0.0
appVersion: "1.0.0"
```

### values.yaml

```yaml
replicaCount: 2

image:
  repository: nexus.example.com:8082/myapp/springboot-app
  tag: latest           # Jenkins가 빌드 시 덮어씀
  pullPolicy: Always

imagePullSecrets:
  - name: nexus-pull-secret

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

ingress:
  enabled: true
  className: nginx
  host: myapp.example.com

resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi

env:
  SPRING_PROFILES_ACTIVE: prod
  SERVER_PORT: "8080"

configmap:
  enabled: true
  data:
    application.properties: |
      spring.datasource.url=jdbc:postgresql://postgres:5432/mydb

hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
```

### templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "springboot-app.fullname" . }}
  labels:
    {{- include "springboot-app.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "springboot-app.selectorLabels" . | nindent 6 }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        {{- include "springboot-app.selectorLabels" . | nindent 8 }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 8080
          env:
            {{- range $key, $val := .Values.env }}
            - name: {{ $key }}
              value: {{ $val | quote }}
            {{- end }}
          {{- if .Values.configmap.enabled }}
          volumeMounts:
            - name: config-volume
              mountPath: /app/config
          {{- end }}
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 15
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
      {{- if .Values.configmap.enabled }}
      volumes:
        - name: config-volume
          configMap:
            name: {{ include "springboot-app.fullname" . }}-config
      {{- end }}
```

---

## K8s imagePullSecret 생성

```bash
kubectl create secret docker-registry nexus-pull-secret \
  --docker-server=nexus.example.com:8082 \
  --docker-username=jenkins \
  --docker-password=<nexus-password> \
  -n app
```

---

## Spring Boot Actuator 설정 (Probe 필수)

```yaml
# application.yaml
management:
  endpoint:
    health:
      probes:
        enabled: true
      show-details: always
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
```

---

## ArgoCD Application 등록

```yaml
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
    path: charts/springboot-app
    helm:
      valueFiles:
        - values.yaml
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 배포 확인 명령어

```bash
# ArgoCD 앱 상태
argocd app get springboot-app

# K8s 롤링 업데이트 상태
kubectl rollout status deployment/springboot-app -n app

# 실행 중인 이미지 태그 확인
kubectl get deployment springboot-app -n app \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 수동 롤백 (K8s 레벨)
kubectl rollout undo deployment/springboot-app -n app
```
