ifeq ($(ERL_EI_INCLUDE_DIR),)
ERL_ROOT_DIR = $(shell erl -eval "io:format(\"~s~n\", [code:root_dir()])" -s init stop -noshell)
ERL_EI_INCLUDE_DIR = "$(ERL_ROOT_DIR)/usr/include"
ERL_EI_LIBDIR = "$(ERL_ROOT_DIR)/usr/lib"
endif

LOLHTML_SRC_DIR=c_src/lol-html/c-api
LOLHTML_STATIC_LIB=$(LOLHTML_SRC_DIR)/target/release/liblolhtml.a

ERL_CFLAGS ?= -I$(ERL_EI_INCLUDE_DIR)
ERL_LDFLAGS ?= -L$(ERL_EI_LIBDIR)

LDFLAGS += -fPIC -shared
CFLAGS ?= -fPIC -O2 -Wall -Wextra -Wno-unused-parameter

ifeq ($(shell uname),Darwin)
LDFLAGS += -undefined dynamic_lookup $(LOLHTML_STATIC_LIB)
else
LDFLAGS += -Wl,--whole-archive $(LOLHTML_STATIC_LIB) -Wl,--no-whole-archive
endif

NIF=priv/laughter_nif.so

all: priv $(LOLHTML_STATIC_LIB) $(NIF)

priv:
	mkdir -p priv

$(LOLHTML_STATIC_LIB):
	cd $(LOLHTML_SRC_DIR) && cargo build --release

$(NIF): c_src/laughter_nif.c
	$(CC) $(ERL_CFLAGS) $(CFLAGS) -I"$(LOLHTML_SRC_DIR)/include" \
	$(LDFLAGS) $(ERL_LDFLAGS) -o $@ $<

clean:
	$(RM) $(NIF)

distclean: clean
	cd $(LOLHTML_SRC_DIR) && cargo clean
