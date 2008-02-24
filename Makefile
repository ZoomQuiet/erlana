all: do-build

do-build:
	@mkdir -p ebin
	@erl -make

# --------------------------------------------------------------------
# mochiweb spec
# --------------------------------------------------------------------

gen-webproj:
	@if [ -d erlana ]; then \
	    echo "Erlana web project is generated already."; \
	else \
	    escript mochiweb/scripts/new_mochiweb.erl erlana; \
	fi

mochiweb:
	@svn co http://mochiweb.googlecode.com/svn/trunk mochiweb

get-mochiweb:
	@rm -rf mochiweb
	@svn co http://mochiweb.googlecode.com/svn/trunk mochiweb

up-mochiweb: mochiweb
	@if [ -d mochiweb ]; then \
		cd mochiweb; \
		svn up; \
		make; \
		cp ebin/*.* ../ebin/; \
	fi

