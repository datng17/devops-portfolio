// eks-portfolio pipeline: test -> build -> push to ECR -> deploy to EKS -> verify (auto-undo) -> smoke test.
//
// Runs on the local Jenkins in jenkins/ (tools baked into the image). Needs:
//   credentials  jenkins-ci-aws (username/password = access key of IAM user jenkins-ci)
//                jenkins-deployer-role-arn (secret text)
//                portfolio-ingress-config (secret file = k8s/app/ingress-config.env)
//   global env   AWS_REGION, EKS_CLUSTER_NAME, APP_URL
// jenkins-deployer only has Edit in namespace "portfolio"; nothing here touches
// cluster-scoped resources.

// Writes an AWS CLI config whose "deployer" profile assumes jenkins-deployer
// with the jenkins-ci key as source profile. The key lives only in a temp file
// that post { always } removes. No AWS_ACCESS_KEY_ID in the environment, so
// every aws call (and the kubeconfig exec plugin) uses the assumed role.
def configureAws() {
  withCredentials([
    usernamePassword(credentialsId: 'jenkins-ci-aws', usernameVariable: 'CI_KEY_ID', passwordVariable: 'CI_SECRET'),
    string(credentialsId: 'jenkins-deployer-role-arn', variable: 'DEPLOYER_ROLE_ARN'),
  ]) {
    sh '''#!/bin/bash
      set -euo pipefail
      umask 077
      mkdir -p "$(dirname "$AWS_CONFIG_FILE")"
      printf '[jenkins-ci]\\naws_access_key_id = %s\\naws_secret_access_key = %s\\n' \
        "$CI_KEY_ID" "$CI_SECRET" > "$AWS_SHARED_CREDENTIALS_FILE"
      printf '[profile deployer]\\nrole_arn = %s\\nsource_profile = jenkins-ci\\nrole_session_name = jenkins-build-%s\\nduration_seconds = 3600\\nregion = %s\\n' \
        "$DEPLOYER_ROLE_ARN" "$BUILD_NUMBER" "$AWS_REGION" > "$AWS_CONFIG_FILE"
      echo "AWS identity: $(aws sts get-caller-identity --query Arn --output text | sed -E 's/::[0-9]{12}:/::<account>:/')"
    '''
  }
}

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 30, unit: 'MINUTES')
  }

  parameters {
    string(name: 'OVERRIDE_IMAGE_TAG', defaultValue: '',
           description: 'Deploy this existing image tag instead of building the commit (rollback / failure demo).')
  }

  triggers {
    // Local Jenkins cannot receive GitHub webhooks.
    pollSCM('H/2 * * * *')
  }

  environment {
    CI = 'true'
    NAMESPACE = 'portfolio'
    DEPLOYMENT = 'portfolio'
    // Per-build scratch dir (Jenkins' <workspace>@tmp), wiped in post.
    SCRATCH = "${WORKSPACE}@tmp/pipeline"
    AWS_CONFIG_FILE = "${WORKSPACE}@tmp/pipeline/aws/config"
    AWS_SHARED_CREDENTIALS_FILE = "${WORKSPACE}@tmp/pipeline/aws/credentials"
    AWS_PROFILE = 'deployer'
    AWS_PAGER = ''
    DOCKER_CONFIG = "${WORKSPACE}@tmp/pipeline/docker"
    KUBECONFIG = "${WORKSPACE}@tmp/pipeline/kube/config"
    DOCKER_BUILDKIT = '1'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHA = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
          def override = (params.OVERRIDE_IMAGE_TAG ?: '').trim()
          if (override && !(override ==~ /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/)) {
            error "OVERRIDE_IMAGE_TAG '${override}' is not a valid image tag"
          }
          env.OVERRIDE = override ? 'true' : 'false'
          env.IMAGE_TAG = override ?: env.GIT_SHA
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG}${override ? ' (override)' : ''}"
          ['AWS_REGION', 'EKS_CLUSTER_NAME', 'APP_URL'].each { name ->
            if (!env."${name}") { error "Global env var ${name} is not set (see jenkins/casc.yaml)" }
          }
        }
        // ingress-config.env is gitignored; it comes from a Jenkins secret file.
        withCredentials([file(credentialsId: 'portfolio-ingress-config', variable: 'INGRESS_CONFIG')]) {
          sh '''#!/bin/bash
            set -euo pipefail
            install -m 0644 "$INGRESS_CONFIG" k8s/app/ingress-config.env
            for key in ACM_CERTIFICATE_ARN ALB_SECURITY_GROUP_ID ECR_REPOSITORY_URL; do
              grep -q "^${key}=." k8s/app/ingress-config.env || { echo "ingress-config.env has no ${key}" >&2; exit 1; }
            done
          '''
        }
        script {
          env.ECR_REPOSITORY_URL = sh(returnStdout: true,
            script: "sed -n 's/^ECR_REPOSITORY_URL=//p' k8s/app/ingress-config.env").trim()
          env.IMAGE = "${env.ECR_REPOSITORY_URL}:${env.IMAGE_TAG}"
        }
        echo "Commit ${env.GIT_SHA}, deploying tag ${env.IMAGE_TAG}"
      }
    }

    stage('Install') {
      when { environment name: 'OVERRIDE', value: 'false' }
      steps {
        sh 'npm ci --no-audit --no-fund'
      }
    }

    stage('Lint & Test') {
      when { environment name: 'OVERRIDE', value: 'false' }
      environment {
        JEST_JUNIT_OUTPUT_DIR = 'reports/junit'
        JEST_JUNIT_OUTPUT_NAME = 'jest.xml'
      }
      steps {
        sh 'npm run lint'
        sh '''npm run test:ci -- --reporters=default --reporters=jest-junit \
              --coverageReporters=cobertura --coverageReporters=text-summary'''
      }
      post {
        always {
          junit testResults: 'reports/junit/*.xml', allowEmptyResults: false
          recordCoverage(tools: [[parser: 'COBERTURA', pattern: 'coverage/cobertura-coverage.xml']],
                         sourceCodeRetention: 'NEVER')
        }
      }
    }

    stage('Build Image') {
      when { environment name: 'OVERRIDE', value: 'false' }
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          docker build \
            --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
            --label "org.opencontainers.image.source=eks-portfolio" \
            -t "$IMAGE" .
          docker image inspect "$IMAGE" --format 'Built {{.Id}} ({{.Size}} bytes)'
        '''
      }
    }

    stage('Push') {
      when { environment name: 'OVERRIDE', value: 'false' }
      steps {
        script { configureAws() }
        sh '''#!/bin/bash
          set -euo pipefail
          registry="${ECR_REPOSITORY_URL%%/*}"
          repo="${ECR_REPOSITORY_URL#*/}"
          # Tags are IMMUTABLE in ECR: if this commit was already pushed, reuse it.
          if out="$(aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$IMAGE_TAG" 2>&1)"; then
            echo "Tag $IMAGE_TAG already in ECR; skipping push"
            exit 0
          elif ! grep -q ImageNotFoundException <<<"$out"; then
            echo "$out" >&2
            exit 1
          fi
          mkdir -p "$DOCKER_CONFIG"
          aws ecr get-login-password | docker login --username AWS --password-stdin "$registry"
          docker push "$IMAGE"
        '''
      }
    }

    stage('Deploy') {
      steps {
        script { configureAws() }
        sh '''#!/bin/bash
          set -euo pipefail
          mkdir -p "$(dirname "$KUBECONFIG")"
          aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
            --kubeconfig "$KUBECONFIG" --alias "$EKS_CLUSTER_NAME" >/dev/null
          # Remember the live revision so a failed rollout can be undone to exactly it.
          kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
            -o jsonpath='{.metadata.annotations.deployment\\.kubernetes\\.io/revision}' \
            > "$SCRATCH/prev-revision" 2>/dev/null || : > "$SCRATCH/prev-revision"
          echo "Live revision before deploy: $(cat "$SCRATCH/prev-revision")"
          # The repository part is filled in from ECR_REPOSITORY_URL by kustomize replacements.
          (cd k8s/app && kustomize edit set image "portfolio:${IMAGE_TAG}")
          kubectl apply -k k8s/app --dry-run=server >/dev/null
          kubectl apply -k k8s/app
        '''
      }
    }

    stage('Verify Rollout') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          PREV_REVISION="$(cat "$SCRATCH/prev-revision")" EXPECTED_IMAGE="$IMAGE" \
            bash scripts/verify-rollout.sh
        '''
      }
    }

    stage('Smoke Test') {
      steps {
        sh 'bash scripts/smoke-test.sh "$APP_URL"'
      }
    }
  }

  post {
    success {
      echo "Deployed ${env.IMAGE} to ${env.APP_URL}"
    }
    always {
      sh '''#!/bin/bash
        rm -rf "$SCRATCH" "$HOME/.aws/cli/cache"
        rm -f k8s/app/ingress-config.env
        git checkout -- k8s/app/kustomization.yaml 2>/dev/null || true
        if [ "${OVERRIDE:-false}" = "false" ] && [ -n "${IMAGE:-}" ]; then
          docker image rm "$IMAGE" >/dev/null 2>&1 || true
        fi
      '''
    }
  }
}
