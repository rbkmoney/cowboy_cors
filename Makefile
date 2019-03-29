REBAR := $(shell which rebar3 2>/dev/null || which ./rebar3)
SUBMODULES = build_utils
SUBTARGETS = $(patsubst %,%/.git,$(SUBMODULES))

UTILS_PATH := build_utils
# ToDo: remove unused TEMPLATES_PATH here, when the bug
# with handling of the varriable in build_utils is fixed
TEMPLATES_PATH := .
SERVICE_NAME := cowboy_cors
BUILD_IMAGE_TAG := f3732d29a5e622aabf80542b5138b3631a726adb

CALL_W_CONTAINER := all submodules rebar-update compile xref lint dialyze test clean distclean

.PHONY: $(CALL_W_CONTAINER)

all: compile

-include $(UTILS_PATH)/make_lib/utils_container.mk

$(SUBTARGETS): %/.git: %
	git submodule update --init $<
	touch $@

submodules: $(SUBTARGETS)

compile: submodules rebar-update
	$(REBAR) compile

rebar-update:
	$(REBAR) update

test: submodules
	$(REBAR) ct

xref: submodules
	$(REBAR) xref

clean:
	$(REBAR) clean

distclean:
	$(REBAR) clean -a
	rm -rfv _build

dialyze:
	$(REBAR) dialyzer

lint:
	elvis rock
