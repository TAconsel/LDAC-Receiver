# Builds libldacBT_dec — the LDAC decoder library BlueALSA looks for when
# enabling its A2DP Sink LDAC path.  See README.md.
#
#   make                   build the library
#   make test              build and run the self-tests
#   sudo make install      install library, header and pkg-config file
#   sudo make uninstall    remove them

PREFIX       ?= /usr/local
LIBDIR       ?= $(PREFIX)/lib
INCLUDEDIR   ?= $(PREFIX)/include/ldac-dec
PKGCONFIGDIR ?= $(LIBDIR)/pkgconfig

# Version advertised through pkg-config.  BlueALSA's configure asks for
# ldacBT-dec >= 2.0.0, matching the encoder API generation this implements.
VERSION      := 2.0.0
SONAME       := libldacBT_dec.so.2
LIB          := $(SONAME).0.0

# Clean-room LDAC decoder; install.sh clones it here.
LDACDEC_SRC  ?= build/libldacdec
SRC          := src
GLUE         := $(SRC)/glue

CC           ?= cc
CFLAGS       ?= -O3 -g
COMMON       := $(CFLAGS) -std=gnu11 -Wall -Wextra -fPIC -pthread

# Include order matters: $(SRC)/include holds an ldacBT.h that adds the decode
# prototypes and reaches the packaged encoder header with #include_next, so it
# has to come before pkg-config's -I/usr/include/ldac.
ENC_CFLAGS   := $(shell pkg-config --cflags ldacBT-enc)
ENC_LIBS     := $(shell pkg-config --libs ldacBT-enc)
INCLUDES     := -I$(SRC)/include $(ENC_CFLAGS) -I$(GLUE) -I$(LDACDEC_SRC)

LDACDEC_OBJS := $(addprefix $(LDACDEC_SRC)/, \
	libldacdec.o bit_allocation.o huffCodes.o bit_reader.o utility.o \
	imdct.o spectrum.o)
OBJS         := $(LDACDEC_OBJS) $(GLUE)/ldacdec-glue.o $(SRC)/ldacBT_dec.o

.PHONY: all clean test install uninstall
all: $(LIB) ldacBT-dec.pc

%.o: %.c
	$(CC) $(COMMON) $(INCLUDES) -MMD -MP -c -o $@ $<

# The version script keeps everything except the two decode entry points local;
# see src/ldacBT_dec.map for why that matters.
$(LIB): $(OBJS) $(SRC)/ldacBT_dec.map
	$(CC) -shared -Wl,-soname,$(SONAME) \
		-Wl,--version-script,$(SRC)/ldacBT_dec.map \
		-o $@ $(OBJS) -lm -pthread
	ln -sf $(LIB) $(SONAME)
	ln -sf $(SONAME) libldacBT_dec.so

ldacBT-dec.pc: $(SRC)/ldacBT-dec.pc.in
	sed -e 's|@PREFIX@|$(PREFIX)|' -e 's|@LIBDIR@|$(LIBDIR)|' \
	    -e 's|@INCLUDEDIR@|$(INCLUDEDIR)|' -e 's|@VERSION@|$(VERSION)|' \
	    $< > $@

# --- self-tests -------------------------------------------------------------
# test-decode exercises the glue directly; test-ldacbt-dec goes through the
# Sony ABI exactly as BlueALSA's decode thread does.
TESTS := tests/test-decode tests/test-ldacbt-dec

test: $(TESTS)
	@fail=0; for t in $(TESTS); do echo; echo "== $$t =="; ./$$t || fail=1; done; exit $$fail

tests/test-decode: tests/test-decode.c $(LIB)
	$(CC) -O1 -g -std=gnu11 -Wall -Wextra $(INCLUDES) -o $@ $< \
		$(OBJS) $(ENC_LIBS) -lm -pthread

tests/test-ldacbt-dec: tests/test-ldacbt-dec.c $(LIB)
	$(CC) -O1 -g -std=gnu11 -Wall -Wextra $(INCLUDES) -o $@ $< \
		-L. -l:$(LIB) $(ENC_LIBS) -lm -pthread -Wl,-rpath,$(CURDIR)

# --- install ----------------------------------------------------------------
# Deliberately does not depend on 'all': this runs under sudo and rebuilding
# here would leave root-owned objects in the tree.  Build first.
install:
	@test -f $(LIB) || { echo "error: nothing built yet; run 'make' first" >&2; exit 1; }
	install -d $(DESTDIR)$(LIBDIR) $(DESTDIR)$(INCLUDEDIR) $(DESTDIR)$(PKGCONFIGDIR)
	install -m 0644 $(LIB) $(DESTDIR)$(LIBDIR)/$(LIB)
	ln -sf $(LIB) $(DESTDIR)$(LIBDIR)/$(SONAME)
	ln -sf $(SONAME) $(DESTDIR)$(LIBDIR)/libldacBT_dec.so
	install -m 0644 $(SRC)/include/ldacBT.h $(DESTDIR)$(INCLUDEDIR)/ldacBT.h
	install -m 0644 ldacBT-dec.pc $(DESTDIR)$(PKGCONFIGDIR)/ldacBT-dec.pc
	ldconfig || true

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/$(LIB) $(DESTDIR)$(LIBDIR)/$(SONAME) \
		$(DESTDIR)$(LIBDIR)/libldacBT_dec.so \
		$(DESTDIR)$(INCLUDEDIR)/ldacBT.h \
		$(DESTDIR)$(PKGCONFIGDIR)/ldacBT-dec.pc
	ldconfig || true

clean:
	rm -f $(OBJS) $(OBJS:.o=.d) $(LIB) $(SONAME) libldacBT_dec.so \
		ldacBT-dec.pc $(TESTS)

-include $(OBJS:.o=.d)
