all: do-build

do-build:
	@mkdir -p ebin
	@erl -make

