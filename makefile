

LIBFLAG= -g -Wall -Wl,-undefined,dynamic_lookup --shared


all: socket.so rc4.so crypt.so 


socket.so: lib/lsocket.c
	clang $(LIBFLAG) -o $@ $^

rc4.so: lib/rc4.c lib/lrc4.c
	clang $(LIBFLAG) -o $@ $^

crypt.so: lib/lcrypt.c
	clang $(LIBFLAG) -o $@ $^	


goscon:
	cd goscon/ && go build


clean:
	-rm -rf *.so


.PHONY: all clean goscon