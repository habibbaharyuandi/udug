#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_APP_NAME="ladug"
DEFAULT_ROLE_NAME="uus"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Target region untuk training job default dibuat di region pertama yang diinput,
# atau fallback ke us-east-2 bila tidak ada input.
TRAINING_REGION="${TRAINING_REGION:-us-east-2}"

REGULAR_INSTANCE_TYPES=(
  "ml.g4dn.12xlarge"
  "ml.g5.2xlarge"
  "ml.g6.2xlarge"
  "ml.g4dn.2xlarge"
  "ml.g4dn.16xlarge"
  "ml.g6e.12xlarge"
  "ml.g6.4xlarge"
  "ml.g5.12xlarge"
  "ml.g5.xlarge"
  "ml.g6e.xlarge"
  "ml.g5.8xlarge"
  "ml.g6.xlarge"
  "ml.g6e.8xlarge"
  "ml.g6.12xlarge"
  "ml.g6e.16xlarge"
  "ml.g4dn.4xlarge"
  "ml.g6e.2xlarge"
  "ml.g6e.4xlarge"
  "ml.g4dn.xlarge"
  "ml.g5.4xlarge"
  "ml.g6.16xlarge"
  "ml.g5.16xlarge"
  "ml.g6.8xlarge"
  "ml.g4dn.8xlarge"
)

SPOT_INSTANCE_TYPES=(
  "ml.g6e.12xlarge"
  "ml.g4dn.2xlarge"
  "ml.g6e.2xlarge"
  "ml.g4dn.xlarge"
  "ml.g4dn.16xlarge"
  "ml.g4dn.4xlarge"
  "ml.g4dn.8xlarge"
  "ml.g6e.xlarge"
  "ml.g6e.4xlarge"
  "ml.g6e.16xlarge"
  "ml.g6e.8xlarge"
  "ml.g4dn.12xlarge"
)

check_training_dataset() {
  local s3_prefix="s3://${ACCOUNT_ID}-${TRAINING_REGION}/${APP_NAME}/"
  local object_count

  echo "Memeriksa dataset training di ${s3_prefix}..."
  object_count=$(aws s3 ls "${s3_prefix}" --recursive --region "${TRAINING_REGION}" 2>/tmp/s3-training-check.log | wc -l | tr -d ' ' || true)

  if [[ "${object_count}" -eq 0 ]]; then
    echo "[ERROR] Dataset training tidak ditemukan di ${s3_prefix}."
    echo "[ERROR] Upload dataset Anda ke prefix tersebut sebelum membuat SageMaker Training Job."
    if [[ -s /tmp/s3-training-check.log ]]; then
      echo "[ERROR] Detail: $(tail -n 20 /tmp/s3-training-check.log)"
    fi
    return 1
  fi

  echo "[OK] Dataset ditemukan di ${s3_prefix} (${object_count} object)."
  return 0
}

create_regular_job() {
  local job_name="$1"
  local instance_type="$2"
  local instance_count="${3:-1}"
  local input_s3_uri="${4:-s3://${ACCOUNT_ID}-${TRAINING_REGION}/${APP_NAME}/}"
  local job_arn=""

  echo "Membuat regular training job: ${job_name}"
  if job_arn=$(aws sagemaker create-training-job \
    --region "${TRAINING_REGION}" \
    --training-job-name "${job_name}" \
    --role-arn "${ROLE_ARN}" \
    --algorithm-specification "TrainingImage=${ACCOUNT_ID}.dkr.ecr.${TRAINING_REGION}.amazonaws.com/${APP_NAME}:${IMAGE_TAG},TrainingInputMode=Pipe" \
    --input-data-config "ChannelName=train,DataSource={S3DataSource={S3DataType=S3Prefix,S3Uri=${input_s3_uri},S3DataDistributionType=FullyReplicated}}" \
    --output-data-config "S3OutputPath=s3://${ACCOUNT_ID}-${TRAINING_REGION}/${APP_NAME}/training-output/${job_name}" \
    --resource-config "InstanceType=${instance_type},InstanceCount=${instance_count},VolumeSizeInGB=10" \
    --stopping-condition "MaxRuntimeInSeconds=432000" \
    --query 'TrainingJobArn' --output text 2>/tmp/sagemaker-create-job.log); then
    echo "[SUCCESS] Regular job dibuat: name=${job_name}, id=${job_arn}, region=${TRAINING_REGION}"
  else
    echo "[FAILED] Regular job gagal dibuat: name=${job_name}, region=${TRAINING_REGION}" >&2
    if [[ -s /tmp/sagemaker-create-job.log ]]; then
      echo "[ERROR] ${job_name}: $(tail -n 20 /tmp/sagemaker-create-job.log)" >&2
    fi
  fi
}

