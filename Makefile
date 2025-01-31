
# Image URL to use all building/pushing image targets;
# Use your own docker registry and image name for dev/test by overridding the IMG and REGISTRY environment variable.
IMG ?= $(shell cat COMPONENT_NAME 2> /dev/null)
REGISTRY ?= quay.io/stolostron
TAG ?= latest
VERSION ?= $(shell cat COMPONENT_VERSION 2> /dev/null)
IMAGE_NAME_AND_VERSION ?= $(REGISTRY)/$(IMG):$(VERSION)

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.23

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" go test `go list ./... | grep -v test/e2e` -coverprofile cover.out

##@ Build

.PHONY: build
build: ## Build manager binary.
	@build/common/scripts/gobuild.sh build/_output/bin/$(IMG) main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

.PHONY: build-images
build-images: generate fmt vet
	@docker build -t ${IMAGE_NAME_AND_VERSION} -f build/Dockerfile .

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMAGE_NAME_AND_VERSION}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
.PHONY: controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.8.0)

KUSTOMIZE = $(shell pwd)/bin/kustomize
.PHONY: kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

ENVTEST = $(shell pwd)/bin/setup-envtest
.PHONY: envtest
envtest: ## Download envtest-setup locally if necessary.
	$(call go-get-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest@latest)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

##@ Kind

KIND_NAME ?= policy-addon-ctrl
KIND_KUBECONFIG ?= $(PWD)/$(KIND_NAME).kubeconfig

.PHONY: kind-create-cluster
kind-create-cluster: $(KIND_KUBECONFIG) ## Create a kind cluster

$(KIND_KUBECONFIG):
	@echo "creating cluster"
	kind create cluster --name $(KIND_NAME) $(KIND_ARGS)
	kind get kubeconfig --name $(KIND_NAME) > $(KIND_KUBECONFIG)

.PHONY: kind-delete-cluster
kind-delete-cluster: ## Delete the kind cluster
	kind delete cluster --name $(KIND_NAME) || true
	rm $(KIND_KUBECONFIG) || true

REGISTRATION_OPERATOR = $(shell pwd)/.go/registration-operator
$(REGISTRATION_OPERATOR):
	@mkdir -p .go
	git clone --depth 1 https://github.com/open-cluster-management-io/registration-operator.git .go/registration-operator

.PHONY: kind-deploy-registration-operator
kind-deploy-registration-operator: $(REGISTRATION_OPERATOR) $(KIND_KUBECONFIG) ## Deploy the ocm registration operator to the kind cluster
	cd $(REGISTRATION_OPERATOR) && make deploy
	@printf "\n*** Pausing and waiting to let everything deploy ***\n\n"
	sleep 10
	kubectl wait --for condition=Available deploy/cluster-manager -n open-cluster-management --timeout=60s
	sleep 10
	kubectl wait --for condition=Available deploy/cluster-manager-placement-controller -n open-cluster-management-hub --timeout=60s
	sleep 10

.PHONY: kind-approve-cluster1
kind-approve-cluster1: $(KIND_KUBECONFIG) ## Approve managed cluster cluster1 in the kind cluster
	kubectl certificate approve "$(shell kubectl get csr -l open-cluster-management.io/cluster-name=cluster1 -o name)"
	sleep 10
	kubectl patch managedcluster cluster1 -p='{"spec":{"hubAcceptsClient":true}}' --type=merge

.PHONY: wait-for-work-agent
wait-for-work-agent: ## Wait for the klusterlet work agent to start
	@printf "\n*** Waiting up to 6 minutes for klusterlet work agent to start ***\n\n"
	@WORK_AGENT_POD=`kubectl get pod -n open-cluster-management-agent -l=app=klusterlet-manifestwork-agent -o name`; \
	TIME_WAITING=0; \
	until [[ -n $$WORK_AGENT_POD ]] ; do \
		if [[ $$TIME_WAITING -gt 360 ]]; then \
			printf "\n*** Klusterlet work agent took too long to start ***\n\n" ; \
			exit 1; \
		fi; \
		echo $$TIME_WAITING seconds waited...; \
		sleep 20; \
		(( TIME_WAITING += 20 )); \
		WORK_AGENT_POD=`kubectl get pod -n open-cluster-management-agent -l=app=klusterlet-manifestwork-agent -o name`; \
	done

CONTROLLER_NAMESPACE ?= governance-policy-addon-controller-system

.PHONY: kind-run-local
kind-run-local: manifests generate fmt vet $(KIND_KUBECONFIG) ## Run the policy-addon-controller locally against the kind cluster
	kubectl get ns $(CONTROLLER_NAMESPACE); if [ $$? -ne 0 ] ; then kubectl create ns $(CONTROLLER_NAMESPACE); fi 
	go run ./main.go controller --kubeconfig=$(KIND_KUBECONFIG) --namespace $(CONTROLLER_NAMESPACE)

.PHONY: kind-load-image
kind-load-image: build-images $(KIND_KUBECONFIG) ## Build and load the docker image into kind
	kind load docker-image $(IMAGE_NAME_AND_VERSION) --name $(KIND_NAME)

.PHONY: regenerate-controller
kind-regenerate-controller: manifests generate kustomize $(KIND_KUBECONFIG) ## Refresh (or initially deploy) the policy-addon-controller
	cp config/default/kustomization.yaml config/default/kustomization.yaml.tmp
	cd config/default && $(KUSTOMIZE) edit set image policy-addon-image=$(IMAGE_NAME_AND_VERSION)
	$(KUSTOMIZE) build config/default | kubectl apply -f -
	mv config/default/kustomization.yaml.tmp config/default/kustomization.yaml
	kubectl delete -n $(CONTROLLER_NAMESPACE) pods -l=app=governance-policy-addon-controller

.PHONY: kind-deploy-controller
kind-deploy-controller: kind-deploy-registration-operator kind-approve-cluster1 kind-load-image kind-regenerate-controller ## Deploy the policy-addon-controller to the kind cluster
	
##@ Quality Control

.PHONY: lint
lint: 
	@echo "no linters configured"

GINKGO = $(shell pwd)/bin/ginkgo
.PHONY: e2e-dependencies
e2e-dependencies: ## Download ginkgo locally if necessary.
	$(call go-get-tool,$(GINKGO),github.com/onsi/ginkgo/ginkgo@v1.16.4)

.PHONY: e2e-test
e2e-test: e2e-dependencies
	$(GINKGO) -v --failFast --slowSpecThreshold=10 test/e2e
