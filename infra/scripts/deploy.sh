#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Deploy script with ECS/EKS abstraction layer
# Usage: DEPLOY_TARGET=ecs ./deploy.sh [service_name]
# Examples:
#   DEPLOY_TARGET=ecs ./deploy.sh clickhouse
#   DEPLOY_TARGET=ecs ./deploy.sh keeper
#   DEPLOY_TARGET=ecs ./deploy.sh all
################################################################################

DEPLOY_TARGET="${DEPLOY_TARGET:-ecs}"
SERVICE_NAME="${1:-all}"
PROJECT="${PROJECT:-logplatform}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

CLUSTER_NAME="${PROJECT}-${ENVIRONMENT}"

# ClickHouse and Keeper service names
CLICKHOUSE_SERVICES=(
  "${PROJECT}-${ENVIRONMENT}-ch-s1r1"
  "${PROJECT}-${ENVIRONMENT}-ch-s1r2"
  "${PROJECT}-${ENVIRONMENT}-ch-s2r1"
  "${PROJECT}-${ENVIRONMENT}-ch-s2r2"
)
KEEPER_SERVICES=(
  "${PROJECT}-${ENVIRONMENT}-keeper-1"
  "${PROJECT}-${ENVIRONMENT}-keeper-2"
  "${PROJECT}-${ENVIRONMENT}-keeper-3"
)

################################################################################
# Abstraction functions
################################################################################

deploy_ecs_service() {
  local service_name="$1"
  echo "Deploying ECS service: ${service_name}"
  aws ecs update-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${service_name}" \
    --force-new-deployment \
    --region "${AWS_REGION}" \
    --no-cli-pager
}

deploy_eks_service() {
  local service_name="$1"
  echo "Deploying EKS service: ${service_name}"
  kubectl rollout restart "statefulset/${service_name}" -n "${PROJECT}"
}

wait_ecs_stable() {
  local service_name="$1"
  echo "Waiting for ECS service to stabilize: ${service_name}"
  aws ecs wait services-stable \
    --cluster "${CLUSTER_NAME}" \
    --services "${service_name}" \
    --region "${AWS_REGION}"
}

wait_eks_stable() {
  local service_name="$1"
  echo "Waiting for EKS rollout: ${service_name}"
  kubectl rollout status "statefulset/${service_name}" -n "${PROJECT}" --timeout=300s
}

deploy_service() {
  local service_name="$1"
  case "${DEPLOY_TARGET}" in
    ecs) deploy_ecs_service "${service_name}" ;;
    eks) deploy_eks_service "${service_name}" ;;
    *)   echo "ERROR: Unknown DEPLOY_TARGET: ${DEPLOY_TARGET}"; exit 1 ;;
  esac
}

wait_stable() {
  local service_name="$1"
  case "${DEPLOY_TARGET}" in
    ecs) wait_ecs_stable "${service_name}" ;;
    eks) wait_eks_stable "${service_name}" ;;
  esac
}

################################################################################
# Deploy logic
################################################################################

deploy_keeper() {
  echo "=== Deploying Keeper services ==="
  for svc in "${KEEPER_SERVICES[@]}"; do
    deploy_service "${svc}"
  done
  for svc in "${KEEPER_SERVICES[@]}"; do
    wait_stable "${svc}"
  done
  echo "=== Keeper deployment complete ==="
}

deploy_clickhouse() {
  echo "=== Deploying ClickHouse services ==="
  for svc in "${CLICKHOUSE_SERVICES[@]}"; do
    deploy_service "${svc}"
  done
  for svc in "${CLICKHOUSE_SERVICES[@]}"; do
    wait_stable "${svc}"
  done
  echo "=== ClickHouse deployment complete ==="
}

case "${SERVICE_NAME}" in
  keeper)
    deploy_keeper
    ;;
  clickhouse)
    deploy_clickhouse
    ;;
  all)
    deploy_keeper
    deploy_clickhouse
    ;;
  *)
    echo "ERROR: Unknown service: ${SERVICE_NAME}"
    echo "Usage: $0 [keeper|clickhouse|all]"
    exit 1
    ;;
esac

echo "Deployment complete (target: ${DEPLOY_TARGET})"
