CI_CD ?= .ci-cd
CI_CONFIG ?= .ci-cd.json
CI_TARGET ?= local
CI_PLATFORM ?= linux/amd64

.PHONY: ci-format ci-lint ci-test ci-build ci-package ci-deploy ci-stack

ci-format:
	$(CI_CD)/bin/ci run format --config $(CI_CONFIG) --target $(CI_TARGET) --platform $(CI_PLATFORM)

ci-lint:
	$(CI_CD)/bin/ci run lint --config $(CI_CONFIG) --target $(CI_TARGET) --platform $(CI_PLATFORM)

ci-test:
	$(CI_CD)/bin/ci run test --config $(CI_CONFIG) --target $(CI_TARGET) --platform $(CI_PLATFORM)

ci-build:
	$(CI_CD)/bin/ci run build --config $(CI_CONFIG) --target $(CI_TARGET) --platform $(CI_PLATFORM)

ci-package:
	$(CI_CD)/bin/ci run package --config $(CI_CONFIG) --target $(CI_TARGET) --platform $(CI_PLATFORM)

ci-deploy:
	$(CI_CD)/bin/ci run deploy --config $(CI_CONFIG) --target $(CI_TARGET) --platform $(CI_PLATFORM)

ci-stack:
	$(CI_CD)/bin/ci run stack --config $(CI_CONFIG) --target $(CI_TARGET) --platform $(CI_PLATFORM)
