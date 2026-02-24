#!/bin/bash
set -e

# =============================
# Required Lab Variables
# =============================

export PROJECT_ID=$(gcloud config get-value project)
export REGION=europe-west1
export ZONE=europe-west1-b

gcloud config set compute/region $REGION
gcloud config set deploy/region $REGION

echo "PROJECT_ID: $PROJECT_ID"
echo "REGION: $REGION"
echo "ZONE: $ZONE"

# =============================
# Enable Required APIs
# =============================

gcloud services enable \
container.googleapis.com \
artifactregistry.googleapis.com \
cloudbuild.googleapis.com \
clouddeploy.googleapis.com

# =============================
# Create GKE Clusters
# =============================

gcloud container clusters create test --node-locations=$ZONE --num-nodes=1 --async
gcloud container clusters create staging --node-locations=$ZONE --num-nodes=1 --async
gcloud container clusters create prod --node-locations=$ZONE --num-nodes=1 --async

# =============================
# Create Artifact Registry
# =============================

gcloud artifacts repositories create web-app \
--description="Image registry for tutorial web app" \
--repository-format=docker \
--location=$REGION

# =============================
# Clone Tutorial Repo
# =============================

cd ~/
git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git
cd cloud-deploy-tutorials
git checkout c3cae80 --quiet
cd tutorials/base

# =============================
# Create skaffold.yaml
# =============================

envsubst < clouddeploy-config/skaffold.yaml.template > web/skaffold.yaml

# =============================
# Enable Cloud Build + Bucket
# =============================

gsutil mb -p $PROJECT_ID gs://${PROJECT_ID}_cloudbuild || true

# =============================
# Build & Push Images
# =============================

cd web
skaffold build --interactive=false \
--default-repo $REGION-docker.pkg.dev/$PROJECT_ID/web-app \
--file-output artifacts.json
cd ..

# =============================
# Create Delivery Pipeline
# =============================

cp clouddeploy-config/delivery-pipeline.yaml.template \
clouddeploy-config/delivery-pipeline.yaml

gcloud beta deploy apply \
--file=clouddeploy-config/delivery-pipeline.yaml

# =============================
# Wait for Clusters
# =============================

echo "Waiting for clusters to be RUNNING..."
until gcloud container clusters list --format="value(status)" | grep -v RUNNING; do
  sleep 10
done

# =============================
# Configure Contexts
# =============================

CONTEXTS=("test" "staging" "prod")

for CONTEXT in ${CONTEXTS[@]}
do
  gcloud container clusters get-credentials ${CONTEXT} --region ${REGION}
  kubectl config rename-context gke_${PROJECT_ID}_${REGION}_${CONTEXT} ${CONTEXT}
done

# =============================
# Create Namespace
# =============================

for CONTEXT in ${CONTEXTS[@]}
do
  kubectl --context ${CONTEXT} apply -f kubernetes-config/web-app-namespace.yaml
done

# =============================
# Create Targets
# =============================

for CONTEXT in ${CONTEXTS[@]}
do
  envsubst < clouddeploy-config/target-$CONTEXT.yaml.template \
  > clouddeploy-config/target-$CONTEXT.yaml

  gcloud beta deploy apply \
  --file=clouddeploy-config/target-$CONTEXT.yaml
done

# =============================
# Create Release
# =============================

gcloud beta deploy releases create web-app-001 \
--delivery-pipeline web-app \
--build-artifacts web/artifacts.json \
--source web/

# =============================
# Promote to Staging
# =============================

gcloud beta deploy releases promote \
--delivery-pipeline web-app \
--release web-app-001 \
--quiet

# =============================
# Promote to Prod
# =============================

gcloud beta deploy releases promote \
--delivery-pipeline web-app \
--release web-app-001 \
--quiet

# Approve rollout
ROLLOUT=$(gcloud beta deploy rollouts list \
--delivery-pipeline web-app \
--release web-app-001 \
--filter="targetId=prod" \
--format="value(name)" | head -n 1)

gcloud beta deploy rollouts approve $ROLLOUT \
--delivery-pipeline web-app \
--release web-app-001 \
--quiet

echo "LAB COMPLETED SUCCESSFULLY"
