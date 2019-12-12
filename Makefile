.DEFAULT_GOAL := help
SHELL := /bin/bash

DOCKER_IMAGE = govuknotify/notifications-ftp
DOCKER_IMAGE_NAME = ${DOCKER_IMAGE}:master

BUILD_TAG ?= notifications-ftp-manual

DOCKER_CONTAINER_PREFIX = ${USER}-${BUILD_TAG}

NOTIFY_CREDENTIALS ?= ~/.notify-credentials
CF_APP = "notify-ftp"
CF_ORG = "govuk-notify"

.PHONY: help
help:
	@cat $(MAKEFILE_LIST) | grep -E '^[a-zA-Z_-]+:.*?## .*$$' | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: generate-manifest
generate-manifest: ## Generates cf manifest
	$(if ${CF_APP},,$(error Must specify CF_APP))
	$(if ${CF_SPACE},,$(error Must specify CF_SPACE))
	$(if $(shell which gpg2), $(eval export GPG=gpg2), $(eval export GPG=gpg))
	$(if ${GPG_PASSPHRASE_TXT}, $(eval export DECRYPT_CMD=echo -n $$$${GPG_PASSPHRASE_TXT} | ${GPG} --quiet --batch --passphrase-fd 0 --pinentry-mode loopback -d), $(eval export DECRYPT_CMD=${GPG} --quiet --batch -d))

	@jinja2 --strict manifest.yml.j2 \
	    -D environment=${CF_SPACE} \
	    -D CF_APP=${CF_APP} \
	    --format=yaml \
	    <(${DECRYPT_CMD} ${NOTIFY_CREDENTIALS}/credentials/${CF_SPACE}/paas/ftp-environment-variables.gpg) 2>&1

.PHONY: cf-target
cf-target:
	$(if ${CF_SPACE},,$(error Must specify CF_SPACE))
	@cf target -o ${CF_ORG} -s ${CF_SPACE}

.PHONY: cf-deploy
cf-deploy: cf-target ## Deploys the app to Cloud Foundry
	$(if ${CF_SPACE},,$(error Must specify CF_SPACE))
	@cf app --guid ${CF_APP} || exit 1
	# cancel any existing deploys to ensure we can apply manifest (if a deploy is in progress you'll see ScaleDisabledDuringDeployment)
	cf v3-cancel-zdt-push ${CF_APP} || true

	cf v3-apply-manifest ${CF_APP} -f <(make -s generate-manifest)
	cf v3-zdt-push ${CF_APP} --wait-for-deploy-complete  # fails after 5 mins if deploy doesn't work

.PHONY: preview
preview: ## Set environment to preview
	$(eval export CF_SPACE=preview)
	@true

.PHONY: staging
staging: ## Set environment to staging
	$(eval export CF_SPACE=staging)
	@true

.PHONY: production
production: ## Set environment to production
	$(eval export CF_SPACE=production)
	@true

.PHONY: test
test: ## run unit tests
	./scripts/run_tests.sh

.PHONY: prepare-docker-build-image
prepare-docker-build-image: ## Prepare the Docker builder image
	docker build -f docker/Dockerfile \
		-t ${DOCKER_IMAGE_NAME} \
		.

define run_docker_container
	docker run -it --rm \
		--name "${DOCKER_CONTAINER_PREFIX}-${1}" \
		${DOCKER_IMAGE_NAME} \
		${2}
endef

.PHONY: test-with-docker
test-with-docker: prepare-docker-build-image ## Run tests inside a Docker container
	$(call run_docker_container,test, make test)

.PHONY: clean-docker-containers
clean-docker-containers: ## Clean up any remaining docker containers
	docker rm -f $(shell docker ps -q -f "name=${DOCKER_CONTAINER_PREFIX}") 2> /dev/null || true

.PHONY: clean
clean:
	rm -rf cache target venv .coverage build tests/.cache wheelhouse
