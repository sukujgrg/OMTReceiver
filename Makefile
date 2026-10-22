.PHONY: build test project check site archive archive-unsigned

project:
	python3 scripts/generate_project.py

build:
	xcodebuild -project OMTReceiver.xcodeproj -scheme OMTReceiver \
		-destination 'generic/platform=tvOS' -configuration Release \
		-derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

test:
	./scripts/test.sh

site:
	python3 scripts/render_site.py

check:
	python3 scripts/validate_distribution.py --audit-public
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/tests -v

archive:
	python3 scripts/archive.py archive

archive-unsigned:
	python3 scripts/archive.py archive --unsigned
