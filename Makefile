#
# Build for the Steve P2P service.
#

ERL=$(shell which erl)
REBAR=$(CURDIR)/bin/rebar
RELDIR=$(CURDIR)/rel
RELTOOL_CFG=$(CURDIR)/conf/reltool.config

.PHONY: daemon client clean distclean drelease crelease scripts all

## Compile the Daemon code.
daemon: 
	$(REBAR) get-deps compile 
	
## Compile our Client code.
client:
	git submodule init
	git submodule update
	cd apps/SteveClient; make

test: daemon
	$(REBAR) eunit

## Superficial clean of workspace
clean:
	$(REBAR) clean
	cd apps/SteveClient; make clean

## Total whipe of all releases and generated scripts.
distclean: clean
	-rm -rf apps/SteveClient
	-rm bin/steve.sh
	-rm -rf rel

## Build a daemon release.
drelease: daemon
	-mkdir $(RELDIR)
	cd $(RELDIR); $(REBAR) create-node nodeid=steve
	cp $(RELTOOL_CFG) $(RELDIR)
	$(REBAR) generate

## Build the client release. ##TODO: push client release code to rel/client/.
crelease: client
	-mkdir -p $(RELDIR)/client
	#cd apps/SteveClient; make release
	@echo "_WARNING_: COULDNT COPY CLIENT REL"


## Ease-of-Use scripts for quick launching and linking to.
scripts:
	touch bin/steve.sh
	@echo "#!/bin/sh" > bin/steve.sh
	@echo "$(RELDIR)/steve/bin/steve " $$"@" >> bin/steve.sh
	chmod +x bin/steve.sh

## Make everything including the scripts.
all: drelease crelease scripts

