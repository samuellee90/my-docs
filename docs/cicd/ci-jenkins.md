# CI 파이프라인 - Jenkins + Nexus + Bitbucket

## 전체 흐름

```
Bitbucket ──(Webhook)──▶ Jenkins Pipeline
                              │
                    ┌─────────┼─────────┐
                    ▼         ▼         ▼
                 Checkout   Build    Test
                (Bitbucket) (Maven) (JUnit)
                              │
                              ▼
                         Docker Build
                              │
                              ▼
                    Nexus Docker Registry
                              │
                              ▼
                   Update Helm values.yaml
                              │
                              ▼
                     Git Push → ArgoCD Trigger
```

---

## 사전 준비

### Jenkins 플러그인

```
- Git Plugin
- Bitbucket Plugin (Webhook 연동)
- Pipeline Plugin
- Docker Pipeline Plugin
- Kubernetes Plugin (optional: K8s agent)
- Nexus Artifact Uploader (optional)
- Credentials Plugin
```

### Jenkins Credentials 등록

| ID | 종류 | 용도 |
|----|------|------|
| `bitbucket-creds` | Username/Password | Bitbucket 소스 체크아웃 |
| `nexus-docker-creds` | Username/Password | Nexus Docker Registry 로그인 |
| `git-push-creds` | Username/Password or SSH | Helm repo push |

---

## Bitbucket Webhook 설정

1. Bitbucket 저장소 → **Settings → Webhooks → Add webhook**
2. URL: `http://<jenkins-url>/bitbucket-hook/`
3. Triggers: **Repository push**, **Pull Request created/updated**

---

## Jenkinsfile 예시 (Declarative Pipeline)

> 경로: `<bitbucket-repo>/Jenkinsfile`

```groovy
pipeline {
    agent any

    environment {
        NEXUS_URL        = 'nexus.example.com:8082'
        IMAGE_NAME       = 'myapp/springboot-app'
        HELM_REPO        = 'git@bitbucket.org:myorg/helm-charts.git'
        HELM_VALUES_PATH = 'charts/springboot-app/values.yaml'
    }

    stages {

        stage('Checkout') {
            steps {
                git credentialsId: 'bitbucket-creds',
                    url: 'https://bitbucket.org/myorg/myapp.git',
                    branch: env.BRANCH_NAME
            }
        }

        stage('Build JAR') {
            steps {
                sh './gradlew clean build -x test'
                // Maven이면: sh 'mvn clean package -DskipTests'
            }
        }

        stage('Unit Test') {
            steps {
                sh './gradlew test'
            }
            post {
                always {
                    junit 'build/test-results/test/*.xml'
                }
            }
        }

        stage('Docker Build') {
            steps {
                script {
                    def imageTag = "${env.BUILD_NUMBER}-${env.GIT_COMMIT[0..6]}"
                    env.IMAGE_TAG = imageTag
                    sh """
                        docker build -t ${NEXUS_URL}/${IMAGE_NAME}:${imageTag} .
                        docker tag  ${NEXUS_URL}/${IMAGE_NAME}:${imageTag} \
                                    ${NEXUS_URL}/${IMAGE_NAME}:latest
                    """
                }
            }
        }

        stage('Push to Nexus') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'nexus-docker-creds',
                    usernameVariable: 'NEXUS_USER',
                    passwordVariable: 'NEXUS_PASS'
                )]) {
                    sh """
                        echo $NEXUS_PASS | docker login ${NEXUS_URL} \
                            -u $NEXUS_USER --password-stdin
                        docker push ${NEXUS_URL}/${IMAGE_NAME}:${env.IMAGE_TAG}
                        docker push ${NEXUS_URL}/${IMAGE_NAME}:latest
                    """
                }
            }
        }

        stage('Update Helm values') {
            when {
                branch 'main'   // main 브랜치 push 시에만 배포 트리거
            }
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'git-push-creds',
                    usernameVariable: 'GIT_USER',
                    passwordVariable: 'GIT_PASS'
                )]) {
                    sh """
                        git clone https://${GIT_USER}:${GIT_PASS}@bitbucket.org/myorg/helm-charts.git /tmp/helm-charts
                        cd /tmp/helm-charts

                        # image.tag 값을 새 빌드 태그로 교체
                        sed -i 's|tag:.*|tag: "${env.IMAGE_TAG}"|' ${HELM_VALUES_PATH}

                        git config user.email "jenkins@ci.local"
                        git config user.name  "Jenkins CI"
                        git add ${HELM_VALUES_PATH}
                        git commit -m "ci: update image tag to ${env.IMAGE_TAG}"
                        git push origin main
                    """
                }
            }
        }
    }

    post {
        success {
            echo "Build ${env.IMAGE_TAG} pushed to Nexus. ArgoCD will sync K8s."
        }
        failure {
            // Slack/Email 알림 설정 가능
            echo "Pipeline failed. Check Jenkins logs."
        }
        always {
            sh "docker rmi ${NEXUS_URL}/${IMAGE_NAME}:${env.IMAGE_TAG} || true"
        }
    }
}
```

---

## Dockerfile 예시 (Spring Boot)

```dockerfile
FROM eclipse-temurin:21-jre-alpine

WORKDIR /app

# Spring Boot 빌드 결과 JAR
COPY build/libs/app.jar app.jar

# 보안: non-root 실행
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
```

---

## Nexus Docker Registry 설정

### Nexus에서 Docker Registry 생성

1. Nexus UI → **Repositories → Create repository**
2. Recipe: **docker (hosted)**
3. HTTP Port: `8082` (또는 HTTPS 8083)
4. Allow anonymous pull: 내부망에서는 허용 가능

### Docker daemon에 Nexus 신뢰 설정

```json
// /etc/docker/daemon.json
{
  "insecure-registries": ["nexus.example.com:8082"]
}
```

### K8s imagePullSecret 생성

```bash
kubectl create secret docker-registry nexus-pull-secret \
  --docker-server=nexus.example.com:8082 \
  --docker-username=<user> \
  --docker-password=<pass> \
  --docker-email=<email> \
  -n <namespace>
```

---

## Jenkins에서 K8s Agent 사용 (선택)

빌드를 K8s Pod로 실행하면 Jenkins 서버 부하를 줄일 수 있습니다.

```groovy
pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: gradle
    image: gradle:8-jdk21
    command: ['sleep', '99d']
  - name: docker
    image: docker:dind
    securityContext:
      privileged: true
"""
        }
    }
    stages {
        stage('Build') {
            steps {
                container('gradle') {
                    sh 'gradle build'
                }
            }
        }
    }
}
```

---

## 브랜치 전략 예시

| 브랜치 | CI 동작 | CD 동작 |
|--------|---------|---------|
| `feature/*` | 빌드 + 테스트만 | 없음 |
| `develop` | 빌드 + 이미지 push | dev 환경 자동 배포 |
| `main` | 빌드 + 이미지 push | staging/prod 배포 |

```groovy
stage('Push to Nexus') {
    when {
        anyOf {
            branch 'main'
            branch 'develop'
        }
    }
    // ...
}
```
