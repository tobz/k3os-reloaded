.PHONY: build clean check-env
build: check-env
	@echo [*] Starting build...
	docker build -t kernel-builder .
	docker run -e ARCH=${KERNEL_ARCH} -e KERNEL_VERSION=${KERNEL_VERSION} kernel-builder

clean:
	@rm -rf output

check-env:
ifndef KERNEL_ARCH
	$(error KERNEL_ARCH is undefined)
endif
ifndef KERNEL_VERSION
	$(error KERNEL_VERSION is undefined)
endif
