# make          build Handa.app into ./build
# make run      build and open it
# make install  copy it to /Applications and make it your default viewer
# make test     run the unit tests

APP = build/Handa.app
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: build run install test clean

build:
	@Scripts/build.sh

run: build
	open $(APP)

install: build
	rm -rf /Applications/Handa.app
	ditto $(APP) /Applications/Handa.app
	$(LSREGISTER) -f /Applications/Handa.app
	/Applications/Handa.app/Contents/MacOS/Handa make-default

test:
	swift test

clean:
	rm -rf build .build
