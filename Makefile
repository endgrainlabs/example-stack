# Targets that need no cluster: lint and test. Targets that do: build, up,
# smoke, validate, down, which call the script that owns each area.
#
# Tools that are not Go modules are pinned here by release archive and
# checksum, downloaded into bin/tools, and run from there after their own
# checksum is confirmed; whatever version is on the PATH is not used. protoc
# is pinned the same way in scripts/build.sh.

SHELLCHECK_VERSION := 0.11.0
ACTIONLINT_VERSION := 1.7.12
KUSTOMIZE_VERSION  := 5.8.1
SEMGREP_VERSION    := 1.177.0
# The semgrep container, for a machine without semgrep on its PATH. Pinned by
# digest like every other image the stack pulls.
SEMGREP_IMAGE := docker.io/semgrep/semgrep:$(SEMGREP_VERSION)@sha256:acaac22ffc7b7cc5926de0751b223bce0b2491c33d18422fa72f632c78d81198

TOOLS := bin/tools
OS    := $(shell uname -s)
ARCH  := $(shell uname -m)

# Two checksums per tool and platform: the release archive, checked on
# download, and the binary inside it, checked before every run, so a file
# that has been replaced under bin/tools does not run. actionlint archive
# and kustomize checksums are from their published checksums files;
# shellcheck publishes none, so those and every binary checksum were taken
# once from the downloaded archives and are re-taken whenever a version is
# repinned.
ifeq ($(OS)/$(ARCH),Darwin/arm64)
  SHELLCHECK_ASSET      := shellcheck-v$(SHELLCHECK_VERSION).darwin.aarch64.tar.gz
  SHELLCHECK_SHA256     := 339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f
  SHELLCHECK_BIN_SHA256 := 61c17246d69f012cd458ae82f244c46023dac75d1b69733ca1cc7d28fb270fd7
  ACTIONLINT_ASSET      := actionlint_$(ACTIONLINT_VERSION)_darwin_arm64.tar.gz
  ACTIONLINT_SHA256     := aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
  ACTIONLINT_BIN_SHA256 := 8db11704dc296f096216db4db65d86cd7f0ebfdf4c38453a1da276b137b88388
  KUSTOMIZE_ASSET       := kustomize_v$(KUSTOMIZE_VERSION)_darwin_arm64.tar.gz
  KUSTOMIZE_SHA256      := 8886f8a78474e608cc81234f729fda188a9767da23e28925802f00ece2bab288
  KUSTOMIZE_BIN_SHA256  := bc77e3505fbd414551cf7b15d1e772a288bc5afd97e31e49655b10524d1888e9
endif
ifeq ($(OS)/$(ARCH),Darwin/x86_64)
  SHELLCHECK_ASSET      := shellcheck-v$(SHELLCHECK_VERSION).darwin.x86_64.tar.gz
  SHELLCHECK_SHA256     := c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51
  SHELLCHECK_BIN_SHA256 := 2589be755bb115f4421b8271eb7c08df1e03729f00350c1e4cf53b4a0bf9c2df
  ACTIONLINT_ASSET      := actionlint_$(ACTIONLINT_VERSION)_darwin_amd64.tar.gz
  ACTIONLINT_SHA256     := 5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
  ACTIONLINT_BIN_SHA256 := d1f7cee75ae2873609bd9567b4600bebc5315a5e733e73202987a44fafdd53b2
  KUSTOMIZE_ASSET       := kustomize_v$(KUSTOMIZE_VERSION)_darwin_amd64.tar.gz
  KUSTOMIZE_SHA256      := ee7cf0c1e3592aa7bb66ba82b359933a95e7f2e0b36e5f53ed0a4535b017f2f8
  KUSTOMIZE_BIN_SHA256  := 1320bc02dd746fdb5d312a89ecdbf67bb4d1acc836036427087117976dbc8bda
