#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_APP_NAME="ladug"
DEFAULT_ROLE_NAME="uus"
IMAGE_TAG="${IMAGE_TAG:-latest}"

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
  local region="$1"
  local s3_prefix="s3://${ACCOUNT_ID}-${region}/${APP_NAME}/"
  local object_count

  echo "Ngecek dataset training di ${s3_prefix}..."
  object_count=$(aws s3 ls "${s3_prefix}" --recursive --region "${region}" 2>/tmp/s3-training-check.log | wc -l | tr -d ' ' || true)

  if [[ "${object_count}" -eq 0 ]]; then
    echo "[ERROR] Dataset training teu kapanggih di ${s3_prefix}."
    echo "[ERROR] Unggah dataset anjeun ka prefix eta saméméh nyieun SageMaker Training Job."
    if [[ -s /tmp/s3-training-check.log ]]; then
      echo "[ERROR] Rincian: $(tail -n 20 /tmp/s3-training-check.log)"
    fi
    return 1
  fi

  echo "[OKE] Dataset kapanggih di ${s3_prefix} (${object_count} object)."
  return 0
}

create_regular_job() {
  local job_name="$1"
  local instance_type="$2"
  local instance_count="${3:-1}"
  local input_s3_uri="$4"
  local target_region="$5"
  local job_arn=""

  echo "Nyieun regular training job: ${job_name} di ${target_region}"
  if job_arn=$(aws sagemaker create-training-job \
    --region "${target_region}" \
    --training-job-name "${job_name}" \
    --role-arn "${ROLE_ARN}" \
    --algorithm-specification "TrainingImage=${ACCOUNT_ID}.dkr.ecr.${target_region}.amazonaws.com/${APP_NAME}:${IMAGE_TAG},TrainingInputMode=Pipe" \
    --input-data-config "ChannelName=train,DataSource={S3DataSource={S3DataType=S3Prefix,S3Uri=${input_s3_uri},S3DataDistributionType=FullyReplicated}}" \
    --output-data-config "S3OutputPath=s3://${ACCOUNT_ID}-${target_region}/${APP_NAME}/training-output/${job_name}" \
    --resource-config "InstanceType=${instance_type},InstanceCount=${instance_count},VolumeSizeInGB=10" \
    --stopping-condition "MaxRuntimeInSeconds=432000" \
    --query 'TrainingJobArn' --output text 2>/tmp/sagemaker-create-job.log); then
    echo "[BERHASIL] Regular job geus dijieun: name=${job_name}, id=${job_arn}, region=${target_region}"
    return 0
  else
    echo "[GAGAL] Regular job teu bisa dijieun: name=${job_name}, region=${target_region}" >&2
    if [[ -s /tmp/sagemaker-create-job.log ]]; then
      echo "[ERROR] ${job_name}: $(tail -n 20 /tmp/sagemaker-create-job.log)" >&2
    fi
    return 1
  fi
}

create_spot_job() {
  local job_name="$1"
  local instance_type="$2"
  local instance_count="${3:-1}"
  local input_s3_uri="$4"
  local target_region="$5"
  local job_arn=""

  echo "Nyieun spot training job: ${job_name} di ${target_region}"
  if job_arn=$(aws sagemaker create-training-job \
    --region "${target_region}" \
    --training-job-name "${job_name}" \
    --role-arn "${ROLE_ARN}" \
    --algorithm-specification "TrainingImage=${ACCOUNT_ID}.dkr.ecr.${target_region}.amazonaws.com/${APP_NAME}:${IMAGE_TAG},TrainingInputMode=Pipe" \
    --input-data-config "ChannelName=train,DataSource={S3DataSource={S3DataType=S3Prefix,S3Uri=${input_s3_uri},S3DataDistributionType=FullyReplicated}}" \
    --output-data-config "S3OutputPath=s3://${ACCOUNT_ID}-${target_region}/${APP_NAME}/spot-output/${job_name}" \
    --resource-config "InstanceType=${instance_type},InstanceCount=${instance_count},VolumeSizeInGB=10" \
    --stopping-condition "MaxRuntimeInSeconds=432000,MaxWaitTimeInSeconds=432000" \
    --enable-managed-spot-training \
    --query 'TrainingJobArn' --output text 2>/tmp/sagemaker-create-spot-job.log); then
    echo "[BERHASIL] Spot job geus dijieun: name=${job_name}, id=${job_arn}, region=${target_region}"
    return 0
  else
    echo "[GAGAL] Spot job teu bisa dijieun: name=${job_name}, region=${target_region}" >&2
    if [[ -s /tmp/sagemaker-create-spot-job.log ]]; then
      echo "[ERROR] ${job_name}: $(tail -n 20 /tmp/sagemaker-create-spot-job.log)" >&2
    fi
    return 1
  fi
}

echo "=== Proses Deployment AWS + IAM Role ==="

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "${ACCOUNT_ID}" ]]; then
  echo "Awas! AWS CLI teu tiasa ngakses akun CloudShell."
  echo "Pastikeun CloudShell anjeun nganggo akun AWS anu leres."
  exit 1
fi

echo "Nomer akun AWS anjeun: ${ACCOUNT_ID}"

echo "Ketik nami aplikasi/repo (teken enter pikeun make bawaan: ${DEFAULT_APP_NAME})"
read -r APP_NAME
if [[ -z "${APP_NAME}" ]]; then
  APP_NAME="${DEFAULT_APP_NAME}"
fi
echo "Nami aplikasi anu dipaké: ${APP_NAME}"

echo "Ketik nami role IAM (teken enter pikeun make bawaan: ${DEFAULT_ROLE_NAME})"
read -r ROLE_NAME
if [[ -z "${ROLE_NAME}" ]]; then
  ROLE_NAME="${DEFAULT_ROLE_NAME}"
