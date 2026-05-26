LIBS = ../../target
CC = gcc
CFLAGS = -Wall -Wextra -I$(LIBS)
LDFLAGS = -L$(LIBS) -lsci

.PHONY: all clean run test

all: from_c_host

from_c_host: from_c_host.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

run test: from_c_host
	LD_LIBRARY_PATH=$(shell realpath $(LIBS)) ./from_c_host

clean:
	rm -f from_c_host