endif
ifeq ($(OS)/$(ARCH),Linux/x86_64)
  SHELLCHECK_ASSET      := shellcheck-v$(SHELLCHECK_VERSION).linux.x86_64.tar.gz
  SHELLCHECK_SHA256     := b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6
  SHELLCHECK_BIN_SHA256 := 4da528ddb3a4d1b7b24a59d4e16eb2f5fd960f4bd9a3708a15baddbdf1d5a55b
  ACTIONLINT_ASSET      := actionlint_$(ACTIONLINT_VERSION)_linux_amd64.tar.gz
  ACTIONLINT_SHA256     := 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
  ACTIONLINT_BIN_SHA256 := c872d6db8c6bf83a8eaa704fc93999f027d55dffbc63b8a6abdccb47df5f4cd4
  KUSTOMIZE_ASSET       := kustomize_v$(KUSTOMIZE_VERSION)_linux_amd64.tar.gz
  KUSTOMIZE_SHA256      := 029a7f0f4e1932c52a0476cf02a0fd855c0bb85694b82c338fc648dcb53a819d
  KUSTOMIZE_BIN_SHA256  := f7b1605aa5143e0dcbd754a4d43c47ad7a560c540b1356b064d69fe236164494
endif
ifeq ($(OS)/$(ARCH),Linux/aarch64)
  SHELLCHECK_ASSET      := shellcheck-v$(SHELLCHECK_VERSION).linux.aarch64.tar.gz
  SHELLCHECK_SHA256     := 68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc
  SHELLCHECK_BIN_SHA256 := 127f13925eadd52c341bca0ebaf9ab0dbd78c6468f30a8f262a528bf8de47546
  ACTIONLINT_ASSET      := actionlint_$(ACTIONLINT_VERSION)_linux_arm64.tar.gz
  ACTIONLINT_SHA256     := 325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
  ACTIONLINT_BIN_SHA256 := ac0323433c2853ec3fb978c611430c5b3dc5d43c58d1a1ec031b00ab572beb60
  KUSTOMIZE_ASSET       := kustomize_v$(KUSTOMIZE_VERSION)_linux_arm64.tar.gz
  KUSTOMIZE_SHA256      := 0953ea3e476f66d6ddfcd911d750f5167b9365aa9491b2326398e289fef2c142
  KUSTOMIZE_BIN_SHA256  := b291d2a7acd096976d904971b0d38aca9da1e6262791cc6fa7259bc0a9578e77
endif

SHELLCHECK := $(TOOLS)/shellcheck-$(SHELLCHECK_VERSION)
ACTIONLINT := $(TOOLS)/actionlint-$(ACTIONLINT_VERSION)
KUSTOMIZE  := $(TOOLS)/kustomize-$(KUSTOMIZE_VERSION)

SCRIPTS   := scripts/*.sh scenarios/lib.sh scenarios/*/demo.sh
WORKFLOWS := .github/workflows/*.yml
# Every kustomization in the tree: the services, each infra directory, and
# each scenario overlay over the services.
KUSTOMIZATIONS := k8s/apps/base $(wildcard k8s/infra/*) $(wildcard scenarios/*/overlay)

.PHONY: lint shellcheck actionlint kustomize semgrep test build up smoke validate down

lint: shellcheck actionlint kustomize semgrep

shellcheck: $(SHELLCHECK)
	@echo "$(SHELLCHECK_BIN_SHA256)  $(SHELLCHECK)" | shasum -a 256 -c - >/dev/null
	$(SHELLCHECK) -S style $(SCRIPTS)

actionlint: $(ACTIONLINT)
	@echo "$(ACTIONLINT_BIN_SHA256)  $(ACTIONLINT)" | shasum -a 256 -c - >/dev/null
	$(ACTIONLINT) -no-color $(WORKFLOWS)

# Builds every kustomization without a cluster, so a patch that names a
# missing resource or a malformed overlay fails here and not at reconcile.
kustomize: $(KUSTOMIZE)
	@echo "$(KUSTOMIZE_BIN_SHA256)  $(KUSTOMIZE)" | shasum -a 256 -c - >/dev/null
	@for d in $(KUSTOMIZATIONS); do echo "kustomize build $$d"; $(KUSTOMIZE) build $$d >/dev/null || exit 1; done

# The registry's Go ruleset; Rust is covered by clippy. The rules are fetched
# at run time and deliberately not pinned: a rule added upstream should start
# applying here without a repin, and rules are data, not code. Generated code
# is excluded; metrics and the version check are off.
#
# semgrep runs from the PATH when the pinned version is installed, otherwise
# from the digest-pinned container through podman or docker, whichever is
# present. With CI set, as on a runner, a skip is a failure.
SEMGREP_SCAN := semgrep scan --config p/golang --error --quiet --exclude '*.pb.go' .
SEMGREP_ENV  := -e SEMGREP_SEND_METRICS=off -e SEMGREP_ENABLE_VERSION_CHECK=0

