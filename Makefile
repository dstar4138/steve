#
# Build for the Steve P2P service.
#

ERL=$(shell which erl)
REBAR=$(CURDIR)/bin/rebar
RELDIR=$(CURDIR)/rel
RELTOOL_CFG=$(CURDIR)/conf/reltool.config

.PHONY: daemon clean distclean drelease scripts all

## Compile the Daemon code.
daemon: 
	$(REBAR) get-deps compile 
	
test: daemon
	$(REBAR) eunit

## Superficial clean of workspace
clean:
	$(REBAR) clean

## Total whipe of all releases and generated scripts.
distclean: clean
	-rm bin/steve.sh
	-rm -rf rel

## Build a daemon release.
drelease: daemon
	-mkdir $(RELDIR)
	cd $(RELDIR); $(REBAR) create-node nodeid=steve
	cp $(RELTOOL_CFG) $(RELDIR)
	$(REBAR) generate

## Ease-of-Use scripts for quick launching and linking to.
scripts:
	touch bin/steve.sh
	@echo "#!/bin/sh" > bin/steve.sh
	@echo "$(RELDIR)/steve/bin/steve " $$"@" >> bin/steve.sh
	chmod +x bin/steve.sh

## Make everything including the scripts.
all: drelease scripts

