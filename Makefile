MANPAGES := generate-cluster-id.1
MANPAGES := $(addprefix man/,$(MANPAGES))

.PHONY: all clean

all: $(MANPAGES)

clean:
	rm -f $(MANPAGES)


%: %.xml
	xmltoman $< > $@
