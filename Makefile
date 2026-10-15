.PHONY: all test cli clean

all: test

test:
	swift test

cli:
	swift build --product controllab-cli

clean:
	swift package clean
	rm -rf build
