TARGETS := $(shell ls scripts)
.PHONY: $(TARGETS)

# Installs `dapper`, a Docker build tool by Rancher for preparing a container as a build environment.
.dapper:
	@echo [*] Downloading 'dapper'...
	@curl -sL https://releases.rancher.com/dapper/latest/dapper-`uname -s`-`uname -m|sed 's/v7l//'` > .dapper.tmp
	@@chmod +x .dapper.tmp
	@./.dapper.tmp -v
	@mv .dapper.tmp .dapper
	@echo [*] 'dapper' installed.

# Send all commands, save for those below, into `dapper`.
#
# The target is a named build script to run within the customized build environment, fed as an
# argument to the build container's entrypoint.
$(TARGETS): .dapper clean
	./.dapper $@

# Configures the build environment and then runs the build container, spawning a shell within it.
#
# The normal sources, scripts, etc, are bind mounted into the container as well, allowing testing of
# changes as they're being made outside of the container, such as when tweaking the build scripts.
shell-bind: .dapper
	./.dapper -m bind -s

# Cleans all build artifacts and output.
clean:
	@rm -rf dist state
	@rm -f Dockerfile.dapper[0-9]*
