.PHONY: test build signed-build analyze check

test:
	./scripts/test.sh

build:
	./scripts/build.sh

signed-build:
	./scripts/build.sh --signed

analyze:
	xcodebuild -project somnus.xcodeproj -scheme Somnus -configuration Debug \
		-derivedDataPath .build/analyze CODE_SIGNING_ALLOWED=NO analyze

check:
	./scripts/check-release.sh
