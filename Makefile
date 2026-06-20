DEPS = main.go go.mod go.sum

.PHONY:
all: bin/pinmon

.PHONY:
clean:
	rm -rf bin

bin/pinmon: main.go $(DEPS) | bin
	go get
	go build -o $@ $<

bin:
	mkdir bin
