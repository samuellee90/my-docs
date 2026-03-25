# K8s CI/CD 파이프라인 전체 개요

## 아키텍처 요약

```
[Bitbucket] → Push/PR
     │
     ▼
[Jenkins]  ─── 빌드 & 테스트 & 이미지 빌드
     │
     ▼
[Nexus]    ─── Docker 이미지 저장소 (Docker Registry)
     │
     ▼ (Helm values 업데이트 → Git push)
[Git Repo] ─── Helm Chart / values.yaml
     │
     ▼ (GitOps 감지)
[ArgoCD]   ─── K8s 클러스터 자동 동기화
     │
     ▼
[Kubernetes] ── 실제 워크로드 실행
```

---

## 구성 요소

| 역할 | 도구 |
|------|------|
| 소스 코드 관리 | Bitbucket |
| CI 자동화 | Jenkins |
| 아티팩트 / 이미지 저장 | Nexus (Maven + Docker Registry) |
| GitOps CD | ArgoCD |
| 패키지 관리 | Helm Chart |
| 컨테이너 오케스트레이션 | Kubernetes |

---

## CI 파이프라인 흐름

1. **개발자** → Bitbucket에 코드 push
2. **Bitbucket Webhook** → Jenkins 빌드 트리거
3. **Jenkins**:
   - 소스 코드 체크아웃 (Bitbucket)
   - Maven / Gradle 빌드 → JAR 생성
   - Docker 이미지 빌드 (`docker build`)
   - Nexus Docker Registry에 이미지 push (`docker push`)
   - Helm Chart values.yaml 이미지 태그 업데이트 → Git push
4. **ArgoCD** → Git 변경 감지 → K8s 자동 동기화

---

## CD 파이프라인 흐름 (GitOps)

1. Jenkins가 `values.yaml`에 새 이미지 태그 커밋
2. ArgoCD가 Git 저장소 변경 감지 (폴링 or Webhook)
3. ArgoCD가 K8s에 Helm 릴리스 자동 동기화
4. 롤백은 ArgoCD UI / CLI에서 이전 Git 커밋으로 즉시 복구

---

## 대상 워크로드

| 워크로드 | 배포 방식 | 특이사항 |
|---------|----------|---------|
| Spring Boot App | 커스텀 Helm Chart | JAR → Docker → Nexus |
| Kafka | Helm (Bitnami/Strimzi) | Operator 또는 Helm |
| Apache Airflow | Helm (공식 Chart) | DAG는 Git-sync |
| Apache Spark | Helm (spark-operator) | SparkApplication CRD |
| Trino | Helm (Trino 공식) | 설정은 ConfigMap |

---

## 네임스페이스 구성 예시

```yaml
# 권장 네임스페이스 분리
namespaces:
  - app          # Spring Boot 애플리케이션
  - data         # Kafka, Spark, Trino
  - workflow     # Airflow
  - cicd         # Jenkins, ArgoCD (별도 클러스터 권장)
```

---

## 다음 단계

- [CI 파이프라인 상세 (Jenkins)](cicd/ci-jenkins.md)
- [CD 파이프라인 상세 (ArgoCD)](cicd/cd-argocd.md)
- [Spring Boot 배포](cicd/springboot.md)
- [Kafka 배포](cicd/kafka.md)
- [Airflow 배포](cicd/airflow.md)
- [Spark 배포](cicd/spark.md)
- [Trino 배포](cicd/trino.md)
