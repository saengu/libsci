LIBS = ../../sci/libsci/target
CC = gcc
CFLAGS = -Wall -Wextra -I$(LIBS)
LDFLAGS = -L$(LIBS) -lsci

.PHONY: all clean run

all: from_c_host

from_c_host: from_c_host.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

run: from_c_host
	LD_LIBRARY_PATH=$(shell realpath $(LIBS)) ./from_c_host

clean:
	rm -f from_c_host
