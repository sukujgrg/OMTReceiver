.PHONY: build test project

project:
	python3 scripts/generate_project.py

build:
	xcodebuild -project OMTReceiver.xcodeproj -scheme OMTReceiver \
		-destination 'generic/platform=tvOS' -configuration Release \
		-derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

test:
	./scripts/test.sh
