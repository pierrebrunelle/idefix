MOJO ?= mojo
CC ?= cc

all: libagent_c.a agent

libagent_c.a: agent_shim.o vendor/cJSON.o
	ar rcs $@ $^

agent_shim.o: agent_shim.c
	$(CC) -O2 -c -o $@ $<

vendor/cJSON.o: vendor/cJSON.c vendor/cJSON.h
	$(CC) -O2 -c -o $@ $<

agent: agent.mojo bindings.mojo libagent_c.a
	$(MOJO) build agent.mojo -o agent -I . -Xlinker libagent_c.a -Xlinker -lcurl

test: agent
	bash tests/run.sh

bundle: agent
	mkdir -p bundle
	cp agent bundle/
	for lib in libKGENCompilerRTShared libAsyncRTMojoBindings libMSupportGlobals libAsyncRTRuntimeGlobals ; do \
		f=$$(find "$$(dirname $$(dirname $$(which $(MOJO))))" -name "$$lib.dylib" | head -1) ; \
		cp "$$f" bundle/ ; \
	done
	install_name_tool -delete_rpath "$$(otool -l bundle/agent | grep -A2 LC_RPATH | grep path | head -1 | awk '{print $$2}')" bundle/agent || true
	install_name_tool -add_rpath @executable_path bundle/agent

clean:
	rm -f agent libagent_c.a agent_shim.o vendor/cJSON.o
	rm -rf bundle

.PHONY: all test bundle clean
