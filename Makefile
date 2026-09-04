.PHONY: build test app run cert clean release

build:
	swift build

# The CLT-only build box has no XCTest host, so `swift test` builds but can't
# run the bundle. Run the identical suite via the standalone swift-testing
# runner. On machines with full Xcode, `swift test` also works.
# Recent CLT's Testing.framework loads lib_TestingInterop from
# CommandLineTools/Library/Developer/usr/lib, which is on no default rpath
# (and SIP strips DYLD_* env through /usr/bin/swift). The runner's rpath DOES
# include the build dir, so symlink the dylib there before running.
#
# Scope a run with TESTFLAGS, NOT with a bare `--filter`: make parses its own
# argv, so `make test --filter foo` is consumed by make itself (it prints its
# help and exits 2) and the filtered test never runs. Correct form:
#     make test TESTFLAGS='--filter liveQwenEval'
test:
	@mkdir -p .build/arm64-apple-macosx/debug
	@ln -sf /Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib .build/arm64-apple-macosx/debug/lib_TestingInterop.dylib
	swift run SkylarkTestRunner --testing-library swift-testing $(TESTFLAGS)

app:
	./Scripts/bundle.sh

run: app
	open dist/Skylark.app

cert:
	./Scripts/make-cert.sh

release:
	./Scripts/release.sh

clean:
	rm -rf .build dist
