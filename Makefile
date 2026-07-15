# Incremental wrapper around `c3c build` — c3c always fully recompiles and
# relinks even when nothing changed (~19s), so gate each target on mtimes
# and skip the c3c invocation entirely when the binary is already newer
# than every source file that feeds it.
#
# Prerequisites are pulled from project.json at execute time (c-sources +
# the target's own "sources", expanding directory entries to their .c3
# files) so this file never drifts from what c3c itself actually builds.

target_sources = $(shell jq -r '.["c-sources"][]' project.json) \
                 $(shell jq -r '.targets.$(1).sources[]' project.json | while read -r s; do \
                     if [ -d "$$s" ]; then find "$$s" -name '*.c3'; else echo "$$s"; fi; \
                 done)

.PHONY: all lib run_js test262_runner duktape_c3 clean

all: lib run_js test262_runner duktape_c3

lib: out/lib.a
run_js: out/run_js
test262_runner: out/test262_runner
duktape_c3: out/duktape_c3

out/lib.a: project.json $(call target_sources,lib)
	c3c build lib

out/run_js: project.json $(call target_sources,run_js)
	c3c build run_js

out/test262_runner: project.json $(call target_sources,test262_runner)
	c3c build test262_runner

out/duktape_c3: project.json $(call target_sources,duktape_c3)
	c3c build duktape_c3

clean:
	c3c clean