semgrep:
	@if semgrep --version 2>/dev/null | grep -q '^$(SEMGREP_VERSION)$$'; then \
	    SEMGREP_SEND_METRICS=off SEMGREP_ENABLE_VERSION_CHECK=0 $(SEMGREP_SCAN) ; \
	elif podman info >/dev/null 2>&1; then \
	    podman run --rm -v "$(CURDIR):/src:ro" -w /src $(SEMGREP_ENV) $(SEMGREP_IMAGE) $(SEMGREP_SCAN) ; \
	elif docker info >/dev/null 2>&1; then \
	    docker run --rm -v "$(CURDIR):/src:ro" -w /src $(SEMGREP_ENV) $(SEMGREP_IMAGE) $(SEMGREP_SCAN) ; \
	elif [ -n "$$CI" ]; then \
	    echo "semgrep: no semgrep $(SEMGREP_VERSION) on the PATH and no container runtime; failing because CI is set" >&2; exit 1 ; \
	else \
	    echo "semgrep skipped: no semgrep $(SEMGREP_VERSION) on the PATH and no container runtime running" ; \
	fi

test:
	go test -race ./...
	cd rust-inventory && cargo test
	python3 -m unittest discover -s scripts -p 'promjson_test.py'

build:
	bash scripts/build.sh

up:
	bash scripts/setup.sh

smoke:
	bash scripts/smoke-test.sh

validate:
	bash scripts/validate-stack.sh

down:
	bash scripts/teardown.sh

# Pinned downloads. Each rule fetches the archive, refuses it unless the
# checksum matches, and leaves only the binary in bin/tools.
$(SHELLCHECK):
	@test -n "$(SHELLCHECK_ASSET)" || { echo "no pinned shellcheck for $(OS)/$(ARCH)" >&2; exit 1; }
	mkdir -p $(TOOLS)
	curl -fsSL -o $(TOOLS)/$(SHELLCHECK_ASSET) https://github.com/koalaman/shellcheck/releases/download/v$(SHELLCHECK_VERSION)/$(SHELLCHECK_ASSET)
	echo "$(SHELLCHECK_SHA256)  $(TOOLS)/$(SHELLCHECK_ASSET)" | shasum -a 256 -c - >/dev/null
	tar -xzf $(TOOLS)/$(SHELLCHECK_ASSET) -C $(TOOLS) shellcheck-v$(SHELLCHECK_VERSION)/shellcheck
	mv $(TOOLS)/shellcheck-v$(SHELLCHECK_VERSION)/shellcheck $@
	rm -rf $(TOOLS)/shellcheck-v$(SHELLCHECK_VERSION) $(TOOLS)/$(SHELLCHECK_ASSET)

$(KUSTOMIZE):
	@test -n "$(KUSTOMIZE_ASSET)" || { echo "no pinned kustomize for $(OS)/$(ARCH)" >&2; exit 1; }
	mkdir -p $(TOOLS)
	curl -fsSL -o $(TOOLS)/$(KUSTOMIZE_ASSET) https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv$(KUSTOMIZE_VERSION)/$(KUSTOMIZE_ASSET)
	echo "$(KUSTOMIZE_SHA256)  $(TOOLS)/$(KUSTOMIZE_ASSET)" | shasum -a 256 -c - >/dev/null
	tar -xzf $(TOOLS)/$(KUSTOMIZE_ASSET) -C $(TOOLS) kustomize
	mv $(TOOLS)/kustomize $@
	rm -f $(TOOLS)/$(KUSTOMIZE_ASSET)

$(ACTIONLINT):
	@test -n "$(ACTIONLINT_ASSET)" || { echo "no pinned actionlint for $(OS)/$(ARCH)" >&2; exit 1; }
	mkdir -p $(TOOLS)
	curl -fsSL -o $(TOOLS)/$(ACTIONLINT_ASSET) https://github.com/rhysd/actionlint/releases/download/v$(ACTIONLINT_VERSION)/$(ACTIONLINT_ASSET)
	echo "$(ACTIONLINT_SHA256)  $(TOOLS)/$(ACTIONLINT_ASSET)" | shasum -a 256 -c - >/dev/null
	tar -xzf $(TOOLS)/$(ACTIONLINT_ASSET) -C $(TOOLS) actionlint
	mv $(TOOLS)/actionlint $@
	rm -f $(TOOLS)/$(ACTIONLINT_ASSET)
