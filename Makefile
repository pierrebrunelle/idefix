MOJO ?= mojo
CC ?= cc

all: libidefix_c.a idefix

libidefix_c.a: idefix_shim.o vendor/cJSON.o
	ar rcs $@ $^

idefix_shim.o: idefix_shim.c
	$(CC) -O2 -c -o $@ $<

vendor/cJSON.o: vendor/cJSON.c vendor/cJSON.h
	$(CC) -O2 -c -o $@ $<

idefix: idefix.mojo bindings.mojo libidefix_c.a
	$(MOJO) build idefix.mojo -o idefix -I . -Xlinker libidefix_c.a -Xlinker -lcurl

test: idefix
	bash tests/run.sh

bundle: idefix
	rm -rf bundle
	mkdir -p bundle
	cp idefix bundle/
	cp scripts/with-max.sh bundle/with-max
	if [ "$$(uname -s)" = "Linux" ]; then ext=so; else ext=dylib; fi ; \
	for lib in libKGENCompilerRTShared libAsyncRTMojoBindings libMSupportGlobals libAsyncRTRuntimeGlobals ; do \
		f=$$(find "$$(dirname "$$(dirname "$$(command -v $(MOJO))")")" -name "$$lib.$$ext" | head -1) ; \
		[ -n "$$f" ] || { echo "make: $$lib.$$ext not found under $$(dirname "$$(dirname "$$(command -v $(MOJO))")")" >&2; exit 1; } ; \
		cp "$$f" bundle/ ; \
	done
	if [ "$$(uname -s)" = "Linux" ]; then \
		patchelf --set-rpath '$$ORIGIN' bundle/idefix \
		|| echo "warn: patchelf missing; with-max exports LD_LIBRARY_PATH as fallback" ; \
	else \
		install_name_tool -delete_rpath "$$(otool -l bundle/idefix | grep -A2 LC_RPATH | grep path | head -1 | awk '{print $$2}')" bundle/idefix || true ; \
		install_name_tool -add_rpath @executable_path bundle/idefix ; \
	fi

clean:
	rm -f idefix libidefix_c.a idefix_shim.o vendor/cJSON.o
	rm -rf bundle

.PHONY: all test bundle clean