fi
echo "Nami role IAM anu dipaké: ${ROLE_NAME}"

echo "Ketik region AWS anu rék dipaké, pisahkeun ku koma"
echo "Contona: us-east-1,us-east-2,us-west-2"
read -r REGION_INPUT

if [[ -z "${REGION_INPUT}" ]]; then
  REGION_INPUT="us-east-1,us-east-2,us-west-2"
fi

IFS=',' read -ra REGIONS <<< "${REGION_INPUT}"

for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"
  if [[ -z "${region}" ]]; then
    continue
  fi

  if [[ ! "${region}" =~ ^[a-z]+-[a-z]+-[0-9]+$ ]]; then
    echo "Format region salah: ${region}"
    echo "Contona anu bener: us-east-1,us-east-2,us-west-2"
    exit 1
  fi
done

echo "Region anu bakal dipaké:"
printf '%s\n' "${REGIONS[@]}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker teu kapanggih di CloudShell."
  echo "Tanpa Docker, build/push image moal tiasa."
  exit 1
fi

if [[ -z "${TRAINING_REGION}" || "${TRAINING_REGION}" == "us-east-2" ]]; then
  if [[ "${#REGIONS[@]}" -gt 0 ]]; then
    TRAINING_REGION="${REGIONS[0]}"
  fi
fi

TRAINING_REGION="${TRAINING_REGION//[[:space:]]/}"

echo "Nyiapkeun trust policy pikeun SageMaker..."
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
  echo "Role ${ROLE_NAME} geus aya. Terasna attach policy..."
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

read -p "Tekan Enter pikeun neruskeun, atawa Ctrl+C pikeun batal..." -r

for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"
  bucket="${ACCOUNT_ID}-${region}"

  echo "== Nyieun / mariksa bucket S3 di ${region} =="
  if ! aws s3api head-bucket --bucket "${bucket}" --region "${region}" >/dev/null 2>&1; then
    aws s3 mb "s3://${bucket}" --region "${region}"
  else
    echo "Bucket geus aya: ${bucket}"
  fi

  aws s3 cp ./edas.sh "s3://${bucket}/${APP_NAME}/edas.sh" --region "${region}"
done

for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"

  echo "== Nyieun / mariksa repo ECR di ${region} =="
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

echo "Ngadamel image Docker..."
docker build -t "${APP_NAME}:${IMAGE_TAG}" .

for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"
  remote="${ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com/${APP_NAME}:${IMAGE_TAG}"

  echo "Ngaronjatkeun image ka ${remote}..."
  docker tag "${APP_NAME}:${IMAGE_TAG}" "${remote}"
  docker push "${remote}"
done

echo
read -p "Mau neruskeun nyieun regular jeung spot training jobs? [y/Enter]: " -r CONFIRM_JOBS
if [[ -z "${CONFIRM_JOBS}" ]]; then
  CONFIRM_JOBS="y"
fi
if [[ ! "${CONFIRM_JOBS}" =~ ^[Yy]$ ]]; then
  echo "Training jobs dibatalkeun. Proses deployment AWS geus selesai."
  echo "Role ARN: ${ROLE_ARN}"
  exit 0
fi

echo "=== Setelan Training Job SageMaker ==="

regular_success_total=0
regular_failed_total=0
regular_attempt_total=0
spot_success_total=0
spot_failed_total=0
spot_attempt_total=0

for region in "${REGIONS[@]}"; do
  region="${region//[[:space:]]/}"
  region_regular_success=0
  region_regular_failed=0
  region_spot_success=0
  region_spot_failed=0

  echo "Job bakal dijieun di region: ${region}"

  if ! check_training_dataset "${region}"; then
    echo "Ngabatalkeun pembuatan training job di region ${region} lantaran dataset input teu valid."
    echo "[RINGKESAN] Region ${region}: regular=0, failed=0, spot=0, failed=0"
    continue
  fi

  for i in "${!REGULAR_INSTANCE_TYPES[@]}"; do
    idx=$((i + 1))
    job_name="${APP_NAME}-${idx}"
    instance_type="${REGULAR_INSTANCE_TYPES[$i]}"
    ((regular_attempt_total += 1))
    if create_regular_job "${job_name}" "${instance_type}" 1 "s3://${ACCOUNT_ID}-${region}/${APP_NAME}/" "${region}"; then
      ((regular_success_total += 1))
      ((region_regular_success += 1))
    else
      ((regular_failed_total += 1))
      ((region_regular_failed += 1))
    fi
  done

  for i in "${!SPOT_INSTANCE_TYPES[@]}"; do
    idx=$((i + 1))
    job_name="${APP_NAME}-spot-${idx}"
    instance_type="${SPOT_INSTANCE_TYPES[$i]}"
    ((spot_attempt_total += 1))
    if create_spot_job "${job_name}" "${instance_type}" 1 "s3://${ACCOUNT_ID}-${region}/${APP_NAME}/" "${region}"; then
      ((spot_success_total += 1))
      ((region_spot_success += 1))
    else
      ((spot_failed_total += 1))
      ((region_spot_failed += 1))
    fi
  done

  echo "[RINGKESAN] Region ${region}: regular success=${region_regular_success}, regular failed=${region_regular_failed}, spot success=${region_spot_success}, spot failed=${region_spot_failed}"
done

echo

echo "=== Ringkesan Ahir Training Job ==="
echo "Regular: total attempt=${regular_attempt_total}, success=${regular_success_total}, failed=${regular_failed_total}"
echo "Spot: total attempt=${spot_attempt_total}, success=${spot_success_total}, failed=${spot_failed_total}"

echo

echo "Proses deployment AWS geus selesai."
echo "Role ARN: ${ROLE_ARN}"