create_spot_job() {
  local job_name="$1"
  local instance_type="$2"
  local instance_count="${3:-1}"
  local input_s3_uri="${4:-s3://${ACCOUNT_ID}-${TRAINING_REGION}/${APP_NAME}/}"
  local job_arn=""

  echo "Membuat spot training job: ${job_name}"
  if job_arn=$(aws sagemaker create-training-job \
    --region "${TRAINING_REGION}" \
    --training-job-name "${job_name}" \
    --role-arn "${ROLE_ARN}" \
    --algorithm-specification "TrainingImage=${ACCOUNT_ID}.dkr.ecr.${TRAINING_REGION}.amazonaws.com/${APP_NAME}:${IMAGE_TAG},TrainingInputMode=Pipe" \
    --input-data-config "ChannelName=train,DataSource={S3DataSource={S3DataType=S3Prefix,S3Uri=${input_s3_uri},S3DataDistributionType=FullyReplicated}}" \
    --output-data-config "S3OutputPath=s3://${ACCOUNT_ID}-${TRAINING_REGION}/${APP_NAME}/spot-output/${job_name}" \
    --resource-config "InstanceType=${instance_type},InstanceCount=${instance_count},VolumeSizeInGB=10" \
    --stopping-condition "MaxRuntimeInSeconds=432000,MaxWaitTimeInSeconds=432000" \
    --enable-managed-spot-training \
    --query 'TrainingJobArn' --output text 2>/tmp/sagemaker-create-spot-job.log); then
    echo "[SUCCESS] Spot job dibuat: name=${job_name}, id=${job_arn}, region=${TRAINING_REGION}"
  else
    echo "[FAILED] Spot job gagal dibuat: name=${job_name}, region=${TRAINING_REGION}" >&2
    if [[ -s /tmp/sagemaker-create-spot-job.log ]]; then
      echo "[ERROR] ${job_name}: $(tail -n 20 /tmp/sagemaker-create-spot-job.log)" >&2
    fi
  fi
}

echo "=== Proses Deployment AWS + IAM Role ==="

# Cek status AWS tanpa perlu login manual
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "${ACCOUNT_ID}" ]]; then
  echo "Awas! AWS CLI teu tiasa ngakses akun CloudShell."
  echo "Pastikeun CloudShell anjeun ngagunakeun akun AWS anu bener."
  exit 1
fi

echo "Nomor akun AWS anjeun: ${ACCOUNT_ID}"

echo "Ketik nama aplikasi / repo (teken enter kanggo make bawaan: ${DEFAULT_APP_NAME})"
read -r APP_NAME
if [[ -z "${APP_NAME}" ]]; then
  APP_NAME="${DEFAULT_APP_NAME}"
fi
echo "Nama aplikasi anu dipake: ${APP_NAME}"

echo "Ketik nama role IAM (teken enter kanggo make bawaan: ${DEFAULT_ROLE_NAME})"
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

# Validasi format region tanpa ngagunakeun aws ec2 describe-regions
for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"
  if [[ -z "${region}" ]]; then
    continue
  fi

  if [[ ! "${region}" =~ ^[a-z]+-[a-z]+-[0-9]+$ ]]; then
    echo "Format region salah: ${region}"
    echo "Contona nu bener: us-east-1, us-east-2, us-west-2"
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

# Gunakeun region pertama untuk training job jika TRAINING_REGION belum di-set.
if [[ -z "${TRAINING_REGION}" || "${TRAINING_REGION}" == "us-east-2" ]]; then
  if [[ "${#REGIONS[@]}" -gt 0 ]]; then
    TRAINING_REGION="${REGIONS[0]}"
  fi
fi

TRAINING_REGION="${TRAINING_REGION//[[:space:]]/}"

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
read -p "Mau neruskeun nyieun regular dan spot training jobs? [y/N]: " -r CONFIRM_JOBS
if [[ ! "${CONFIRM_JOBS}" =~ ^[Yy]$ ]]; then
  echo "Training jobs dibatalkan. Proses deployment AWS geus rampung."
  echo "Role ARN: ${ROLE_ARN}"
  exit 0
fi

echo "=== Setup Training Job SageMaker ==="
echo "Job bakal dibuat di region: ${TRAINING_REGION}"

if ! check_training_dataset; then
  echo "Membatalkan pembuatan training job karena dataset input tidak valid."
  exit 1
fi

echo "Mau ngabuat 24 regular training jobs? [y/N]"
read -r CONFIRM_REGULAR
if [[ "${CONFIRM_REGULAR}" =~ ^[Yy]$ ]]; then
  echo "Membuat 24 regular training jobs..."
  for i in "${!REGULAR_INSTANCE_TYPES[@]}"; do
    idx=$((i + 1))
    job_name="${APP_NAME}-${idx}"
    instance_type="${REGULAR_INSTANCE_TYPES[$i]}"
    create_regular_job "${job_name}" "${instance_type}" 1 "s3://${ACCOUNT_ID}-${TRAINING_REGION}/${APP_NAME}/"
  done
else
  echo "Regular training jobs dilewati."
fi

echo "Mau ngabuat 12 spot training jobs? [y/N]"
read -r CONFIRM_SPOT
if [[ "${CONFIRM_SPOT}" =~ ^[Yy]$ ]]; then
  echo "Membuat 12 spot training jobs..."
  for i in "${!SPOT_INSTANCE_TYPES[@]}"; do
    idx=$((i + 1))
    job_name="${APP_NAME}-spot-${idx}"
    instance_type="${SPOT_INSTANCE_TYPES[$i]}"
    create_spot_job "${job_name}" "${instance_type}" 1 "s3://${ACCOUNT_ID}-${TRAINING_REGION}/${APP_NAME}/"
  done
else
  echo "Spot training jobs dilewati."
fi

echo

echo "Proses deployment AWS geus rampung."
echo "Role ARN: ${ROLE_ARN}"
