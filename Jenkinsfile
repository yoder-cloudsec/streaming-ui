pipeline {
    agent any

    parameters {
        booleanParam(name: 'ENFORCE', defaultValue: false,
            description: 'false: scanners report only (build turns yellow). true: findings fail the build.')
    }

    environment {
        AWS_REGION     = 'eu-south-2'
        CLUSTER        = 'streaming'
        K8S_NS         = 'streaming'
        ECR_REPO       = 'streaming-ui'
        PATH           = "/snap/bin:${env.PATH}"
        TRIVY_EXIT     = "${params.ENFORCE ? 1 : 0}"
        DC_FAIL        = "${params.ENFORCE ? '--failOnCVSS 7' : ''}"
        SCANNER_IMAGE  = 'sonarsource/sonar-scanner-cli:latest'
        DEPCHECK_IMAGE = 'owasp/dependency-check:latest'
        NODE_IMAGE     = 'node:20-alpine'
    }

    stages {
        stage('Clean workspace') {
            steps {
                deleteDir()
            }
        }

        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG = sh(returnStdout: true, script: 'git rev-parse --short=12 HEAD').trim()
                }
            }
        }

        stage('SonarQube analysis') {
            steps {
                withSonarQubeEnv('sonarqube') {
                    sh '''
                      docker run --rm --network host -u "$(id -u):$(id -g)" \
                        -e SONAR_HOST_URL="$SONAR_HOST_URL" -e SONAR_TOKEN="$SONAR_AUTH_TOKEN" \
                        -e SONAR_USER_HOME=/tmp/.sonar \
                        -v "$PWD:/usr/src" "$SCANNER_IMAGE" \
                        -Dsonar.projectKey=streaming-ui -Dsonar.projectName=streaming-ui
                    '''
                }
            }
        }

        stage('Quality gate') {
            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    script {
                        def qg = waitForQualityGate()
                        if (qg.status != 'OK') {
                            if (params.ENFORCE) {
                                error "Quality gate failed: ${qg.status}"
                            } else {
                                unstable("Quality gate: ${qg.status}")
                            }
                        }
                    }
                }
            }
        }

         stage('Install dependencies') {
            steps {
                sh '''
                  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/app" -w /app "$NODE_IMAGE" \
                    yarn install --frozen-lockfile --ignore-scripts
                '''
            }
        }

        stage('Dependency-Check') {
            steps {
                timeout(time: 90, unit: 'MINUTES') {
                    sh '''
                      set +x
                      NVD_KEY=$(aws ssm get-parameter --region "$AWS_REGION" --name /streaming/nvd-api-key --with-decryption --query Parameter.Value --output text)
                      mkdir -p reports "$JENKINS_HOME/odc-data"
                      docker run --rm -u "$(id -u):$(id -g)" \
                        -v "$PWD:/src" -v "$JENKINS_HOME/odc-data:/usr/share/dependency-check/data" \
                        "$DEPCHECK_IMAGE" \
                        --scan /src --out /src/reports --format HTML --format JSON \
                        --disableYarnAudit --disableNodeAudit \
                        --nvdApiKey "$NVD_KEY" $DC_FAIL
                    '''
                }
            }
        }

        stage('Trivy filesystem scan') {
            steps {
                sh '''
                  rc=0
                  trivy fs --scanners vuln,secret,misconfig --skip-dirs node_modules \
                    --severity HIGH,CRITICAL --exit-code "$TRIVY_EXIT" --output trivyfs.txt . || rc=$?
                  cat trivyfs.txt
                  exit $rc
                '''
            }
        }

        stage('Build image') {
            steps {
                sh '''
                  set +x
                  umask 077
                  KEYFILE=$(mktemp)
                  trap 'rm -f "$KEYFILE"' EXIT
                  aws ssm get-parameter --region "$AWS_REGION" --name /streaming/tmdb-api-key \
                    --with-decryption --query Parameter.Value --output text > "$KEYFILE"
                  DOCKER_BUILDKIT=1 docker build --secret id=tmdb_key,src="$KEYFILE" \
                    -t "streaming-ui:$IMAGE_TAG" .
                '''
            }
        }

        stage('Trivy image scan') {
            steps {
                sh '''
                  rc=0
                  trivy image --severity HIGH,CRITICAL --ignore-unfixed \
                    --exit-code "$TRIVY_EXIT" --output trivyimage.txt "streaming-ui:$IMAGE_TAG" || rc=$?
                  cat trivyimage.txt
                  exit $rc
                '''
            }
        }

        stage('Smoke test') {
            steps {
                sh '''
                  CID=$(docker run -d --rm -p 127.0.0.1:18081:80 "streaming-ui:$IMAGE_TAG")
                  trap 'docker stop "$CID" > /dev/null' EXIT
                  for i in 1 2 3 4 5 6 7 8 9 10; do
                    if curl -fsS http://127.0.0.1:18081/ > /dev/null; then exit 0; fi
                    sleep 2
                  done
                  docker logs "$CID"
                  exit 1
                '''
            }
        }

        stage('Push to ECR') {
            steps {
                sh '''
                  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
                  REGISTRY="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
                  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
                  docker tag "streaming-ui:$IMAGE_TAG" "$REGISTRY/$ECR_REPO:$IMAGE_TAG"
                  docker push "$REGISTRY/$ECR_REPO:$IMAGE_TAG"
                  docker inspect --format='{{index .RepoDigests 0}}' "$REGISTRY/$ECR_REPO:$IMAGE_TAG" > image-digest.txt
                  cat image-digest.txt
                '''
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                sh '''
                  export KUBECONFIG="$WORKSPACE/.kubeconfig"
                  aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
                  DIGEST=$(cat image-digest.txt)
                  sed "s|IMAGE_PLACEHOLDER|$DIGEST|" k8s/deployment.yaml | kubectl apply -n "$K8S_NS" -f -
                  kubectl apply -n "$K8S_NS" -f k8s/service.yaml
                  kubectl rollout status deployment/streaming-ui -n "$K8S_NS" --timeout=180s
                '''
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'reports/**, trivyfs.txt, trivyimage.txt, image-digest.txt', allowEmptyArchive: true
            sh 'docker image prune -af --filter "until=48h" || true'
        }
    }
}
