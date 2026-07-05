.PHONY: build test app run cert clean

build:
	swift build

# The CLT-only build box has no XCTest host, so `swift test` builds but can't
# run the bundle. Run the identical suite via the standalone swift-testing
# runner. On machines with full Xcode, `swift test` also works.
test:
	swift run SkylarkTestRunner --testing-library swift-testing

app:
	./Scripts/bundle.sh

run: app
	open dist/Skylark.app

cert:
	./Scripts/make-cert.sh

clean:
	rm -rf .build dist
