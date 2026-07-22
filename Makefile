.PHONY: build test app run cert clean

build:
	swift build

# The CLT-only build box has no XCTest host, so `swift test` builds but can't
# run the bundle. Run the identical suite via the standalone swift-testing
# runner. On machines with full Xcode, `swift test` also works.
# Recent CLT's Testing.framework loads lib_TestingInterop from
# CommandLineTools/Library/Developer/usr/lib, which is on no default rpath
# (and SIP strips DYLD_* env through /usr/bin/swift). The runner's rpath DOES
# include the build dir, so symlink the dylib there before running.
test:
	@mkdir -p .build/arm64-apple-macosx/debug
	@ln -sf /Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib .build/arm64-apple-macosx/debug/lib_TestingInterop.dylib
	swift run SkylarkTestRunner --testing-library swift-testing

app:
	./Scripts/bundle.sh

run: app
	open dist/Skylark.app

cert:
	./Scripts/make-cert.sh

clean:
	rm -rf .build dist
