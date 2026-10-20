MOJO ?= mojo
CC ?= cc

all: libmax_c.a max

libmax_c.a: max_shim.o vendor/cJSON.o
	ar rcs $@ $^

max_shim.o: max_shim.c
	$(CC) -O2 -c -o $@ $<

vendor/cJSON.o: vendor/cJSON.c vendor/cJSON.h
	$(CC) -O2 -c -o $@ $<

max: max.mojo bindings.mojo libmax_c.a
	$(MOJO) build max.mojo -o max -I . -Xlinker libmax_c.a -Xlinker -lcurl

test: max
	bash tests/run.sh

bundle: max
	rm -rf bundle
	mkdir -p bundle
	cp max bundle/
	for lib in libKGENCompilerRTShared libAsyncRTMojoBindings libMSupportGlobals libAsyncRTRuntimeGlobals ; do \
		f=$$(find "$$(dirname $$(dirname $$(which $(MOJO))))" -name "$$lib.dylib" | head -1) ; \
		cp "$$f" bundle/ ; \
	done
	install_name_tool -delete_rpath "$$(otool -l bundle/max | grep -A2 LC_RPATH | grep path | head -1 | awk '{print $$2}')" bundle/max || true
	install_name_tool -add_rpath @executable_path bundle/max

clean:
	rm -f max libmax_c.a max_shim.o vendor/cJSON.o
	rm -rf bundle

.PHONY: all test bundle clean
