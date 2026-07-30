#!/bin/bash
set -e

ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
else
  echo "ERROR: Archivo .env no encontrado. Copia .env.example como .env y completa los valores."
  exit 1
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-$(aws configure get region)}
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

usage() {
  echo "Uso: ./build.sh [base|function|all|deploy]"
  echo ""
  echo "  base      Buildea y sube la imagen base (R + GDAL + paquetes)."
  echo "            Solo necesario cuando cambian dependencias del sistema o paquetes R."
  echo "            ~60 min la primera vez."
  echo ""
  echo "  function  Buildea y sube la imagen Lambda (solo copia el codigo .r)."
  echo "            Usar despues de cada cambio en el codigo."
  echo "            ~30 segundos."
  echo ""
  echo "  deploy    Actualiza la funcion Lambda con la imagen ECR actual."
  echo "            Requiere perfil AWS 'deploy-cli'."
  echo ""
  echo "  all       Buildea base, function y hace deploy."
  exit 1
}

ecr_login() {
  echo ">>> Login a ECR..."
  aws ecr get-login-password --region $REGION \
    | docker login --username AWS --password-stdin $ECR
}

build_base() {
  echo ">>> Buildeando imagen base (esto tarda ~60 min)..."
  docker build -f Dockerfile.base -t "${ECR}/${BASE_REPO}:latest" .
  echo ">>> Subiendo imagen base a ECR..."
  docker push "${ECR}/${BASE_REPO}:latest"
  echo ">>> Imagen base lista: ${ECR}/${BASE_REPO}:latest"
}

build_function() {
  echo ">>> Buildeando imagen Lambda..."
  # --platform is explicit: the Lambda function runs on arm64, and without this
  # the image would inherit the build host's architecture.
  docker build --platform linux/arm64 \
    --build-arg BASE_IMAGE="${ECR}/${BASE_REPO}:latest" \
    -t "${FUNCTION_REPO}:latest" .
  echo ">>> Tageando imagen..."
  docker tag "${FUNCTION_REPO}:latest" "${ECR}/${FUNCTION_REPO}:latest"
  echo ">>> Subiendo imagen Lambda a ECR..."
  docker push "${ECR}/${FUNCTION_REPO}:latest"
  echo ">>> Imagen Lambda lista: ${ECR}/${FUNCTION_REPO}:latest"
}

deploy_lambda() {
  LAMBDA_FUNCTION=${LAMBDA_FUNCTION:-d4n}
  IMAGE_URI="${ECR}/${FUNCTION_REPO}:latest"

  # deploy-cli may lack lambda:UpdateFunctionCode on this function (it does on
  # `conservation`), so fall back to admin instead of failing. Either way this
  # only updates $LATEST (staging); promoting to prod is a separate manual
  # publish-version + update-alias.
  DEPLOY_PROFILE=${DEPLOY_PROFILE:-deploy-cli}
  if ! aws lambda get-function --function-name "${LAMBDA_FUNCTION}" \
       --profile "${DEPLOY_PROFILE}" >/dev/null 2>&1; then
    echo ">>> Perfil '${DEPLOY_PROFILE}' sin acceso a '${LAMBDA_FUNCTION}', usando 'admin'."
    DEPLOY_PROFILE=admin
  fi

  echo ">>> Actualizando Lambda '${LAMBDA_FUNCTION}' con imagen ${IMAGE_URI}..."
  aws lambda update-function-code \
    --function-name "${LAMBDA_FUNCTION}" \
    --image-uri "${IMAGE_URI}" \
    --profile "${DEPLOY_PROFILE}"
  echo ">>> Esperando que Lambda quede activa..."
  aws lambda wait function-updated \
    --function-name "${LAMBDA_FUNCTION}" \
    --profile "${DEPLOY_PROFILE}"
  echo ">>> Lambda '${LAMBDA_FUNCTION}' actualizada (\$LATEST / staging)."
}

case "${1:-}" in
  base)
    ecr_login
    build_base
    ;;
  function)
    ecr_login
    build_function
    ;;
  deploy)
    deploy_lambda
    ;;
  all)
    ecr_login
    build_base
    build_function
    deploy_lambda
    ;;
  *)
    usage
    ;;
esac
