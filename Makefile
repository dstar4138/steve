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
	$(REBAR) compile 
	
## Compile our Client code.
client:
	cd apps/stevecli; make

## Superficial clean of workspace
clean:
	$(REBAR) clean
	cd apps/stevecli; make clean

## Total whipe of all releases and generated scripts.
distclean: clean
	-rm start_steve.sh
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
	cd apps/stevecli; make release
	@echo "_WARNING_: COULDNT COPY CLIENT REL"


## Ease-of-Use scripts for quick launching and linking to.
scripts:
	touch start_steve.sh
	@echo "#!/bin/sh" > start_steve.sh
	@echo "$(RELDIR)/steve/bin/steve start" >> start_steve.sh
	chmod +x start_steve.sh

## Make everything including the scripts.
all: drelease crelease scripts

