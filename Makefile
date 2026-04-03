SWIFT = $(HOME)/.swiftly/bin/swift

install: build
	mkdir -p $(HOME)/.local/bin
	cp .build/release/aii $(HOME)/.local/bin/aii

build:
	$(SWIFT) build -c release

uninstall:
	rm -f $(HOME)/.local/bin/aii

clean:
	rm -rf .build
