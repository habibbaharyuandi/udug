#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_APP_NAME="ladug"
DEFAULT_ROLE_NAME="uus"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "=== Proses Deployment AWS + IAM Role ==="

# Cek status AWS tanpa nyebut login manual
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "${ACCOUNT_ID}" ]]; then
  echo "Awas! AWS CLI teu tiasa ngakses akun CloudShell."
  echo "Pastikeun CloudShell anjeun geus ngagunakeun akun AWS anu bener."
  exit 1
fi

echo "Nomor akun AWS anjeun: ${ACCOUNT_ID}"

echo "Ketik nama aplikasi / repo (teken enter pikeun make bawaan: ${DEFAULT_APP_NAME})"
read -r APP_NAME
if [[ -z "${APP_NAME}" ]]; then
  APP_NAME="${DEFAULT_APP_NAME}"
fi
echo "Nama aplikasi anu dipake: ${APP_NAME}"

echo "Ketik nama role IAM (teken enter pikeun make bawaan: ${DEFAULT_ROLE_NAME})"
read -r ROLE_NAME
if [[ -z "${ROLE_NAME}" ]]; then
  ROLE_NAME="${DEFAULT_ROLE_NAME}"
fi
echo "Nama role IAM anu dipake: ${ROLE_NAME}"

echo "Ketik region AWS anu rek dipake, pisahkeun ku koma"
echo "Contoh: us-east-1,us-east-2,us-west-2"
read -r REGION_INPUT

if [[ -z "${REGION_INPUT}" ]]; then
  REGION_INPUT="us-east-1,us-east-2,us-west-2"
fi

IFS=',' read -ra REGIONS <<< "${REGION_INPUT}"

ALL_REGIONS="$(aws ec2 describe-regions --region us-east-1 --all --query 'Regions[].RegionName' --output text 2>/dev/null || true)"
for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"
  if [[ -z "${region}" ]]; then
    continue
  fi

  if ! echo "${ALL_REGIONS}" | grep -q "^${region}$"; then
    echo "Region teu valid: ${region}"
    exit 1
  fi
done

echo "Region anu bakal dipake:"
printf '%s\n' "${REGIONS[@]}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker teu kapanggih di CloudShell."
  echo "Tanpa Docker, build/push image moal bisa."
  exit 1
fi

echo "Menyiapkeun trust policy untuk SageMaker..."
cat > /tmp/sagemaker-trust-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "sagemaker.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role ${ROLE_NAME} geus aya. Lanjutna attach policy..."
else
  echo "Nyieun role ${ROLE_NAME}..."
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document file:///tmp/sagemaker-trust-policy.json
fi

echo "Attach policy AmazonSageMakerFullAccess..."
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess

echo "Attach policy AmazonS3FullAccess..."
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

echo "Attach policy AmazonEC2ContainerRegistryFullAccess..."
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess

ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query "Role.Arn" --output text)
echo "Role IAM SageMaker:"
echo "${ROLE_ARN}"

echo "Ngeunduh file konfigurasi..."
curl -fsSL https://github.com/ngagateng2-creator/codet/raw/refs/heads/main/edas.sh -o edas.sh
curl -fsSL https://github.com/ngagateng2-creator/codet/raw/refs/heads/main/Dockerfile -o Dockerfile

echo "Ieu hasil file anu diunduh:"
echo "--- edas.sh ---"
sed -n '1,40p' edas.sh
echo "--- Dockerfile ---"
sed -n '1,40p' Dockerfile

read -p "Tekan Enter kanggo neruskeun, atawa Ctrl+C kanggo batal..." -r

for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"
  bucket="${ACCOUNT_ID}-${region}"

  echo "== Nyieun / ngecek bucket S3 di ${region} =="
  if ! aws s3api head-bucket --bucket "${bucket}" --region "${region}" >/dev/null 2>&1; then
    aws s3 mb "s3://${bucket}" --region "${region}"
  else
    echo "Bucket geus aya: ${bucket}"
  fi

  aws s3 cp ./edas.sh "s3://${bucket}/${APP_NAME}/edas.sh" --region "${region}"
done

for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"

  echo "== Nyieun / ngecek repo ECR di ${region} =="
  if ! aws ecr describe-repositories --repository-names "${APP_NAME}" --region "${region}" >/dev/null 2>&1; then
    aws ecr create-repository \
      --repository-name "${APP_NAME}" \
      --image-scanning-configuration scanOnPush=false \
      --region "${region}"
  else
    echo "Repository geus aya: ${APP_NAME}"
  fi

  echo "Login ka ECR ${region}..."
  aws ecr get-login-password --region "${region}" | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com"
done

echo "Ngarangkep image Docker..."
docker build -t "${APP_NAME}:${IMAGE_TAG}" .

for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"
  remote="${ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com/${APP_NAME}:${IMAGE_TAG}"

  echo "Ngadorong image ka ${remote}..."
  docker tag "${APP_NAME}:${IMAGE_TAG}" "${remote}"
  docker push "${remote}"
done

echo
echo "Proses deployment AWS geus rampung."
echo "Role ARN: ${ROLE_ARN}"
