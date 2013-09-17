#
# Build for the Steve P2P service.
#

ERL=$(shell which erl)
REBAR=$(CURDIR)/bin/rebar

.PHONY: steve clean

steve: 
	$(REBAR) compile

clean:
	$(REBAR) clean

